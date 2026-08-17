"""카메라 이미지를 dc-vps 로컬라이제이션 서버(server/, POST /localize)에 보내서
6DoF pose를 받아오고, robot_localization EKF 입력 또는 AMCL /initialpose로 쓸 수 있는
PoseWithCovarianceStamped로 퍼블리시하는 브리지 노드.

- hloc world 좌표계 pose를 map 프레임으로 옮기기 위해 `scan_basemap_frame`(기본
  "scan_basemap") -> `map_frame`(기본 "map") ROS tf를 매번 lookup해서 적용한다.
  이 tf는 pipeline/export_pointcloud.py로 뽑은 포인트클라우드를
  https://github.com/dcrobot-keen/scan-to-map-studio 에 넣어 로봇 자체 SLAM 지도와
  ICP 정합한 결과(scripts/export_tf.py 출력)를 그대로 쓰면 된다 — 같은 스캔에서
  나온 world 좌표계라 별도 변환 없이 바로 맞는다.
- 서버가 여러 방(room)의 DB를 동시에 서빙 중이면(server/README.md "여러 방" 참고)
  응답에 room_id가 실려온다 — 그 경우 `scan_basemap_frame` 대신
  `{scan_basemap_frame_prefix}{room_id}`(기본 접두사 "scan_basemap_")를 tf 소스
  프레임으로 쓴다. room_id가 없으면(단일 DB 서버) 기존처럼 `scan_basemap_frame`을 쓴다.
- 그 tf가 아직 안 올라와 있으면(스캔-투-맵 파이프라인을 아직 안 돌렸거나, 로봇이
  없어서 테스트 중인 경우) `calibration_translation`/`calibration_quaternion`
  파라미터(기본 identity)로 대체한다 — tf 없이도 노드가 죽거나 멈추지 않고 계속
  동작하게 하기 위한 폴백.
- VPS 서버 쿼리는 느리므로(모델 로딩 포함 요청당 수십 초~1분, server/README.md 참고)
  카메라 프레임마다 호출하지 않고 query_period_sec 주기로만 최신 프레임을 사용한다.
"""

from __future__ import annotations

import cv2
import numpy as np
import rclpy
import requests
from cv_bridge import CvBridge
from geometry_msgs.msg import PoseWithCovarianceStamped
from rclpy.duration import Duration
from rclpy.node import Node
from rclpy.time import Time
from sensor_msgs.msg import CameraInfo, Image
from tf2_ros import ConnectivityException, ExtrapolationException, LookupException
from tf2_ros.buffer import Buffer
from tf2_ros.transform_listener import TransformListener


def quaternion_to_matrix(q: np.ndarray) -> np.ndarray:
    """[x, y, z, w] 쿼터니언 -> 3x3 회전행렬."""
    x, y, z, w = q
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ]
    )


def matrix_to_quaternion(r: np.ndarray) -> np.ndarray:
    """3x3 회전행렬 -> [x, y, z, w] 쿼터니언 (Shepperd's method, 수치적으로 안정적)."""
    trace = np.trace(r)
    if trace > 0:
        s = 0.5 / np.sqrt(trace + 1.0)
        w = 0.25 / s
        x = (r[2, 1] - r[1, 2]) * s
        y = (r[0, 2] - r[2, 0]) * s
        z = (r[1, 0] - r[0, 1]) * s
    elif r[0, 0] > r[1, 1] and r[0, 0] > r[2, 2]:
        s = 2.0 * np.sqrt(1.0 + r[0, 0] - r[1, 1] - r[2, 2])
        w = (r[2, 1] - r[1, 2]) / s
        x = 0.25 * s
        y = (r[0, 1] + r[1, 0]) / s
        z = (r[0, 2] + r[2, 0]) / s
    elif r[1, 1] > r[2, 2]:
        s = 2.0 * np.sqrt(1.0 + r[1, 1] - r[0, 0] - r[2, 2])
        w = (r[0, 2] - r[2, 0]) / s
        x = (r[0, 1] + r[1, 0]) / s
        y = 0.25 * s
        z = (r[1, 2] + r[2, 1]) / s
    else:
        s = 2.0 * np.sqrt(1.0 + r[2, 2] - r[0, 0] - r[1, 1])
        w = (r[1, 0] - r[0, 1]) / s
        x = (r[0, 2] + r[2, 0]) / s
        y = (r[1, 2] + r[2, 1]) / s
        z = 0.25 * s
    return np.array([x, y, z, w])


class VPSLocalizerNode(Node):
    def __init__(self) -> None:
        super().__init__("vps_localizer_node")

        self.declare_parameter("server_url", "http://localhost:8000/localize")
        self.declare_parameter("image_topic", "image_raw")
        self.declare_parameter("camera_info_topic", "camera_info")
        self.declare_parameter("pose_topic", "vps_pose")
        self.declare_parameter("map_frame", "map")
        self.declare_parameter("scan_basemap_frame", "scan_basemap")
        self.declare_parameter("scan_basemap_frame_prefix", "scan_basemap_")
        self.declare_parameter("tf_lookup_timeout_sec", 0.5)
        self.declare_parameter("query_period_sec", 2.0)
        self.declare_parameter("jpeg_quality", 85)
        self.declare_parameter("request_timeout_sec", 30.0)
        self.declare_parameter("position_stddev_m", 0.05)
        self.declare_parameter("orientation_stddev_deg", 5.0)
        # scan_basemap -> map tf가 없을 때(scan-to-map-studio 정합을 아직 안 했거나
        # 로봇 없이 테스트 중일 때)의 폴백. 기본값은 identity(=hloc world와 map이
        # 동일 원점/방향).
        self.declare_parameter("calibration_translation", [0.0, 0.0, 0.0])
        self.declare_parameter("calibration_quaternion", [0.0, 0.0, 0.0, 1.0])

        self.server_url = self.get_parameter("server_url").value
        self.map_frame = self.get_parameter("map_frame").value
        self.scan_basemap_frame = self.get_parameter("scan_basemap_frame").value
        self.scan_basemap_frame_prefix = self.get_parameter("scan_basemap_frame_prefix").value
        self.tf_lookup_timeout = Duration(
            seconds=float(self.get_parameter("tf_lookup_timeout_sec").value)
        )
        self.jpeg_quality = int(self.get_parameter("jpeg_quality").value)
        self.request_timeout_sec = float(self.get_parameter("request_timeout_sec").value)

        position_stddev = float(self.get_parameter("position_stddev_m").value)
        orientation_stddev_rad = np.deg2rad(
            float(self.get_parameter("orientation_stddev_deg").value)
        )
        self.covariance = self._build_covariance(position_stddev, orientation_stddev_rad)

        calib_t = self.get_parameter("calibration_translation").value
        calib_q = self.get_parameter("calibration_quaternion").value
        self.fallback_translation = np.array(calib_t, dtype=np.float64)
        self.fallback_rotation = quaternion_to_matrix(np.array(calib_q, dtype=np.float64))

        self.tf_buffer = Buffer()
        self.tf_listener = TransformListener(self.tf_buffer, self)

        self.bridge = CvBridge()
        self.latest_image = None
        self.latest_camera_info: CameraInfo | None = None

        self.image_sub = self.create_subscription(
            Image, self.get_parameter("image_topic").value, self._on_image, 10
        )
        self.info_sub = self.create_subscription(
            CameraInfo,
            self.get_parameter("camera_info_topic").value,
            self._on_camera_info,
            10,
        )
        self.pose_pub = self.create_publisher(
            PoseWithCovarianceStamped, self.get_parameter("pose_topic").value, 10
        )

        query_period_sec = float(self.get_parameter("query_period_sec").value)
        self.timer = self.create_timer(query_period_sec, self._on_timer)

        self.get_logger().info(
            f"dc-vps localizer bridge 시작: server_url={self.server_url}, "
            f"query_period={query_period_sec}s"
        )

    @staticmethod
    def _build_covariance(position_stddev: float, orientation_stddev_rad: float) -> list:
        cov = [0.0] * 36
        for i in range(3):
            cov[i * 6 + i] = position_stddev**2
        for i in range(3, 6):
            cov[i * 6 + i] = orientation_stddev_rad**2
        return cov

    def _on_image(self, msg: Image) -> None:
        self.latest_image = self.bridge.imgmsg_to_cv2(msg, desired_encoding="bgr8")

    def _on_camera_info(self, msg: CameraInfo) -> None:
        self.latest_camera_info = msg

    def _on_timer(self) -> None:
        if self.latest_image is None:
            self.get_logger().warn("아직 카메라 이미지를 받지 못함 — 쿼리 스킵", throttle_duration_sec=10)
            return
        if self.latest_camera_info is None:
            self.get_logger().warn("아직 camera_info를 받지 못함 — 쿼리 스킵", throttle_duration_sec=10)
            return

        ok, encoded = cv2.imencode(
            ".jpg", self.latest_image, [cv2.IMWRITE_JPEG_QUALITY, self.jpeg_quality]
        )
        if not ok:
            self.get_logger().error("쿼리 이미지 JPEG 인코딩 실패")
            return

        k = self.latest_camera_info.k  # row-major 3x3
        fields = {
            "fx": str(k[0]),
            "fy": str(k[4]),
            "cx": str(k[2]),
            "cy": str(k[5]),
            "width": str(self.latest_camera_info.width),
            "height": str(self.latest_camera_info.height),
        }

        try:
            response = requests.post(
                self.server_url,
                files={"image": ("query.jpg", encoded.tobytes(), "image/jpeg")},
                data=fields,
                timeout=self.request_timeout_sec,
            )
        except requests.RequestException as error:
            self.get_logger().error(f"VPS 서버 요청 실패: {error}")
            return

        if response.status_code != 200:
            self.get_logger().warn(
                f"VPS 로컬라이제이션 실패 (HTTP {response.status_code}): {response.text}"
            )
            return

        result = response.json()
        self._publish_pose(result)

    def _get_calibration(self, room_id: str | None) -> tuple[np.ndarray, np.ndarray]:
        """scan_basemap(_<room_id>) -> map 변환을 tf에서 lookup한다.
        실패하면 정적 파라미터로 대체한다."""
        source_frame = (
            f"{self.scan_basemap_frame_prefix}{room_id}" if room_id else self.scan_basemap_frame
        )
        try:
            transform = self.tf_buffer.lookup_transform(
                self.map_frame,
                source_frame,
                Time(),
                timeout=self.tf_lookup_timeout,
            )
        except (LookupException, ConnectivityException, ExtrapolationException) as error:
            self.get_logger().warn(
                f"'{source_frame}' -> '{self.map_frame}' tf를 찾을 수 없어 "
                f"calibration_translation/quaternion 파라미터로 대체함: {error}",
                throttle_duration_sec=10,
            )
            return self.fallback_translation, self.fallback_rotation

        t = transform.transform.translation
        q = transform.transform.rotation
        translation = np.array([t.x, t.y, t.z], dtype=np.float64)
        rotation = quaternion_to_matrix(np.array([q.x, q.y, q.z, q.w], dtype=np.float64))
        return translation, rotation

    def _publish_pose(self, result: dict) -> None:
        t_world_cam = np.array(result["translation"], dtype=np.float64)
        r_world_cam = quaternion_to_matrix(np.array(result["quaternion"], dtype=np.float64))
        calib_translation, calib_rotation = self._get_calibration(result.get("room_id"))

        # T_map_from_cam = T_map_from_world * T_world_from_cam
        r_map_cam = calib_rotation @ r_world_cam
        t_map_cam = calib_rotation @ t_world_cam + calib_translation
        q_map_cam = matrix_to_quaternion(r_map_cam)

        msg = PoseWithCovarianceStamped()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.header.frame_id = self.map_frame
        msg.pose.pose.position.x = float(t_map_cam[0])
        msg.pose.pose.position.y = float(t_map_cam[1])
        msg.pose.pose.position.z = float(t_map_cam[2])
        msg.pose.pose.orientation.x = float(q_map_cam[0])
        msg.pose.pose.orientation.y = float(q_map_cam[1])
        msg.pose.pose.orientation.z = float(q_map_cam[2])
        msg.pose.pose.orientation.w = float(q_map_cam[3])
        msg.pose.covariance = self.covariance

        self.pose_pub.publish(msg)
        self.get_logger().info(
            f"VPS pose 퍼블리시: t={t_map_cam.round(3).tolist()}, "
            f"room_id={result.get('room_id')}, num_inliers={result.get('num_inliers')}"
        )


def main(args=None) -> None:
    rclpy.init(args=args)
    node = VPSLocalizerNode()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()

# dc_vps_bridge

`server/`의 dc-vps 로컬라이제이션 서버(`POST /localize`)를 호출해서 6DoF pose를 받아오고,
`robot_localization` EKF 또는 AMCL `/initialpose`에 넣을 수 있는
`geometry_msgs/PoseWithCovarianceStamped`로 퍼블리시하는 ROS2(Humble) 브리지 노드.

macOS(Apple Silicon)에서 [RoboStack](https://robostack.github.io/)의 `pixi` 배포판으로
ROS2 Humble(`ros-humble-ros-base` + `cv_bridge` + `launch_ros` + `tf2_ros`)을 설치해서
`colcon build`, `ros2 run`, `ros2 launch`(YAML 파라미터 로딩 포함)까지, 그리고 아래
"map 프레임 캘리브레이션"의 tf lookup/fallback 로직도 실제 `static_transform_publisher`로
검증했다 (2026-08-17). 단, **로봇/카메라/Nav2 스택 자체가 아직 없어서** 실제 이미지
토픽을 받아 VPS 서버에 쿼리하는 end-to-end 흐름은 검증 못 했다 — 노드가 뜨고
파라미터를 읽고 구독/퍼블리셔를 만들고 tf를 정확히 적용하는 것까지만 확인된 상태.

## 설치 & 빌드

이 프로젝트는 [pixi](https://pixi.sh/)(RoboStack) 기반 ROS2 환경을 쓴다. 별도
pixi 프로젝트(`~/code/ros_ws` 같은 곳)에 아래 의존성으로 설치한다:

```toml
# pixi.toml
[workspace]
channels = ["https://prefix.dev/robostack-humble"]
platforms = ["osx-arm64"]  # Apple Silicon 기준, Intel Mac이면 osx-64

[dependencies]
ros-humble-ros-base = "*"
ros-humble-cv-bridge = "*"
ros-humble-launch-ros = "*"
colcon-common-extensions = "*"
requests = "*"
```

```bash
pixi install
pixi run bash -c "cd /path/to/vps-system/ros2_ws && colcon build --packages-select dc_vps_bridge"
```

(Linux에서 표준 ROS2 apt 설치를 쓴다면 `rosdep install --from-paths src --ignore-src -r -y`
후 `colcon build --packages-select dc_vps_bridge`로 동일하게 빌드된다. `python3-requests`
rosdep 키가 없으면 `pip install requests`로 대체.)

## 실행

먼저 `server/`의 dc-vps 서버가 떠 있어야 한다 ([server/README.md](../../server/README.md) 참고):
```bash
# server/ 에서
export DC_VPS_DB_DIR=../pipeline/outputs/<scan_name>
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

그 다음 브리지 노드 실행:
```bash
# pixi 환경이면
pixi run bash -c "source /path/to/vps-system/ros2_ws/install/setup.bash && ros2 launch dc_vps_bridge vps_localizer.launch.py"

# 또는 pixi shell로 들어간 뒤
source /path/to/vps-system/ros2_ws/install/setup.bash
ros2 launch dc_vps_bridge vps_localizer.launch.py
```

파라미터는 [config/vps_localizer.yaml](config/vps_localizer.yaml) 참고. 주요 항목:
- `server_url`: dc-vps 서버 `/localize` 엔드포인트
- `image_topic` / `camera_info_topic`: 로봇 카메라 토픽 (RGB 이미지 + intrinsics)
- `pose_topic`: 퍼블리시할 pose 토픽 이름 (기본 `vps_pose`)
- `query_period_sec`: VPS 쿼리 주기. 현재 서버가 요청마다 모델을 새로 로드해서
  느리므로(server/README.md "구현 메모" 참고) 너무 짧게 잡지 말 것
- `map_frame` / `scan_basemap_frame` / `scan_basemap_frame_prefix` / `calibration_translation` /
  `calibration_quaternion`: 아래 "map 프레임 캘리브레이션" 참고

## robot_localization / AMCL에 연결하기

`vps_pose` 토픽은 표준 `PoseWithCovarianceStamped`라 두 가지 방식으로 바로 쓸 수 있다:

**(A) robot_localization EKF의 추가 pose 소스로 fusion**
```yaml
ekf_node:
  ros__parameters:
    pose0: vps_pose
    pose0_config: [true,  true,  true,
                    false, false, true,
                    false, false, false,
                    false, false, false,
                    false, false, false]
```
(x, y, yaw만 fuse하는 예시 — 로봇이 2D 평면 위에서만 움직인다면. 실제 EKF 설정은 기존
IMU/wheel odometry 소스와 함께 튜닝 필요.)

**(B) AMCL 재측위(주기적 드리프트 보정)**
launch에서 `pose_topic`을 `initialpose`로 remap하면 AMCL이 이 pose로 주기적으로
재초기화된다:
```python
Node(
    package="dc_vps_bridge",
    executable="vps_localizer_node",
    remappings=[("vps_pose", "initialpose")],
    ...
)
```
다만 매 쿼리마다 AMCL을 강제로 튀게 만들 수 있으니, 실제로는 (A)가 더 안정적인 선택.

## map 프레임 캘리브레이션

hloc이 만드는 world 좌표계의 원점/방향은 **스캔 세션을 시작한 순간의 iPhone pose**다
(ARKit이 세션 시작 지점을 world origin으로 잡기 때문 — `ios-capture/README.md` 참고).
이건 로봇의 `map` 프레임(occupancy grid 원점)과 대개 다르다. 노드는 이 변환을 두
가지 방법으로 얻는다 — **(A)가 되면 자동으로 (A)를 쓰고, 안 되면 (B)로 폴백한다.**

**(A) 자동 — scan-to-map-studio의 tf (권장)**

같은 스캔에서 `pipeline/export_pointcloud.py`로 뽑은 포인트클라우드를
[scan-to-map-studio](https://github.com/dcrobot-keen/scan-to-map-studio)에 넣어
로봇 자체 SLAM 지도와 ICP 정합하면 `scripts/export_tf.py`가 `scan_basemap` ↔ `map`
정적 tf를 출력해준다 (`static_transform_publisher` 명령어 형태로 나옴). 그 명령을
로봇에서 띄워두면, `vps_localizer_node`가 매 쿼리마다 이 tf를 자동으로 lookup해서
VPS pose에 적용한다 — 아래 (B)의 수동 측정 없이 **ICP 기반으로 훨씬 정확하게** 얻는
경로다. 노드의 `scan_basemap_frame` 파라미터(기본 `"scan_basemap"`)가 tf의
`frame_id`와 이름이 같아야 한다.

같은 스캔에서 export_pointcloud.py → scan-to-map-studio(`remove_ceiling.py` →
`rasterize_base_map.py`)까지는 실데이터로 검증됨(`pipeline/README.md` 참고).
`register_maps.py`(로봇 지도와의 ICP 정합) 이후 단계와, 이 tf를 `vps_localizer_node`가
실제로 lookup해서 적용하는 부분은 각각 별도로 검증했다 — `tf2_ros.Buffer`로 실제
`static_transform_publisher`를 띄워 known transform을 lookup해서 정확한 역변환이
나오는 것까지 확인함(2026-08-17). 다만 두 파이프라인을 **로봇의 실제 SLAM 지도로
엮어서** 끝까지 돌려본 적은 아직 없다 (로봇이 없어서).

**여러 방(room)일 때**: `server/`가 여러 DB(`DC_VPS_DB_DIRS`)를 서빙 중이면 응답에
`room_id`가 실려온다 — 그 경우 `scan_basemap_frame`을 무시하고
`{scan_basemap_frame_prefix}{room_id}`(기본 접두사 `"scan_basemap_"`)를 tf 소스
프레임으로 쓴다. 즉 방마다 scan-to-map-studio로 각각 로봇 map에 등록해서
`scan_basemap_<room_id>` tf를 따로 export해두면, 방이 몇 개든 로봇의 공용 `map`
프레임 하나로 자동으로 이어진다 — 방끼리 서로 겹쳐 찍을 필요 없음. 이것도
`static_transform_publisher`로 room별 tf 두 개를 띄워서 정확한 room이 정확한 tf를
찾는 것까지 검증함(2026-08-17).

**(B) 수동 폴백 — `calibration_translation`/`calibration_quaternion`**

`scan_basemap_frame` → `map_frame` tf가 없을 때(스캔-투-맵 파이프라인을 아직 안
돌렸거나 테스트 중일 때)만 쓰인다. 기본값은 identity.

1. iPhone으로 스캔을 시작하기 **직전**, 로봇을 `map` 프레임 기준으로 알고 있는 정확한
   위치/방향에 세운다 (예: AMCL로 이미 잘 수렴한 상태, 또는 맵 원점의 특정 마커 위).
2. 그 로봇 pose(`map` 프레임 기준 translation+quaternion)를 기록해둔다 — 이게
   `calibration_translation`/`calibration_quaternion`이 된다.
3. `config/vps_localizer.yaml`에 그 값을 채워 넣는다.

## 알려진 한계

- 카메라 프레임을 매번 쓰지 않고 `query_period_sec` 주기로 최신 프레임만 사용한다
  (서버가 느려서 그렇다 — `server/README.md` 참고).
- 이미지/camera_info를 아직 못 받았으면 조용히 스킵한다 (throttled 로그만 남김,
  실제로 이 상태에서 로그가 잘 찍히는 것까지 확인함).
- tf lookup은 쿼리(`query_period_sec`)마다 다시 하고 캐싱하지 않는다 — `lookup_transform`
  자체가 가벼운 호출이라 문제없다고 보고 일단 단순하게 뒀다.
- 로봇/카메라/Nav2 스택이 없어서 실제 이미지 토픽으로 VPS 서버까지 쿼리하는 전체
  흐름은 아직 검증 못 했다. 카메라 토픽이 생기면 `image_topic`/`camera_info_topic`
  파라미터만 맞춰주면 될 것으로 예상하지만 실측 필요.
- `ros2 run`으로 노드를 실행하면 stdout이 완전 버퍼링돼서 로그가 즉시 안 보일 수
  있다(`ros2 launch`는 정상 스트리밍됨) — 디버깅 시 `ros2 launch`를 쓰거나
  `PYTHONUNBUFFERED=1`을 설정할 것.

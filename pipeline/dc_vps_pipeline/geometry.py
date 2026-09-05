"""RGB keypoint -> depth 해상도 정합 -> 3D world 좌표 backproject.

핵심 규칙 (대화에서 확정된 정합 정책):
- keypoint를 depth 해상도로 스케일 다운한다 (반대 방향인 depth upsampling은 안 함).
- depth/confidence lookup은 반드시 nearest-neighbor. bilinear는 물체 경계에서
  전경/배경 depth가 섞이는 "flying pixel" 아티팩트를 만든다.
- confidence < MIN_CONFIDENCE인 포인트는 버린다.

스케일은 프레임마다 다를 수 있다: poses.jsonl의 intrinsics.width/height(= 저장된 RGB
이미지 크기)를 쓴다. 2026-09-05부터 앱이 RGB를 긴 변 1600px로 저장하므로(hloc의
resize_max와 같음) 옛 스캔(1920x1440)과 새 스캔(1600x1200)이 한 파이프라인에서 같이
돌아야 하고, config.RGB_WIDTH/HEIGHT는 그 값이 없는 옛 레코드의 폴백일 뿐이다.
"""

from __future__ import annotations

import numpy as np

from . import config

ImageSize = tuple[int, int]  # (width, height) of the saved RGB image

DEFAULT_IMAGE_SIZE: ImageSize = (config.RGB_WIDTH, config.RGB_HEIGHT)


def depth_scale(image_size: ImageSize = DEFAULT_IMAGE_SIZE) -> tuple[float, float]:
    """(scale_x, scale_y): RGB 픽셀 좌표 -> depth 픽셀 좌표 배율."""
    w, h = image_size
    return config.DEPTH_WIDTH / w, config.DEPTH_HEIGHT / h


def rgb_keypoint_to_depth_coord(kp_rgb: tuple[float, float], image_size: ImageSize = DEFAULT_IMAGE_SIZE) -> tuple[float, float]:
    sx, sy = depth_scale(image_size)
    return kp_rgb[0] * sx, kp_rgb[1] * sy


def scale_intrinsics_to_depth(K_rgb: np.ndarray, image_size: ImageSize = DEFAULT_IMAGE_SIZE) -> np.ndarray:
    """RGB 기준 intrinsics(3x3)를 depth 해상도 기준으로 스케일한다."""
    sx, sy = depth_scale(image_size)
    K_depth = K_rgb.copy()
    K_depth[0, 0] *= sx  # fx
    K_depth[1, 1] *= sy  # fy
    K_depth[0, 2] *= sx  # cx
    K_depth[1, 2] *= sy  # cy
    return K_depth


def sample_nearest(map_2d: np.ndarray, u_d: float, v_d: float):
    row, col = int(round(v_d)), int(round(u_d))
    if 0 <= row < map_2d.shape[0] and 0 <= col < map_2d.shape[1]:
        return map_2d[row, col]
    return None


def backproject_filtered(
    kp_rgb: tuple[float, float],
    depth_map: np.ndarray,
    confidence_map: np.ndarray | None,
    K_depth: np.ndarray,
    pose_c2w: np.ndarray,
    min_confidence: int = config.MIN_CONFIDENCE,
    image_size: ImageSize = DEFAULT_IMAGE_SIZE,
) -> np.ndarray | None:
    """RGB keypoint 하나를 world 좌표계 3D 포인트로 변환한다.

    confidence 미달이거나 depth가 유효 범위를 벗어나면 None을 반환한다
    (반사면/저텍스처 영역, 원거리 노이즈 대응). `image_size`는 keypoint가 찍힌
    RGB 이미지의 크기 -- `K_depth`를 만든 것과 같은 값이어야 한다.
    """
    u_d, v_d = rgb_keypoint_to_depth_coord(kp_rgb, image_size)
    row, col = int(round(v_d)), int(round(u_d))
    if not (0 <= row < depth_map.shape[0] and 0 <= col < depth_map.shape[1]):
        return None

    if confidence_map is not None:
        confidence = confidence_map[row, col]
        if confidence < min_confidence:
            return None

    z = float(depth_map[row, col])
    if z <= config.MIN_DEPTH_METERS or z > config.MAX_DEPTH_METERS:
        return None

    x = (u_d - K_depth[0, 2]) * z / K_depth[0, 0]
    y = (v_d - K_depth[1, 2]) * z / K_depth[1, 1]
    p_cam = np.array([x, y, z, 1.0])
    p_world = pose_c2w @ p_cam
    return p_world[:3]

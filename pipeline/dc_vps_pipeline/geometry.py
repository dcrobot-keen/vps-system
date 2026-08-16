"""RGB keypoint -> depth 해상도 정합 -> 3D world 좌표 backproject.

핵심 규칙 (대화에서 확정된 정합 정책):
- keypoint를 depth 해상도로 스케일 다운한다 (반대 방향인 depth upsampling은 안 함).
- depth/confidence lookup은 반드시 nearest-neighbor. bilinear는 물체 경계에서
  전경/배경 depth가 섞이는 "flying pixel" 아티팩트를 만든다.
- confidence < MIN_CONFIDENCE인 포인트는 버린다.
"""

from __future__ import annotations

import numpy as np

from . import config


def rgb_keypoint_to_depth_coord(kp_rgb: tuple[float, float]) -> tuple[float, float]:
    u_d = kp_rgb[0] * config.SCALE_X
    v_d = kp_rgb[1] * config.SCALE_Y
    return u_d, v_d


def scale_intrinsics_to_depth(K_rgb: np.ndarray) -> np.ndarray:
    """RGB 기준 intrinsics(3x3)를 depth 해상도 기준으로 스케일한다."""
    K_depth = K_rgb.copy()
    K_depth[0, 0] *= config.SCALE_X  # fx
    K_depth[1, 1] *= config.SCALE_Y  # fy
    K_depth[0, 2] *= config.SCALE_X  # cx
    K_depth[1, 2] *= config.SCALE_Y  # cy
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
) -> np.ndarray | None:
    """RGB keypoint 하나를 world 좌표계 3D 포인트로 변환한다.

    confidence 미달이거나 depth가 유효 범위를 벗어나면 None을 반환한다
    (반사면/저텍스처 영역, 원거리 노이즈 대응).
    """
    u_d, v_d = rgb_keypoint_to_depth_coord(kp_rgb)
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

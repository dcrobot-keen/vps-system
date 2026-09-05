"""RGB -> depth 배율이 저장 이미지 크기(1920x1440 옛 스캔, 1600x1200 새 스캔)에 따라
프레임마다 달라져도 같은 물리 지점을 같은 depth 픽셀로 보내는지 확인한다. GPU 불필요.
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from dc_vps_pipeline import config
from dc_vps_pipeline.geometry import (
    backproject_filtered,
    depth_scale,
    rgb_keypoint_to_depth_coord,
    scale_intrinsics_to_depth,
)
from dc_vps_pipeline.scan_loader import load_scan

K_1920 = np.array([[1440.25, 0.0, 965.58], [0.0, 1440.25, 719.76], [0.0, 0.0, 1.0]])


def test_default_scale_matches_legacy_constants() -> None:
    assert depth_scale() == (config.SCALE_X, config.SCALE_Y)


def test_same_physical_point_lands_on_same_depth_pixel_at_both_sizes() -> None:
    f = 1600 / 1920
    K_1600 = K_1920.copy()
    K_1600[0, 0] *= f; K_1600[1, 1] *= f; K_1600[0, 2] *= f; K_1600[1, 2] *= f
    kp_1920 = (1200.0, 800.0)
    kp_1600 = (1200.0 * f, 800.0 * f)
    d_a = rgb_keypoint_to_depth_coord(kp_1920, (1920, 1440))
    d_b = rgb_keypoint_to_depth_coord(kp_1600, (1600, 1200))
    np.testing.assert_allclose(d_a, d_b, atol=1e-9)
    np.testing.assert_allclose(scale_intrinsics_to_depth(K_1920, (1920, 1440)), scale_intrinsics_to_depth(K_1600, (1600, 1200)), atol=1e-9)


def test_backproject_is_size_invariant() -> None:
    depth = np.full((config.DEPTH_HEIGHT, config.DEPTH_WIDTH), 2.0, dtype=np.float32)
    pose = np.eye(4)
    f = 1600 / 1920
    K_1600 = K_1920.copy()
    K_1600[0, 0] *= f; K_1600[1, 1] *= f; K_1600[0, 2] *= f; K_1600[1, 2] *= f
    p_a = backproject_filtered((1200.0, 800.0), depth, None, scale_intrinsics_to_depth(K_1920, (1920, 1440)), pose, image_size=(1920, 1440))
    p_b = backproject_filtered((1200.0 * f, 800.0 * f), depth, None, scale_intrinsics_to_depth(K_1600, (1600, 1200)), pose, image_size=(1600, 1200))
    assert p_a is not None and p_b is not None
    np.testing.assert_allclose(p_a, p_b, atol=1e-6)


def test_load_scan_reads_image_size_per_record(tmp_path: Path) -> None:
    (tmp_path / "poses").mkdir()
    rec = {
        "frame_id": 1, "timestamp": 0.0, "rgb_path": "rgb/f.jpg", "depth_path": "depth/f.depth",
        "camera_transform": np.eye(4).tolist(), "tracking_state": "normal",
        "intrinsics": {"fx": 1200.2, "fy": 1200.2, "cx": 804.6, "cy": 599.8, "width": 1600, "height": 1200},
    }
    legacy = dict(rec, frame_id=2, intrinsics={k: v for k, v in rec["intrinsics"].items() if k not in ("width", "height")})
    (tmp_path / "poses" / "poses.jsonl").write_text(json.dumps(rec) + "\n" + json.dumps(legacy) + "\n", encoding="utf-8")
    frames = load_scan(tmp_path)
    assert frames[0].image_size == (1600, 1200)
    assert frames[1].image_size == (1920, 1440)  # no width/height -> legacy default

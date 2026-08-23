"""db_build.py end-to-end 회귀 테스트.

실 iPhone 스캔 데이터 없이, 합성 scan(dc_vps_pipeline.testing)으로 실제 hloc
SuperPoint/NetVLAD 추출 + depth backproject 전체 경로를 검증한다. GPU/torch로
실제 모델을 돌리므로 다소 느리다(수십 초).
"""

from __future__ import annotations

import pickle
from pathlib import Path

import pytest

from dc_vps_pipeline.db_build import build_db
from dc_vps_pipeline.testing import FrameSpec, write_synthetic_scan

VALID_DEPTH = 2.0
OUT_OF_RANGE_DEPTH = 10.0  # config.MAX_DEPTH_METERS(5.0m) 초과
HIGH_CONFIDENCE = 2.0
LOW_CONFIDENCE = 0.0  # config.MIN_CONFIDENCE(1) 미만


@pytest.fixture(scope="module")
def kp_to_3d_db(tmp_path_factory: pytest.TempPathFactory) -> dict:
    """합성 scan을 한 번만 빌드해서 모든 테스트가 결과를 공유한다(추출이 느림)."""
    base = tmp_path_factory.mktemp("db_build")
    frame_specs = [
        FrameSpec(frame_id=0, depth_value=VALID_DEPTH, confidence_value=HIGH_CONFIDENCE),
        FrameSpec(frame_id=1, depth_value=VALID_DEPTH, confidence_value=LOW_CONFIDENCE),
        FrameSpec(frame_id=2, depth_value=OUT_OF_RANGE_DEPTH, confidence_value=HIGH_CONFIDENCE),
        FrameSpec(
            frame_id=3,
            depth_value=VALID_DEPTH,
            confidence_value=HIGH_CONFIDENCE,
            tracking_state="limited",
        ),
    ]
    write_synthetic_scan(base / "scan_test", frame_specs)
    build_db(base / "scan_test", base / "out")

    with (base / "out" / "kp_to_3d_db.pkl").open("rb") as f:
        return pickle.load(f)


def test_db_build_end_to_end(kp_to_3d_db: dict) -> None:
    # tracking_state != "normal"인 프레임은 DB에서 제외된다.
    assert set(kp_to_3d_db) == {"frame_0000.jpg", "frame_0001.jpg", "frame_0002.jpg"}

    for name, points in kp_to_3d_db.items():
        assert len(points) > 0, f"{name}: SuperPoint가 keypoint를 하나도 못 찾음"


def test_valid_depth_and_confidence_backprojects_correctly(kp_to_3d_db: dict) -> None:
    points = kp_to_3d_db["frame_0000.jpg"]
    valid = [p for p in points if p is not None]

    assert valid, "high-confidence/유효 depth 프레임에서 backproject된 포인트가 하나도 없음"
    # camera_transform이 identity이므로 world z는 depth 값과 정확히 같아야 한다.
    for p in valid:
        assert abs(p[2] - VALID_DEPTH) < 1e-3


def test_low_confidence_is_filtered_out(kp_to_3d_db: dict) -> None:
    points = kp_to_3d_db["frame_0001.jpg"]
    assert all(p is None for p in points)


def test_out_of_range_depth_is_filtered_out(kp_to_3d_db: dict) -> None:
    points = kp_to_3d_db["frame_0002.jpg"]
    assert all(p is None for p in points)

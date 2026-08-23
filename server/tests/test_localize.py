"""Localizer end-to-end 회귀 테스트.

pipeline과 동일한 합성 scan(dc_vps_pipeline.testing)으로 DB를 하나 빌드하고,
그 DB를 만든 것과 동일한 쿼리 이미지+intrinsics로 로컬라이즈한다. camera_transform이
identity인 프레임 하나로 DB를 만들었으므로, 같은 이미지를 쿼리하면 PnP가 복원하는
카메라 pose도 identity(translation=0, quaternion=[0,0,0,1])에 가까워야 한다 — 검색
(NetVLAD)/매칭(LightGlue)/PnP(pycolmap) 전체 경로에 대한 sanity check.
"""

from __future__ import annotations

import io
from pathlib import Path

import numpy as np
import pytest
from dc_vps_pipeline.db_build import build_db
from dc_vps_pipeline.testing import CX, CY, FX, FY, RGB_SIZE, FrameSpec, synthetic_rgb_texture, write_synthetic_scan
from PIL import Image

from app.localize import MIN_INLIERS, Localizer

VALID_DEPTH = 2.0
HIGH_CONFIDENCE = 2.0


def _jpeg_bytes(rgb_array: np.ndarray) -> bytes:
    buf = io.BytesIO()
    Image.fromarray(rgb_array).save(buf, format="JPEG", quality=95)
    return buf.getvalue()


def _localize(localizer: Localizer, image_bytes: bytes):
    return localizer.localize(
        image_bytes, fx=FX, fy=FY, cx=CX, cy=CY, width=RGB_SIZE[0], height=RGB_SIZE[1]
    )


@pytest.fixture(scope="module")
def localizer(tmp_path_factory: pytest.TempPathFactory) -> Localizer:
    base = tmp_path_factory.mktemp("localize_db")
    frame_specs = [
        FrameSpec(frame_id=0, depth_value=VALID_DEPTH, confidence_value=HIGH_CONFIDENCE)
    ]
    write_synthetic_scan(base / "scan_test", frame_specs)
    build_db(base / "scan_test", base / "out")
    return Localizer([base / "out"])


def test_localize_recovers_identity_pose_for_db_frame(localizer: Localizer) -> None:
    query_bytes = _jpeg_bytes(synthetic_rgb_texture())  # seed=42, DB 프레임과 동일 텍스처

    result = _localize(localizer, query_bytes)

    assert result.success, result.reason
    assert result.num_inliers >= MIN_INLIERS
    assert np.allclose(result.translation, [0.0, 0.0, 0.0], atol=0.1)
    # quaternion은 [qx,qy,qz,qw]; identity 회전이면 w가 (부호 무관) 1에 가까워야 한다.
    assert abs(abs(result.quaternion[3]) - 1.0) < 0.02
    assert np.allclose(result.quaternion[:3], [0.0, 0.0, 0.0], atol=0.02)


def test_localize_fails_for_unrelated_query_image(localizer: Localizer) -> None:
    query_bytes = _jpeg_bytes(synthetic_rgb_texture(seed=123))  # DB와 무관한 텍스처

    result = _localize(localizer, query_bytes)

    assert not result.success
    assert result.reason


def test_localize_raises_on_missing_db(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        Localizer([tmp_path / "does_not_exist"])

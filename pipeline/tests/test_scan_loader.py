"""scan_loader의 depth/confidence 로더가 v1(float32)와 v2(uint16 mm / uint8) 두
인코딩(scan-format/SCAN_FORMAT.md)을 같은 float32 배열로 읽는지 확인한다. GPU 불필요.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from dc_vps_pipeline.scan_loader import load_confidence_raw, load_depth_raw

W, H = 256, 192


def test_v1_float32_depth_and_confidence_round_trip(tmp_path: Path) -> None:
    depth = np.random.default_rng(0).uniform(0.3, 5.0, size=(H, W)).astype(np.float32)
    conf = np.random.default_rng(1).integers(0, 3, size=(H, W)).astype(np.float32)
    depth.tofile(tmp_path / "f.depth")
    conf.tofile(tmp_path / "f.conf")
    np.testing.assert_array_equal(load_depth_raw(tmp_path / "f.depth", W, H), depth)
    np.testing.assert_array_equal(load_confidence_raw(tmp_path / "f.conf", W, H), conf)


def test_v2_uint16_mm_depth_is_returned_in_metres(tmp_path: Path) -> None:
    mm = np.random.default_rng(2).integers(0, 6000, size=(H, W)).astype("<u2")
    mm[0, 0] = 0  # 미측정
    mm.tofile(tmp_path / "f.depth")
    out = load_depth_raw(tmp_path / "f.depth", W, H)
    assert out.dtype == np.float32 and out.shape == (H, W)
    np.testing.assert_allclose(out, mm.astype(np.float32) / 1000.0, rtol=0, atol=1e-6)
    assert out[0, 0] == 0.0  # 0 m -> MIN_DEPTH 필터가 걸러냄


def test_v2_uint8_confidence_is_returned_as_float32(tmp_path: Path) -> None:
    conf = np.random.default_rng(3).integers(0, 3, size=(H, W)).astype(np.uint8)
    conf.tofile(tmp_path / "f.conf")
    out = load_confidence_raw(tmp_path / "f.conf", W, H)
    assert out.dtype == np.float32
    np.testing.assert_array_equal(out, conf.astype(np.float32))
    # 소비자의 임계 비교가 v1과 똑같이 동작해야 한다
    assert ((out >= 1) == (conf >= 1)).all()


def test_wrong_size_is_rejected_loudly(tmp_path: Path) -> None:
    np.zeros(W * H * 3, dtype=np.uint8).tofile(tmp_path / "bad.depth")
    with pytest.raises(ValueError):
        load_depth_raw(tmp_path / "bad.depth", W, H)
    with pytest.raises(ValueError):
        load_confidence_raw(tmp_path / "bad.depth", W, H)

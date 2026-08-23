"""Localizer.add_room()/remove_room()/list_rooms() 회귀 테스트 -- room을 서버
재시작 없이 등록/해제할 수 있는지 검증한다 (server/README.md "room 라이프사이클" 참고).

DB 빌드(SuperPoint/NetVLAD 추출)는 한 번만 하고, 두 번째 room은 같은 산출물을
다른 디렉터리 이름으로 복사해서 만든다 -- room_id는 디렉터리 이름이라 그걸로
충분하고, 모델을 두 번 돌릴 필요가 없다.
"""

from __future__ import annotations

import io
import shutil
from pathlib import Path

import numpy as np
import pytest
from dc_vps_pipeline.db_build import build_db
from dc_vps_pipeline.testing import CX, CY, FX, FY, RGB_SIZE, FrameSpec, synthetic_rgb_texture, write_synthetic_scan
from PIL import Image

from app.localize import Localizer

VALID_DEPTH = 2.0
HIGH_CONFIDENCE = 2.0


def _jpeg_bytes(rgb_array: np.ndarray) -> bytes:
    buf = io.BytesIO()
    Image.fromarray(rgb_array).save(buf, format="JPEG", quality=95)
    return buf.getvalue()


def _query_bytes() -> bytes:
    return _jpeg_bytes(synthetic_rgb_texture())  # seed=42, DB 프레임과 동일 텍스처


@pytest.fixture(scope="module")
def db_dir_a(tmp_path_factory: pytest.TempPathFactory) -> Path:
    base = tmp_path_factory.mktemp("room_lifecycle_db")
    frame_specs = [FrameSpec(frame_id=0, depth_value=VALID_DEPTH, confidence_value=HIGH_CONFIDENCE)]
    write_synthetic_scan(base / "scan_test", frame_specs)
    out_dir = base / "scan_room_a"
    build_db(base / "scan_test", out_dir)
    return out_dir


@pytest.fixture()
def db_dir_b(db_dir_a: Path, tmp_path: Path) -> Path:
    out_dir = tmp_path / "scan_room_b"
    shutil.copytree(db_dir_a, out_dir)
    return out_dir


def test_starts_with_zero_rooms_allowed() -> None:
    localizer = Localizer([])
    assert localizer.list_rooms() == []

    result = localizer.localize(
        _query_bytes(), fx=FX, fy=FY, cx=CX, cy=CY, width=RGB_SIZE[0], height=RGB_SIZE[1]
    )
    assert not result.success
    assert result.reason == "검색 후보를 찾지 못함"


def test_add_room_then_localize_succeeds(db_dir_a: Path) -> None:
    localizer = Localizer([])
    room_id = localizer.add_room(db_dir_a)

    assert room_id == db_dir_a.name
    assert localizer.list_rooms() == [{"room_id": room_id, "num_images": 1}]

    result = localizer.localize(
        _query_bytes(), fx=FX, fy=FY, cx=CX, cy=CY, width=RGB_SIZE[0], height=RGB_SIZE[1]
    )
    assert result.success, result.reason
    assert result.room_id == room_id


def test_add_duplicate_room_id_rejected_without_replace(db_dir_a: Path) -> None:
    localizer = Localizer([db_dir_a])
    with pytest.raises(ValueError):
        localizer.add_room(db_dir_a, replace=False)


def test_add_duplicate_room_id_allowed_with_replace(db_dir_a: Path) -> None:
    localizer = Localizer([db_dir_a])
    room_id = localizer.add_room(db_dir_a, replace=True)
    assert room_id == db_dir_a.name
    assert len(localizer.list_rooms()) == 1


def test_add_missing_db_dir_raises(tmp_path: Path) -> None:
    localizer = Localizer([])
    with pytest.raises(FileNotFoundError):
        localizer.add_room(tmp_path / "does_not_exist")


def test_remove_room_then_localize_fails_again(db_dir_a: Path) -> None:
    localizer = Localizer([db_dir_a])
    room_id = db_dir_a.name

    localizer.remove_room(room_id)

    assert localizer.list_rooms() == []
    result = localizer.localize(
        _query_bytes(), fx=FX, fy=FY, cx=CX, cy=CY, width=RGB_SIZE[0], height=RGB_SIZE[1]
    )
    assert not result.success


def test_remove_unknown_room_raises(db_dir_a: Path) -> None:
    localizer = Localizer([db_dir_a])
    with pytest.raises(KeyError):
        localizer.remove_room("no_such_room")


def test_two_rooms_can_coexist_and_be_independently_removed(db_dir_a: Path, db_dir_b: Path) -> None:
    localizer = Localizer([db_dir_a])
    localizer.add_room(db_dir_b)

    room_ids = {r["room_id"] for r in localizer.list_rooms()}
    assert room_ids == {db_dir_a.name, db_dir_b.name}

    localizer.remove_room(db_dir_a.name)
    assert {r["room_id"] for r in localizer.list_rooms()} == {db_dir_b.name}

"""scan_jobs.py 회귀 테스트 -- 업로드된 zip -> DB 빌드 -> room 등록까지의 백그라운드
job 로직을 검증한다.

app.main(FastAPI 앱 전체)이 아니라 scan_jobs 모듈을 직접 부른다 -- app.main을
import하면 모듈 최상단에서 Localizer(DB_DIRS)가 즉시 실행되어(SuperPoint/NetVLAD/
LightGlue 모델 로딩) 이 파일과 무관한 무거운 초기화가 테스트마다 딸려 온다
(server/tests/의 다른 테스트들이 전부 Localizer를 직접 써서 이걸 피하는 것과 같은
이유 -- test_room_lifecycle.py 참고). scan_jobs.start_build_job()이 Localizer
인스턴스를 인자로 받게 설계한 것도 이 때문이다.

HTTP 레이어(라우트 자체의 요청 스트리밍, 상태 코드) 검증은 이 파일의 책임이
아니다 -- server/README.md의 curl 예시로 수동 확인한다.
"""

from __future__ import annotations

import time
import zipfile
from pathlib import Path

import pytest
from dc_vps_pipeline.testing import FrameSpec, write_synthetic_scan

from app import scan_jobs
from app.localize import Localizer

VALID_DEPTH = 2.0
HIGH_CONFIDENCE = 2.0


def _zip_scan_dir(scan_dir: Path, zip_path: Path) -> None:
    """ios-capture의 ZipArchiver.zip(directory:to:)과 동일하게, scan_dir 자체를
    루트로 압축한다(감싸는 scan_<name>/ 폴더 없이 rgb/, depth/, poses/, manifest.json이
    zip 루트에 바로 온다)."""
    with zipfile.ZipFile(zip_path, "w") as zf:
        for path in scan_dir.rglob("*"):
            if path.is_file():
                zf.write(path, arcname=path.relative_to(scan_dir).as_posix())


def _wait_for_job(scan_name: str, *, timeout: float = 60.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        job = scan_jobs.get_job(scan_name)
        assert job is not None
        if job["status"] in ("done", "failed"):
            return job
        time.sleep(0.1)
    raise TimeoutError(f"'{scan_name}' job이 {timeout}초 안에 끝나지 않음")


@pytest.fixture()
def scan_zip(tmp_path: Path) -> Path:
    scan_dir = tmp_path / "raw_scan"
    frame_specs = [FrameSpec(frame_id=0, depth_value=VALID_DEPTH, confidence_value=HIGH_CONFIDENCE)]
    write_synthetic_scan(scan_dir, frame_specs)
    zip_path = tmp_path / "upload.zip"
    _zip_scan_dir(scan_dir, zip_path)
    return zip_path


def test_upload_builds_and_registers_room(scan_zip: Path, tmp_path: Path) -> None:
    localizer = Localizer([])
    registered = []

    scan_jobs.start_build_job(
        "scan_test_upload",
        scan_zip,
        replace=False,
        localizer=localizer,
        uploads_dir=tmp_path / "uploads",
        output_dir=tmp_path / "outputs" / "scan_test_upload",
        on_registered=lambda: registered.append(True),
    )

    job = _wait_for_job("scan_test_upload")
    assert job["status"] == "done", job.get("error")
    assert job["room_id"] == "scan_test_upload"
    assert registered == [True]
    assert [r["room_id"] for r in localizer.list_rooms()] == ["scan_test_upload"]
    # zip은 처리 후 정리돼야 한다(디스크에 계속 쌓이면 안 됨).
    assert not scan_zip.exists()


def test_upload_is_rejected_while_busy(scan_zip: Path, tmp_path: Path) -> None:
    localizer = Localizer([])
    scan_jobs.start_build_job(
        "scan_busy_a",
        scan_zip,
        replace=False,
        localizer=localizer,
        uploads_dir=tmp_path / "uploads",
        output_dir=tmp_path / "outputs" / "scan_busy_a",
        on_registered=lambda: None,
    )

    assert scan_jobs.is_busy()
    with pytest.raises(scan_jobs.BusyError):
        scan_jobs.start_build_job(
            "scan_busy_b",
            scan_zip,
            replace=False,
            localizer=localizer,
            uploads_dir=tmp_path / "uploads",
            output_dir=tmp_path / "outputs" / "scan_busy_b",
            on_registered=lambda: None,
        )

    _wait_for_job("scan_busy_a")
    assert not scan_jobs.is_busy()


def test_replace_true_allows_rebuilding_same_room(scan_zip: Path, tmp_path: Path) -> None:
    localizer = Localizer([])

    scan_jobs.start_build_job(
        "scan_replace_test",
        scan_zip,
        replace=False,
        localizer=localizer,
        uploads_dir=tmp_path / "uploads",
        output_dir=tmp_path / "outputs" / "scan_replace_test",
        on_registered=lambda: None,
    )
    first = _wait_for_job("scan_replace_test")
    assert first["status"] == "done"

    # 첫 번째 job이 원본 zip을 이미 지웠으므로(정리 확인은 다른 테스트에서 함),
    # scan_zip 픽스처가 만들어둔 raw_scan/을 다시 zip해서 재사용한다.
    zip_path_2 = tmp_path / "upload2.zip"
    _zip_scan_dir(tmp_path / "raw_scan", zip_path_2)

    scan_jobs.start_build_job(
        "scan_replace_test",
        zip_path_2,
        replace=True,
        localizer=localizer,
        uploads_dir=tmp_path / "uploads",
        output_dir=tmp_path / "outputs" / "scan_replace_test",
        on_registered=lambda: None,
    )
    second = _wait_for_job("scan_replace_test")
    assert second["status"] == "done", second.get("error")
    assert [r["room_id"] for r in localizer.list_rooms()] == ["scan_replace_test"]


def test_get_job_unknown_scan_returns_none() -> None:
    assert scan_jobs.get_job("no_such_scan_ever") is None

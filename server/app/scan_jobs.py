"""폰이 올린 스캔 zip -> VPS DB 빌드 -> room 등록까지 한 번에 처리하는 백그라운드
작업. 큐가 아니라 "지금 하나 돌고 있나" 플래그다 -- GPU가 하나뿐이라 빌드는 어차피
한 번에 하나만 의미가 있고, 현장 운영자가 가끔 의도적으로 올리는 작업이라 두 번째
요청은 조용히 줄 세우기보다 바로 409로 거절하는 쪽이 맞다(main.py에서 처리).

Localizer(app.main의 전역 싱글턴)를 여기서 직접 import하지 않는다 -- 그러면
이 모듈을 테스트할 때마다 SuperPoint/NetVLAD/LightGlue 모델 로딩이 딸려 온다
(server/tests/의 기존 테스트들이 전부 피하는 것과 같은 이유). 대신
start_build_job()이 Localizer 인스턴스와 등록 후 콜백을 인자로 받는다 -- 테스트는
이 모듈만 따로, 가벼운 Localizer([])로 검증할 수 있다.
"""

from __future__ import annotations

import shutil
import threading
import zipfile
from pathlib import Path
from typing import Callable

from dc_vps_pipeline import db_build

from .localize import Localizer
from .gpu_lock import GPU_LOCK

_lock = threading.Lock()
_current_scan_name: str | None = None
_jobs: dict[str, dict] = {}


class BusyError(RuntimeError):
    """다른 스캔 빌드가 이미 진행 중일 때."""


def is_busy() -> bool:
    with _lock:
        return _current_scan_name is not None


def get_job(scan_name: str) -> dict | None:
    with _lock:
        job = _jobs.get(scan_name)
        return dict(job) if job is not None else None


def start_build_job(
    scan_name: str,
    zip_path: Path,
    *,
    replace: bool,
    localizer: Localizer,
    uploads_dir: Path,
    output_dir: Path,
    on_registered: Callable[[], None],
) -> None:
    """빌드를 백그라운드 스레드로 시작한다. 이미 다른 빌드가 진행 중이면
    (is_busy() 사전 체크와 실제 시작 사이의 경쟁 상태까지 포함해서) BusyError를
    던진다 -- 호출부(main.py)가 이걸 409로 변환한다."""
    with _lock:
        global _current_scan_name
        if _current_scan_name is not None:
            raise BusyError(f"'{_current_scan_name}' 빌드가 이미 진행 중입니다")
        _current_scan_name = scan_name
        _jobs[scan_name] = {
            "scan_name": scan_name,
            "status": "unzipping",
            "room_id": None,
            "error": None,
        }

    thread = threading.Thread(
        target=_run_job,
        args=(scan_name, zip_path, replace, localizer, uploads_dir, output_dir, on_registered),
        daemon=True,
    )
    thread.start()


def _run_job(
    scan_name: str,
    zip_path: Path,
    replace: bool,
    localizer: Localizer,
    uploads_dir: Path,
    output_dir: Path,
    on_registered: Callable[[], None],
) -> None:
    global _current_scan_name
    try:
        _set_status(scan_name, "unzipping")
        scan_dir = _extract_scan_zip(zip_path, uploads_dir, scan_name)

        _set_status(scan_name, "building")
        with GPU_LOCK:
            db_build.build_db(scan_dir, output_dir)

        _set_status(scan_name, "registering")
        room_id = localizer.add_room(output_dir, replace=replace)
        on_registered()

        with _lock:
            _jobs[scan_name].update(status="done", room_id=room_id)
    except Exception as error:  # noqa: BLE001 -- 원인 무관하게 job을 failed로 남겨야 폰이 폴링을 끝낼 수 있다
        with _lock:
            _jobs[scan_name].update(status="failed", error=str(error))
    finally:
        zip_path.unlink(missing_ok=True)
        with _lock:
            _current_scan_name = None


def _set_status(scan_name: str, status: str) -> None:
    with _lock:
        _jobs[scan_name]["status"] = status


def _extract_scan_zip(zip_path: Path, uploads_dir: Path, scan_name: str) -> Path:
    """업로드된 zip은 ios-capture의 ZipArchiver가 project.url 자체를 루트로 압축한
    것이라(감싸는 scan_<name>/ 폴더가 zip 안에 없음) 여기서 직접 그 폴더를 만들어서
    풀어야 한다."""
    scan_dir = uploads_dir / scan_name
    if scan_dir.exists():
        shutil.rmtree(scan_dir)
    scan_dir.mkdir(parents=True)
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(scan_dir)
    return scan_dir

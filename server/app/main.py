"""VL(재측위) 로컬라이제이션 서버.

로봇/iPhone 카메라가 이미지를 보내면 사전에 빌드된 DB(kp_to_3d_db)에 매칭해서
world 좌표계 기준 6DoF pose를 리턴한다. Nav2 통합 시 robot_localization EKF의
한 입력 소스로 fusion하거나 amcl pose 초기화/보정에 사용한다.

여러 방(room)의 DB를 동시에 로드할 수 있다 — `DC_VPS_DB_DIRS`(콤마로 구분된 여러
경로)가 있으면 그걸 쓰고, 없으면 기존처럼 `DC_VPS_DB_DIR` 하나만 쓴다. 여러 방일 때
쿼리 이미지가 어느 방과 매칭됐는지는 응답의 `room_id`로 알 수 있다 (각 DB 디렉터리
이름 — 보통 scan_<name>). ros2_ws/src/dc_vps_bridge가 room_id별로 다른
scan_basemap_<room_id> tf를 찾아 쓰는 식으로 여러 방을 하나의 로봇 map 프레임에
이어붙일 수 있다 (pipeline/README.md 참고).

room을 추가/제거할 때마다 서버를 재시작해야 했던 문제(그때마다 SuperPoint/NetVLAD/
LightGlue 모델을 다시 로드하고, 그 사이 다른 room 쿼리도 전부 끊김) 때문에 `/rooms`
admin API로 이미 빌드된 DB 디렉터리를 런타임에 등록/해제할 수 있게 했다 (모델은
그대로 두고 room 데이터만 교체 -- 모델 재로드가 없으니 무겁지 않다). 등록 상태는
`DC_VPS_ROOMS_MANIFEST`(기본 `rooms_manifest.json`)에 저장돼서 재시작해도 유지된다.
이 API는 이미 빌드된 DB를 "등록"만 한다 -- 원본 스캔에서 DB를 새로 빌드하는 건
여전히 `pipeline/dc_vps_pipeline/db_build.py`(또는 `orchestrate.py`)를 따로 돌려야
한다.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from pydantic import BaseModel

from . import scan_jobs
from .frames import frames_from_env
from .localize import Localizer

app = FastAPI(title="dc-vps localization server")

_SCAN_NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def _env_db_dirs() -> list[Path]:
    multi = os.environ.get("DC_VPS_DB_DIRS")
    if multi:
        return [Path(p.strip()) for p in multi.split(",") if p.strip()]
    single = os.environ.get("DC_VPS_DB_DIR")
    return [Path(single)] if single else []


def _manifest_path() -> Path:
    return Path(os.environ.get("DC_VPS_ROOMS_MANIFEST", "rooms_manifest.json"))


def _uploads_dir() -> Path:
    # 업로드된 zip을 풀어놓는 곳. pipeline/outputs와 같은 상위(../pipeline/)에 둔다 --
    # 기존 DB 디렉터리들이 이미 그렇게 상대경로로(../pipeline/outputs/<scan_name>)
    # manifest에 저장돼 있어서(add_room 결과), 같은 컨벤션을 따른다.
    return Path(os.environ.get("DC_VPS_UPLOADS_DIR", "../pipeline/uploads"))


def _pipeline_outputs_dir() -> Path:
    return Path(os.environ.get("DC_VPS_PIPELINE_OUTPUTS_DIR", "../pipeline/outputs"))


def _load_manifest(path: Path) -> list[Path] | None:
    if not path.exists():
        return None
    with path.open("r", encoding="utf-8") as f:
        return [Path(p) for p in json.load(f)]


def _save_manifest(path: Path, db_dirs: list[Path]) -> None:
    with path.open("w", encoding="utf-8") as f:
        json.dump([str(p) for p in db_dirs], f, indent=2)


def _current_db_dirs(loc: Localizer) -> list[Path]:
    # _RoomDB는 db_dir 자체가 아니라 그 밑의 h5 파일 경로만 들고 있으므로 부모로 역산한다.
    return [room.features_path.parent for room in loc.rooms.values()]


def _resolve_initial_db_dirs() -> list[Path]:
    """서버 기동 시 로드할 DB 목록을 정한다. manifest가 있으면 그게 현재 진실
    (admin API로 바뀐 상태를 재시작 후에도 유지) -- 없으면 기존 env var 방식으로
    시드하고, 그 결과를 manifest에 처음 저장해서 다음 재시작부터는 manifest를 쓴다."""
    manifest_path = _manifest_path()
    manifest_dirs = _load_manifest(manifest_path)
    if manifest_dirs is not None:
        return manifest_dirs

    env_dirs = _env_db_dirs()
    if not env_dirs:
        env_dirs = [Path("outputs")] if Path("outputs").exists() else []
    _save_manifest(manifest_path, env_dirs)
    return env_dirs


DB_DIRS = _resolve_initial_db_dirs()
localizer = Localizer(DB_DIRS)
# 방별 ScanAlignment(선택, DC_VPS_GROUP_ALIGNMENT) -- /localize 응답의 frame 필드. app/frames.py 참고.
frames = frames_from_env()


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


class AddRoomRequest(BaseModel):
    db_dir: str
    replace: bool = False  # 이미 로드된 room_id를 덮어쓸지 (재스캔 후 DB 갱신용)


@app.get("/rooms")
def list_rooms() -> dict:
    return {"rooms": localizer.list_rooms(), "frames": frames.describe()}


@app.post("/rooms")
def add_room(body: AddRoomRequest) -> dict:
    """이미 db_build.py로 빌드된 DB 디렉터리를 서버 재시작 없이 등록한다.
    room_id는 그 디렉터리 이름 -- pipeline/README.md의 db_build.py 실행 결과를
    그대로 가리키면 된다."""
    try:
        room_id = localizer.add_room(Path(body.db_dir), replace=body.replace)
    except FileNotFoundError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    except ValueError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error

    _save_manifest(_manifest_path(), _current_db_dirs(localizer))
    return {"room_id": room_id, "rooms": localizer.list_rooms()}


@app.delete("/rooms/{room_id}")
def remove_room(room_id: str) -> dict:
    try:
        localizer.remove_room(room_id)
    except KeyError as error:
        raise HTTPException(status_code=404, detail=str(error)) from error

    _save_manifest(_manifest_path(), _current_db_dirs(localizer))
    return {"rooms": localizer.list_rooms()}


@app.post("/scans", status_code=202)
async def upload_scan(request: Request, scan_name: str, replace: bool = False) -> dict:
    """폰이 스캔 폴더를 zip으로 그대로 올리면(raw body, Content-Type: application/zip)
    서버가 풀어서 DB를 빌드하고 room으로 등록까지 한 번에 끝낸다 -- 지금까지는
    db_build.py를 손으로 돌리고 그 결과를 /rooms로 등록하는 2단계 수동 흐름이었다.

    multipart가 아니라 raw body인 이유: 폰 앱에 네트워킹 코드가 아직 하나도 없어서
    (이게 첫 HTTP 호출) multipart를 손으로 구현하는 위험을 피했다. 스캔은 1~2GB일
    수 있어서 request.body()로 메모리에 통째로 올리지 않고 스트리밍으로 디스크에
    바로 쓴다(/localize의 UploadFile.read()는 사진 한 장짜리라 문제없지만 이 크기엔
    안 맞는 패턴).

    job 상태는 GET /scans/{scan_name}으로 폴링한다. job 식별자는 별도 UUID가 아니라
    scan_name 자체 -- 클라이언트가 업로드 전부터 이미 아는 값이라 응답을 파싱해서
    id를 얻을 필요가 없다."""
    if not _SCAN_NAME_RE.match(scan_name):
        raise HTTPException(status_code=400, detail="scan_name은 영숫자/_/- 만 허용됩니다")
    if not replace and scan_name in {r["room_id"] for r in localizer.list_rooms()}:
        raise HTTPException(
            status_code=409,
            detail=f"room_id '{scan_name}'가 이미 등록돼 있습니다 (재업로드하려면 replace=true)",
        )
    # 바디(최대 1~2GB)를 다 받기 전에 빨리 거절한다. start_build_job()이 시작 시점에
    # 한 번 더(락으로 원자적으로) 검사하므로 이 사이의 경쟁 상태는 안전하다.
    if scan_jobs.is_busy():
        raise HTTPException(status_code=409, detail="다른 스캔 빌드가 진행 중입니다. 잠시 후 다시 시도하세요")

    uploads_dir = _uploads_dir()
    uploads_dir.mkdir(parents=True, exist_ok=True)
    zip_path = uploads_dir / f"{scan_name}.zip"
    with zip_path.open("wb") as f:
        async for chunk in request.stream():
            f.write(chunk)

    try:
        scan_jobs.start_build_job(
            scan_name,
            zip_path,
            replace=replace,
            localizer=localizer,
            uploads_dir=uploads_dir,
            output_dir=_pipeline_outputs_dir() / scan_name,
            on_registered=lambda: _save_manifest(_manifest_path(), _current_db_dirs(localizer)),
        )
    except scan_jobs.BusyError as error:
        zip_path.unlink(missing_ok=True)
        raise HTTPException(status_code=409, detail=str(error)) from error

    return {"scan_name": scan_name, "status": "queued"}


@app.get("/scans/{scan_name}")
def get_scan_status(scan_name: str) -> dict:
    job = scan_jobs.get_job(scan_name)
    if job is None:
        raise HTTPException(status_code=404, detail=f"scan '{scan_name}'에 대한 job이 없습니다")
    return job


@app.post("/localize")
async def localize(
    image: UploadFile = File(...),
    fx: float = Form(...),
    fy: float = Form(...),
    cx: float = Form(...),
    cy: float = Form(...),
    width: int = Form(...),
    height: int = Form(...),
) -> dict:
    image_bytes = await image.read()
    # localizer.localize()는 GPU 추론 + CPU PnP+RANSAC으로 수백 ms~1초 가까이 블로킹
    # 되는 동기 호출이다. await 없이 직접 부르면 그동안 이벤트 루프 전체가 막혀서
    # 다른 요청(다른 room 쿼리는 물론 /health, /rooms까지)을 하나도 못 받는다 --
    # asyncio.to_thread로 워커 스레드에 넘겨서 이벤트 루프는 다른 요청을 계속 받게
    # 한다. pycolmap/torch 쪽 실제 연산은 여전히 순차적일 수 있지만(GPU는 디바이스
    # 하나, PnP도 GIL을 오래 붙잡음), 최소한 요청 수락/헬스체크가 죽지 않고 CPU
    # 구간(PnP)과 다른 요청의 GPU 구간이 겹칠 여지가 생긴다.
    result = await asyncio.to_thread(
        localizer.localize, image_bytes, fx=fx, fy=fy, cx=cx, cy=cy, width=width, height=height
    )

    if not result.success:
        raise HTTPException(status_code=422, detail=result.reason or "localization failed")

    return {
        "room_id": result.room_id,
        "translation": result.translation,
        "quaternion": result.quaternion,
        "num_inliers": result.num_inliers,
        "runner_up_room_id": result.runner_up_room_id,
        "runner_up_inliers": result.runner_up_inliers,
        # 이 room 을 그룹 기준 좌표계로 옮기는 ScanAlignment (그룹 정렬이 설정된 경우만).
        "frame": frames.frame_for(result.room_id),
    }

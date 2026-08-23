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
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from pydantic import BaseModel

from .localize import Localizer

app = FastAPI(title="dc-vps localization server")


def _env_db_dirs() -> list[Path]:
    multi = os.environ.get("DC_VPS_DB_DIRS")
    if multi:
        return [Path(p.strip()) for p in multi.split(",") if p.strip()]
    single = os.environ.get("DC_VPS_DB_DIR")
    return [Path(single)] if single else []


def _manifest_path() -> Path:
    return Path(os.environ.get("DC_VPS_ROOMS_MANIFEST", "rooms_manifest.json"))


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


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


class AddRoomRequest(BaseModel):
    db_dir: str
    replace: bool = False  # 이미 로드된 room_id를 덮어쓸지 (재스캔 후 DB 갱신용)


@app.get("/rooms")
def list_rooms() -> dict:
    return {"rooms": localizer.list_rooms()}


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
    }

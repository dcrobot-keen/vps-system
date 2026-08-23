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
"""

from __future__ import annotations

import os
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, UploadFile

from .localize import Localizer

app = FastAPI(title="dc-vps localization server")


def _resolve_db_dirs() -> list[Path]:
    multi = os.environ.get("DC_VPS_DB_DIRS")
    if multi:
        return [Path(p.strip()) for p in multi.split(",") if p.strip()]
    return [Path(os.environ.get("DC_VPS_DB_DIR", "outputs"))]


DB_DIRS = _resolve_db_dirs()
localizer = Localizer(DB_DIRS)


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


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
    result = localizer.localize(
        image_bytes, fx=fx, fy=fy, cx=cx, cy=cy, width=width, height=height
    )

    if not result.success:
        raise HTTPException(status_code=422, detail=result.reason or "localization failed")

    return {
        "room_id": result.room_id,
        "translation": result.translation,
        "quaternion": result.quaternion,
        "num_inliers": result.num_inliers,
    }

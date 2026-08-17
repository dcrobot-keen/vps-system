"""VL(재측위) 로컬라이제이션 서버.

로봇/iPhone 카메라가 이미지를 보내면 사전에 빌드된 DB(kp_to_3d_db)에 매칭해서
world 좌표계 기준 6DoF pose를 리턴한다. Nav2 통합 시 robot_localization EKF의
한 입력 소스로 fusion하거나 amcl pose 초기화/보정에 사용한다.
"""

from __future__ import annotations

import os
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, UploadFile

from .localize import Localizer

app = FastAPI(title="dc-vps localization server")

DB_DIR = Path(os.environ.get("DC_VPS_DB_DIR", "outputs"))
localizer = Localizer(DB_DIR)


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
        "translation": result.translation,
        "quaternion": result.quaternion,
        "num_inliers": result.num_inliers,
    }

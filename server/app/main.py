"""VL(재측위) 로컬라이제이션 서버.

로봇/iPhone 카메라가 이미지를 보내면 사전에 빌드된 DB(kp_to_3d_db)에 매칭해서
world 좌표계 기준 6DoF pose를 리턴한다. Nav2 통합 시 robot_localization EKF의
한 입력 소스로 fusion하거나 amcl pose 초기화/보정에 사용한다.
"""

from __future__ import annotations

import os
from pathlib import Path

import pycolmap
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
    """쿼리 카메라 intrinsics(fx/fy/cx/cy, 쿼리 이미지 해상도 기준)는 호출자가 함께 보내야 한다.

    DB를 만든 스캔 카메라와 쿼리 카메라(로봇/iPhone)의 렌즈/해상도가 다를 수 있어
    intrinsics를 서버가 추정하지 않는다.
    """
    image_bytes = await image.read()
    camera = pycolmap.Camera(model="PINHOLE", width=width, height=height, params=[fx, fy, cx, cy])

    result = localizer.localize(image_bytes, camera)

    if not result.success:
        raise HTTPException(status_code=422, detail=result.reason or "localization failed")

    return {
        "translation": result.translation,
        "quaternion": result.quaternion,
        "num_inliers": result.num_inliers,
    }

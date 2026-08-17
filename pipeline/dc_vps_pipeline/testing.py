"""테스트용 합성 scan_<name>/ 폴더 생성기.

실제 iPhone 캡처(ios-capture) 없이 db_build.py의 hloc 추출 -> backproject
파이프라인, 그리고 server의 쿼리 로컬라이제이션(SuperPoint/NetVLAD/LightGlue/PnP)을
end-to-end로 검증하기 위한 fixture. dc_vps_pipeline 패키지 안에 두어 pipeline과
server 양쪽 테스트(각자의 venv에 editable install)에서 재사용한다.

RGB는 SuperPoint가 코너를 안정적으로 검출하면서도, 체커보드처럼 주기적인 패턴이
LightGlue 매칭에서 반복 대응(반대편 대칭 코너로 잘못 매칭)을 일으키지 않도록
시드 고정된 랜덤 블록 텍스처를 사용한다.

각 프레임은 depth/confidence를 상수값으로 채운다. camera_transform이 identity인
프레임에서는 backproject된 3D 포인트의 world z 좌표가 그대로 depth 값과 같아야
하므로(p_world = I @ p_cam), 이를 이용해 backproject 정확성을 직접 검증할 수 있다.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

from dc_vps_pipeline import config

# scan 데이터는 config.py가 가정하는 RGB/depth 해상도와 반드시 일치해야 한다.
# SCALE_X/SCALE_Y가 config 상수로 고정되어 있어, 실제 이미지 크기가 다르면
# keypoint <-> depth 정합이 깨진다.
RGB_SIZE = (config.RGB_WIDTH, config.RGB_HEIGHT)
DEPTH_SIZE = (config.DEPTH_WIDTH, config.DEPTH_HEIGHT)

# 쿼리 쪽 테스트(server)에서 pycolmap.Camera를 동일하게 구성할 수 있도록 노출.
FX = FY = 1000.0
CX, CY = RGB_SIZE[0] / 2, RGB_SIZE[1] / 2


@dataclass
class FrameSpec:
    frame_id: int
    depth_value: float
    confidence_value: float
    tracking_state: str = "normal"
    translation: tuple[float, float, float] = (0.0, 0.0, 0.0)


def synthetic_rgb_texture(square: int = 48, seed: int = 42) -> np.ndarray:
    """시드 고정 랜덤 블록 텍스처. square는 RGB_SIZE를 나누어떨어뜨려야 한다."""
    w, h = RGB_SIZE
    rng = np.random.RandomState(seed)
    blocks = rng.randint(0, 256, size=(h // square, w // square)).astype(np.uint8)
    pattern = np.kron(blocks, np.ones((square, square), dtype=np.uint8))
    return np.stack([pattern] * 3, axis=-1)


def write_synthetic_scan(scan_dir: Path, frame_specs: list[FrameSpec]) -> None:
    rgb_dir = scan_dir / "rgb"
    depth_dir = scan_dir / "depth"
    poses_dir = scan_dir / "poses"
    for d in (rgb_dir, depth_dir, poses_dir):
        d.mkdir(parents=True, exist_ok=True)

    rgb_array = synthetic_rgb_texture()

    fx, fy, cx, cy = FX, FY, CX, CY

    lines = []
    for spec in frame_specs:
        name = f"frame_{spec.frame_id:04d}"

        rgb_path = rgb_dir / f"{name}.jpg"
        Image.fromarray(rgb_array).save(rgb_path, quality=95)

        depth_path = depth_dir / f"{name}.depth"
        depth = np.full(DEPTH_SIZE[::-1], spec.depth_value, dtype=np.float32)
        depth.tofile(depth_path)

        conf_path = depth_dir / f"{name}.conf"
        confidence = np.full(DEPTH_SIZE[::-1], spec.confidence_value, dtype=np.float32)
        confidence.tofile(conf_path)

        camera_transform = np.eye(4)
        camera_transform[:3, 3] = spec.translation

        record = {
            "frame_id": spec.frame_id,
            "timestamp": float(spec.frame_id),
            "rgb_path": f"rgb/{name}.jpg",
            "depth_path": f"depth/{name}.depth",
            "tracking_state": spec.tracking_state,
            "intrinsics": {"fx": fx, "fy": fy, "cx": cx, "cy": cy},
            "camera_transform": camera_transform.tolist(),
        }
        lines.append(json.dumps(record))

    (poses_dir / "poses.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")

"""ios-capture 앱이 export한 scan_<name>/ 폴더를 파싱한다."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np


@dataclass
class ScanFrame:
    frame_id: int
    timestamp: float
    rgb_path: Path
    depth_path: Path
    camera_transform: np.ndarray  # 4x4 camera-to-world
    intrinsics: np.ndarray  # 3x3, 저장된 RGB 이미지 해상도 기준
    tracking_state: str
    # 저장된 RGB 이미지의 (width, height). intrinsics와 같은 해상도다. 2026-09-05부터
    # 앱이 긴 변 1600px로 저장하므로 (1600, 1200); 옛 스캔은 (1920, 1440). depth 해상도로
    # 내리는 스케일은 반드시 이 값으로 계산한다(config의 RGB_* 상수는 옛 스캔 폴백).
    image_size: tuple[int, int] = (1920, 1440)


def load_scan(scan_dir: Path, valid_only: bool = True) -> list[ScanFrame]:
    """poses.jsonl을 읽어 ScanFrame 리스트를 반환한다.

    valid_only=True면 tracking_state가 "normal"이 아닌 프레임은 제외한다
    (pose 신뢰도가 낮아 DB에 넣으면 안 됨).
    """
    poses_path = scan_dir / "poses" / "poses.jsonl"
    frames: list[ScanFrame] = []

    with poses_path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)

            if valid_only and record["tracking_state"] != "normal":
                continue

            intr = record["intrinsics"]
            K = np.array(
                [
                    [intr["fx"], 0.0, intr["cx"]],
                    [0.0, intr["fy"], intr["cy"]],
                    [0.0, 0.0, 1.0],
                ]
            )

            frames.append(
                ScanFrame(
                    frame_id=record["frame_id"],
                    timestamp=record["timestamp"],
                    rgb_path=scan_dir / record["rgb_path"],
                    depth_path=scan_dir / record["depth_path"],
                    camera_transform=np.array(record["camera_transform"]),
                    intrinsics=K,
                    tracking_state=record["tracking_state"],
                    image_size=(int(intr.get("width", 1920)), int(intr.get("height", 1440))),
                )
            )

    return frames


def load_depth_raw(depth_path: Path, width: int, height: int) -> np.ndarray:
    """`.depth` -> float32 미터 (height, width). 두 인코딩을 파일 크기로 구분한다
    (scan-format/SCAN_FORMAT.md "depth/*.depth"): v1 float32 미터(4·w·h 바이트),
    v2 uint16 little-endian 밀리미터(2·w·h 바이트, 0 = 미측정 -> 0.0 m로 두면 기존
    MIN_DEPTH 필터가 그대로 걸러낸다)."""
    raw = np.fromfile(depth_path, dtype=np.uint8)
    n = width * height
    if raw.size == 4 * n:
        return raw.view(np.float32).reshape(height, width)
    if raw.size == 2 * n:
        return raw.view("<u2").reshape(height, width).astype(np.float32) / 1000.0
    raise ValueError(f"{depth_path}: {raw.size}바이트 -- {height}x{width} float32({4 * n}) 또는 uint16({2 * n})이어야 함")


def load_confidence_raw(conf_path: Path, width: int, height: int) -> np.ndarray:
    """`.conf` -> float32 (height, width), 값 0/1/2. v1은 float32로 저장된 값(4·w·h),
    v2는 uint8 원본(w·h). 소비자는 늘 float32 배열을 받으므로 `>= MIN_CONFIDENCE`
    비교가 두 버전에서 같게 동작한다."""
    raw = np.fromfile(conf_path, dtype=np.uint8)
    n = width * height
    if raw.size == 4 * n:
        return raw.view(np.float32).reshape(height, width)
    if raw.size == n:
        return raw.reshape(height, width).astype(np.float32)
    raise ValueError(f"{conf_path}: {raw.size}바이트 -- {height}x{width} float32({4 * n}) 또는 uint8({n})이어야 함")

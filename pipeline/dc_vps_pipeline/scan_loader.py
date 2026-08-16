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
    intrinsics: np.ndarray  # 3x3, RGB 해상도 기준
    tracking_state: str


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
                )
            )

    return frames


def load_depth_raw(depth_path: Path, width: int, height: int) -> np.ndarray:
    """Float32 raw depth 파일(row-major, width x height)을 로드한다."""
    return np.fromfile(depth_path, dtype=np.float32).reshape(height, width)

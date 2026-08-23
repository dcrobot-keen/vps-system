"""scan_<name>/ 폴더 -> world-frame 포인트클라우드(PLY).

`db_build.py`가 SuperPoint keypoint 위치만 backproject하는 것과 달리, 여기서는 각
프레임의 depth 전체를 backproject해서 실내 공간의 포인트클라우드를 만든다. 이
포인트클라우드는 `scan-to-map-studio`(https://github.com/dcrobot-keen/scan-to-map-studio)
프로젝트의 `scripts/remove_ceiling.py` 입력으로 그대로 쓸 수 있다 — 같은 스캔에서
뽑은 포인트클라우드라 hloc VPS DB(pipeline/db_build.py)와 world 좌표계 원점/방향이
동일하고, 그래서 scan-to-map-studio가 계산하는 `scan_basemap <-> map` ROS tf를
VPS pose에도 그대로 적용할 수 있다.

좌표계 변환: ARKit world 좌표계는 Y-up(오른손 좌표계)인데, scan-to-map-studio의
파이프라인(`studio/usdz_import.py`의 `_convert_to_zup`과 동일 관례)은 Z-up meters를
기대한다. 그래서 축을 (x, y, z) -> (x, -z, y)로 바꾼다.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image

from . import config
from .geometry import scale_intrinsics_to_depth
from .scan_loader import ScanFrame, load_depth_raw, load_scan


def _sample_rgb_colors(rgb_path: Path, u_depth: np.ndarray, v_depth: np.ndarray) -> np.ndarray:
    """depth 해상도 좌표(u_depth, v_depth)에 대응하는 RGB 픽셀을 nearest-neighbor로 샘플링한다."""
    image = np.asarray(Image.open(rgb_path).convert("RGB"))
    u_rgb = np.clip(np.round(u_depth / config.SCALE_X).astype(np.int64), 0, image.shape[1] - 1)
    v_rgb = np.clip(np.round(v_depth / config.SCALE_Y).astype(np.int64), 0, image.shape[0] - 1)
    return image[v_rgb, u_rgb]


def backproject_frame_dense(frame: ScanFrame) -> tuple[np.ndarray, np.ndarray | None]:
    """프레임의 depth 전체를 confidence/거리 필터링 후 world 좌표(ARKit Y-up)로 backproject한다."""
    depth = load_depth_raw(frame.depth_path, config.DEPTH_WIDTH, config.DEPTH_HEIGHT)
    confidence_path = frame.depth_path.with_suffix(".conf")
    confidence = (
        load_depth_raw(confidence_path, config.DEPTH_WIDTH, config.DEPTH_HEIGHT)
        if confidence_path.exists()
        else None
    )

    valid = (depth > config.MIN_DEPTH_METERS) & (depth <= config.MAX_DEPTH_METERS)
    if confidence is not None:
        valid &= confidence >= config.MIN_CONFIDENCE

    rows, cols = np.indices(depth.shape)
    v = rows[valid].astype(np.float64)
    u = cols[valid].astype(np.float64)
    z = depth[valid].astype(np.float64)
    if len(z) == 0:
        return np.empty((0, 3)), None

    K_depth = scale_intrinsics_to_depth(frame.intrinsics)
    x_cam = (u - K_depth[0, 2]) * z / K_depth[0, 0]
    y_cam = (v - K_depth[1, 2]) * z / K_depth[1, 1]
    points_cam = np.stack([x_cam, y_cam, z, np.ones_like(z)], axis=1)

    points_world = points_cam @ frame.camera_transform.T
    points_world = points_world[:, :3]

    colors = _sample_rgb_colors(frame.rgb_path, u, v) if frame.rgb_path.exists() else None
    return points_world, colors


def voxel_downsample(
    points: np.ndarray, colors: np.ndarray | None, voxel_size: float
) -> tuple[np.ndarray, np.ndarray | None]:
    """복셀 그리드당 한 점만 남긴다 (스캔 중 겹치는 프레임들의 중복 포인트 제거)."""
    if voxel_size <= 0 or len(points) == 0:
        return points, colors
    voxel_indices = np.floor(points / voxel_size).astype(np.int64)
    _, unique_idx = np.unique(voxel_indices, axis=0, return_index=True)
    unique_idx.sort()
    return points[unique_idx], (colors[unique_idx] if colors is not None else None)


def arkit_to_zup(points: np.ndarray) -> np.ndarray:
    """ARKit(Y-up) -> scan-to-map-studio 관례(Z-up): (x, y, z) -> (x, -z, y)."""
    return np.column_stack([points[:, 0], -points[:, 2], points[:, 1]])


def write_ply(path: Path, points: np.ndarray, colors: np.ndarray | None) -> None:
    """binary_little_endian PLY로 저장한다 (scan-to-map-studio의 studio.point_cloud_io와
    동일한 property 순서: x,y,z float32 [+ red,green,blue uchar])."""
    points = np.asarray(points, dtype="<f4")
    n = len(points)

    with path.open("wb") as f:
        header = ["ply", "format binary_little_endian 1.0", f"element vertex {n}"]
        header += ["property float x", "property float y", "property float z"]
        if colors is not None:
            header += ["property uchar red", "property uchar green", "property uchar blue"]
        header.append("end_header")
        f.write(("\n".join(header) + "\n").encode("ascii"))

        if colors is not None:
            colors = np.asarray(colors, dtype="<u1")
            record_dtype = np.dtype(
                [("x", "<f4"), ("y", "<f4"), ("z", "<f4"), ("r", "u1"), ("g", "u1"), ("b", "u1")]
            )
            data = np.empty(n, dtype=record_dtype)
            data["x"], data["y"], data["z"] = points[:, 0], points[:, 1], points[:, 2]
            data["r"], data["g"], data["b"] = colors[:, 0], colors[:, 1], colors[:, 2]
        else:
            record_dtype = np.dtype([("x", "<f4"), ("y", "<f4"), ("z", "<f4")])
            data = np.empty(n, dtype=record_dtype)
            data["x"], data["y"], data["z"] = points[:, 0], points[:, 1], points[:, 2]

        f.write(data.tobytes())


def export_pointcloud(
    scan_dir: Path, output_path: Path, voxel_size: float = config.POINTCLOUD_VOXEL_SIZE_METERS
) -> None:
    frames = load_scan(scan_dir)  # tracking_state != "normal"인 프레임은 기본 제외

    all_points: list[np.ndarray] = []
    all_colors: list[np.ndarray] = []
    for frame in frames:
        points, colors = backproject_frame_dense(frame)
        if len(points) == 0:
            continue
        all_points.append(points)
        if colors is not None:
            all_colors.append(colors)

    if not all_points:
        raise ValueError(f"{scan_dir}에서 유효한 포인트를 하나도 만들지 못했습니다")

    points = np.concatenate(all_points, axis=0)
    colors = np.concatenate(all_colors, axis=0) if len(all_colors) == len(all_points) else None

    points = arkit_to_zup(points)
    points, colors = voxel_downsample(points, colors, voxel_size)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    write_ply(output_path, points, colors)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="scan 폴더의 depth 전체를 backproject해서 world-frame 포인트클라우드(PLY)로 내보낸다"
    )
    parser.add_argument("scan_dir", type=Path)
    parser.add_argument("output_ply", type=Path)
    parser.add_argument(
        "--voxel-size",
        type=float,
        default=config.POINTCLOUD_VOXEL_SIZE_METERS,
        help="복셀 다운샘플링 크기(m). 0이면 다운샘플링 안 함",
    )
    args = parser.parse_args()
    export_pointcloud(args.scan_dir, args.output_ply, args.voxel_size)
    print(f"wrote {args.output_ply}")


if __name__ == "__main__":
    main()

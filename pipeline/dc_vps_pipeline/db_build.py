"""scan_<name>/ 폴더 -> hloc DB(keypoint별 3D 대응 테이블).

InLoc 방식: COLMAP 삼각측량 없이, LiDAR depth에서 직접 2D-3D 대응을 만든다.
1. hloc.extract_features로 SuperPoint(local) + NetVLAD(global) 추출
2. 각 DB 이미지의 2D keypoint를 depth 해상도로 스케일 다운
3. nearest-neighbor로 depth/confidence lookup, confidence 미달/범위 밖이면 버림
4. depth 기준 intrinsics로 backproject -> ARKit pose로 world 좌표 변환
5. keypoint_id -> 3D 좌표 테이블을 저장 (localize_sfm.py의 COLMAP 모델을 대체)

TODO: hloc 버전별 extract_features 반환/HDF5 스키마를 확인해서
      feats 순회 부분(`# TODO: hloc feature 포맷에 맞게 순회`)을 채워 넣을 것.
"""

from __future__ import annotations

import argparse
import pickle
from pathlib import Path

import numpy as np
from PIL import Image

from . import config
from .geometry import backproject_filtered, scale_intrinsics_to_depth
from .scan_loader import load_depth_raw, load_scan


def build_db(scan_dir: Path, output_dir: Path) -> None:
    from hloc import extract_features

    output_dir.mkdir(parents=True, exist_ok=True)
    images_dir = scan_dir / "rgb"

    feature_conf = extract_features.confs[config.SUPERPOINT_CONF]
    retrieval_conf = extract_features.confs[config.RETRIEVAL_CONF]

    extract_features.main(feature_conf, images_dir, output_dir)
    extract_features.main(retrieval_conf, images_dir, output_dir)

    frames = load_scan(scan_dir)
    frames_by_rgb_name = {f.rgb_path.name: f for f in frames}

    feats_path = output_dir / f"{feature_conf['output']}.h5"
    kp_to_3d_db: dict[str, list] = {}

    import h5py

    with h5py.File(feats_path, "r") as feats_file:
        for rgb_name, frame in frames_by_rgb_name.items():
            if rgb_name not in feats_file:
                continue

            # TODO: hloc feature 포맷에 맞게 순회 (버전에 따라 group 구조가 다를 수 있음)
            keypoints = feats_file[rgb_name]["keypoints"][()]

            depth = load_depth_raw(frame.depth_path, config.DEPTH_WIDTH, config.DEPTH_HEIGHT)
            confidence_path = frame.depth_path.with_suffix(".conf")
            confidence = (
                load_depth_raw(confidence_path, config.DEPTH_WIDTH, config.DEPTH_HEIGHT)
                if confidence_path.exists()
                else None
            )

            K_depth = scale_intrinsics_to_depth(frame.intrinsics)

            points_3d = []
            for kp in keypoints:
                p = backproject_filtered(
                    tuple(kp), depth, confidence, K_depth, frame.camera_transform
                )
                points_3d.append(p)

            kp_to_3d_db[rgb_name] = points_3d

    with (output_dir / "kp_to_3d_db.pkl").open("wb") as f:
        pickle.dump(kp_to_3d_db, f)


def main() -> None:
    parser = argparse.ArgumentParser(description="scan 폴더에서 hloc DB(2D-3D 대응 테이블) 빌드")
    parser.add_argument("scan_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    build_db(args.scan_dir, args.output_dir)


if __name__ == "__main__":
    main()

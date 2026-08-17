"""쿼리 이미지 -> 6DoF pose.

흐름 (ARC eye VL API와 동일한 역할):
1. 쿼리 이미지에서 SuperPoint 추출
2. NetVLAD로 DB에서 top-k(RETRIEVAL_TOP_K) 후보 이미지 검색
3. LightGlue로 쿼리-DB 2D-2D 매칭 -> 매칭된 DB keypoint의 3D 좌표(kp_to_3d_db) 가져오기
4. 2D(쿼리)-3D(world) 대응점으로 pycolmap.estimate_and_refine_absolute_pose
   (PnP+RANSAC) -> 6DoF pose

db_build.py가 만든 kp_to_3d_db.pkl + hloc feature/global descriptor 파일을 로드해서 사용한다.

pycolmap은 world-to-camera(cam_from_world)를 리턴하지만, ios-capture/pipeline 전반은
camera-to-world(world_from_cam) 관례(ARKit camera_transform, db_build.py의 backproject)를
쓰므로 리턴 직전에 inverse()로 뒤집는다.
"""

from __future__ import annotations

import pickle
import tempfile
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pycolmap

from dc_vps_pipeline import config as pipeline_config


@dataclass
class LocalizationResult:
    success: bool
    translation: list[float] | None = None  # [x, y, z], world 좌표계
    quaternion: list[float] | None = None  # [qx, qy, qz, qw]
    num_inliers: int = 0
    reason: str | None = None


class Localizer:
    QUERY_NAME = "query.jpg"

    def __init__(self, db_dir: Path):
        from hloc import extract_features
        from hloc.utils.io import list_h5_names

        self.db_dir = Path(db_dir)
        self.feature_conf = extract_features.confs[pipeline_config.SUPERPOINT_CONF]
        self.retrieval_conf = extract_features.confs[pipeline_config.RETRIEVAL_CONF]

        self.db_feats_path = self.db_dir / f"{self.feature_conf['output']}.h5"
        self.db_retrieval_path = self.db_dir / f"{self.retrieval_conf['output']}.h5"
        kp_db_path = self.db_dir / "kp_to_3d_db.pkl"

        for path in (self.db_feats_path, self.db_retrieval_path, kp_db_path):
            if not path.exists():
                raise FileNotFoundError(
                    f"DB 파일 없음: {path} (먼저 pipeline의 db_build.py로 DB를 빌드할 것)"
                )

        with kp_db_path.open("rb") as f:
            self.kp_to_3d_db: dict[str, list] = pickle.load(f)

        # torch.topk(k=RETRIEVAL_TOP_K)가 DB 이미지 수보다 큰 k를 받으면 터진다
        # (pairs_from_retrieval.pairs_from_score_matrix). 작은 DB(테스트, 소규모 스캔)에서
        # 흔히 발생하므로 미리 클램프한다.
        self.num_retrieval_matched = min(
            pipeline_config.RETRIEVAL_TOP_K, len(list_h5_names(self.db_retrieval_path))
        )

    def localize(self, image_bytes: bytes, camera: pycolmap.Camera) -> LocalizationResult:
        from hloc import extract_features, match_features, pairs_from_retrieval
        from hloc.utils.io import get_keypoints, get_matches
        from hloc.utils.parsers import parse_retrieval

        with tempfile.TemporaryDirectory(prefix="dc_vps_query_") as tmp:
            tmp_dir = Path(tmp)
            images_dir = tmp_dir / "images"
            images_dir.mkdir()
            (images_dir / self.QUERY_NAME).write_bytes(image_bytes)

            query_feats_path = extract_features.main(
                self.feature_conf, images_dir, tmp_dir, image_list=[self.QUERY_NAME]
            )
            query_retrieval_path = extract_features.main(
                self.retrieval_conf, images_dir, tmp_dir, image_list=[self.QUERY_NAME]
            )

            pairs_path = tmp_dir / "pairs.txt"
            pairs_from_retrieval.main(
                query_retrieval_path,
                pairs_path,
                num_matched=self.num_retrieval_matched,
                query_list=[self.QUERY_NAME],
                db_descriptors=self.db_retrieval_path,
            )

            retrieved = parse_retrieval(pairs_path)
            db_names = retrieved.get(self.QUERY_NAME, [])
            if not db_names:
                return LocalizationResult(success=False, reason="검색된 DB 후보 이미지가 없음")

            match_conf = match_features.confs[pipeline_config.MATCHER_CONF]
            matches_path = tmp_dir / "matches.h5"
            match_features.main(
                match_conf,
                pairs_path,
                features=query_feats_path,
                matches=matches_path,
                features_ref=self.db_feats_path,
            )

            kpq = get_keypoints(query_feats_path, self.QUERY_NAME)

            points2d: list[np.ndarray] = []
            points3d: list[np.ndarray] = []
            for db_name in db_names:
                db_points = self.kp_to_3d_db.get(db_name)
                if db_points is None:
                    continue
                matches, _scores = get_matches(matches_path, self.QUERY_NAME, db_name)
                for idx_q, idx_db in matches:
                    point3d = db_points[idx_db]
                    if point3d is None:
                        continue
                    points2d.append(kpq[idx_q])
                    points3d.append(point3d)

            if len(points2d) < 3:
                return LocalizationResult(
                    success=False,
                    reason=f"2D-3D 대응점 부족 ({len(points2d)}개, 최소 3개 필요)",
                )

            ret = pycolmap.estimate_and_refine_absolute_pose(
                np.array(points2d, dtype=np.float64),
                np.array(points3d, dtype=np.float64),
                camera,
            )

        if ret is None or ret["num_inliers"] < pipeline_config.MIN_INLIERS:
            num_inliers = ret["num_inliers"] if ret else 0
            return LocalizationResult(
                success=False,
                reason=f"PnP 실패 또는 inlier 부족 (num_inliers={num_inliers})",
                num_inliers=num_inliers,
            )

        world_from_cam = ret["cam_from_world"].inverse()
        return LocalizationResult(
            success=True,
            translation=world_from_cam.translation.tolist(),
            quaternion=world_from_cam.rotation.quat.tolist(),
            num_inliers=ret["num_inliers"],
        )

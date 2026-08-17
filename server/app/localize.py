"""쿼리 이미지 -> 6DoF pose.

흐름 (ARC eye VL API와 동일한 역할):
1. 쿼리 이미지에서 SuperPoint 추출
2. NetVLAD로 DB에서 top-k(RETRIEVAL_TOP_K) 후보 이미지 검색
3. LightGlue로 쿼리-DB 2D-2D 매칭 -> 매칭된 DB keypoint의 3D 좌표(kp_to_3d_db) 가져오기
4. 2D(쿼리)-3D(world) 대응점으로 pycolmap.estimate_and_refine_absolute_pose (PnP+RANSAC) -> 6DoF pose

db_build.py가 만든 kp_to_3d_db.pkl + hloc feature/global descriptor 파일을 로드해서 사용한다.

feature 추출은 hloc.extract_features.main()을 쿼리 1장짜리 임시 디렉터리에 대해 그대로
호출한다. db_build.py와 완전히 동일한 전처리/후처리(리사이즈, keypoint 좌표 원본 해상도로
역스케일)를 재사용해서 DB와 쿼리 간 좌표계 불일치를 피하기 위함이다. 매 요청마다 모델
가중치를 다시 로드하는 비용이 있지만(수 초), 이 서버는 아직 실시간 로봇 루프가 아니라
프로토타입 단계라 우선순위가 아니다 — 필요해지면 모델을 프로세스 시작 시 한 번만 로드하도록
바꿀 수 있다.
"""

from __future__ import annotations

import pickle
import tempfile
from dataclasses import dataclass
from pathlib import Path

import h5py
import numpy as np
import pycolmap

from hloc import extract_features, match_features
from hloc.utils.parsers import names_to_pair

# pipeline/dc_vps_pipeline/config.py의 SUPERPOINT_CONF/RETRIEVAL_CONF/RETRIEVAL_TOP_K와
# 반드시 동일해야 한다 — DB가 그 설정으로 빌드됐기 때문에 쿼리도 같은 설정으로 추출해야
# keypoint 좌표계/디스크립터가 호환된다. pipeline과 server가 별도 venv라 패키지 임포트로
# 공유하지 않고 값만 맞춰서 복제했다.
SUPERPOINT_CONF = extract_features.confs["superpoint_inloc"]
RETRIEVAL_CONF = extract_features.confs["netvlad"]
RETRIEVAL_TOP_K = 20

MATCHER_CONF = match_features.confs["superpoint+lightglue"]

# PnP+RANSAC inlier가 이보다 적으면 위치 추정 실패로 간주한다.
MIN_INLIERS = 12


@dataclass
class LocalizationResult:
    success: bool
    translation: list[float] | None = None  # [x, y, z], world 좌표계
    quaternion: list[float] | None = None  # [qx, qy, qz, qw]
    num_inliers: int = 0
    reason: str | None = None


class Localizer:
    def __init__(self, db_dir: Path):
        self.db_dir = db_dir
        self.features_path = db_dir / f"{SUPERPOINT_CONF['output']}.h5"
        self.global_features_path = db_dir / f"{RETRIEVAL_CONF['output']}.h5"
        kp_to_3d_path = db_dir / "kp_to_3d_db.pkl"

        for path in (self.features_path, self.global_features_path, kp_to_3d_path):
            if not path.exists():
                raise FileNotFoundError(
                    f"DB 파일을 찾을 수 없습니다: {path}. "
                    "pipeline/dc_vps_pipeline/db_build.py로 먼저 DB를 빌드했는지 확인하세요."
                )

        with kp_to_3d_path.open("rb") as f:
            self.kp_to_3d_db: dict[str, list] = pickle.load(f)

        with h5py.File(self.global_features_path, "r", libver="latest") as fd:
            self.db_names = list(fd.keys())
            descs = np.stack(
                [fd[name]["global_descriptor"].__array__() for name in self.db_names], 0
            ).astype(np.float64)
        self.db_global_descs = descs / np.linalg.norm(descs, axis=1, keepdims=True)

    def localize(
        self,
        image_bytes: bytes,
        fx: float,
        fy: float,
        cx: float,
        cy: float,
        width: int,
        height: int,
    ) -> LocalizationResult:
        query_name = "query.jpg"

        with tempfile.TemporaryDirectory(prefix="dc_vps_query_") as tmp:
            tmp_dir = Path(tmp)
            image_dir = tmp_dir / "images"
            image_dir.mkdir()
            (image_dir / query_name).write_bytes(image_bytes)

            export_dir = tmp_dir / "export"
            try:
                extract_features.main(
                    SUPERPOINT_CONF, image_dir, export_dir, image_list=[query_name]
                )
                extract_features.main(
                    RETRIEVAL_CONF, image_dir, export_dir, image_list=[query_name]
                )
            except ValueError as error:
                return LocalizationResult(success=False, reason=f"이미지 처리 실패: {error}")

            query_features_path = export_dir / f"{SUPERPOINT_CONF['output']}.h5"
            query_global_path = export_dir / f"{RETRIEVAL_CONF['output']}.h5"

            candidates = self._retrieve_candidates(query_global_path, query_name)
            if not candidates:
                return LocalizationResult(success=False, reason="검색 후보를 찾지 못함")

            pairs_path = tmp_dir / "pairs.txt"
            pairs_path.write_text(
                "\n".join(f"{query_name} {candidate}" for candidate in candidates) + "\n"
            )

            match_path = tmp_dir / "matches.h5"
            match_features.match_from_paths(
                MATCHER_CONF,
                pairs_path,
                match_path,
                query_features_path,
                self.features_path,
            )

            points2d, points3d = self._gather_correspondences(
                query_name, candidates, query_features_path, match_path
            )

        if len(points2d) < 4:
            return LocalizationResult(
                success=False, reason=f"2D-3D 대응점 부족 ({len(points2d)}개, 최소 4개 필요)"
            )

        camera = {
            "model": "PINHOLE",
            "width": width,
            "height": height,
            "params": [fx, fy, cx, cy],
        }
        ret = pycolmap.estimate_and_refine_absolute_pose(
            points2d, points3d, camera, pycolmap.AbsolutePoseEstimationOptions()
        )

        if ret is None or ret["num_inliers"] < MIN_INLIERS:
            return LocalizationResult(
                success=False,
                num_inliers=ret["num_inliers"] if ret else 0,
                reason="PnP+RANSAC 실패 또는 inlier 부족",
            )

        # cam_from_world(world->camera)를 world_from_cam(camera->world)으로 뒤집는다 —
        # poses.jsonl의 camera_transform과 동일하게 "카메라의 world 좌표계 pose"로 리턴하기 위함.
        world_from_cam = ret["cam_from_world"].inverse()
        qx, qy, qz, qw = world_from_cam.rotation.quat

        return LocalizationResult(
            success=True,
            translation=world_from_cam.translation.tolist(),
            quaternion=[float(qx), float(qy), float(qz), float(qw)],
            num_inliers=ret["num_inliers"],
        )

    def _retrieve_candidates(self, query_global_path: Path, query_name: str) -> list[str]:
        with h5py.File(query_global_path, "r", libver="latest") as fd:
            query_desc = fd[query_name]["global_descriptor"].__array__().astype(np.float64)
        query_desc = query_desc / np.linalg.norm(query_desc)

        scores = self.db_global_descs @ query_desc
        top_k = min(RETRIEVAL_TOP_K, len(self.db_names))
        top_indices = np.argsort(-scores)[:top_k]
        return [self.db_names[i] for i in top_indices]

    def _gather_correspondences(
        self,
        query_name: str,
        candidates: list[str],
        query_features_path: Path,
        match_path: Path,
    ) -> tuple[np.ndarray, np.ndarray]:
        points2d: list[np.ndarray] = []
        points3d: list[np.ndarray] = []

        with h5py.File(query_features_path, "r", libver="latest") as qf, \
             h5py.File(match_path, "r", libver="latest") as mf:
            kpq = qf[query_name]["keypoints"].__array__()

            for candidate in candidates:
                pair = names_to_pair(query_name, candidate)
                if pair not in mf:
                    continue
                matches = mf[pair]["matches0"].__array__()
                valid = matches > -1
                if not np.any(valid):
                    continue

                candidate_points_3d = self.kp_to_3d_db.get(candidate)
                if candidate_points_3d is None:
                    continue

                for query_idx in np.nonzero(valid)[0]:
                    ref_idx = int(matches[query_idx])
                    p3d = candidate_points_3d[ref_idx]
                    if p3d is None:
                        continue
                    points2d.append(kpq[query_idx].astype(np.float64))
                    points3d.append(np.asarray(p3d, dtype=np.float64))

        if not points2d:
            return np.empty((0, 2)), np.empty((0, 3))
        return np.stack(points2d, 0), np.stack(points3d, 0)

"""쿼리 이미지 -> 6DoF pose.

흐름 (ARC eye VL API와 동일한 역할):
1. 쿼리 이미지에서 SuperPoint 추출
2. NetVLAD로 DB에서 top-k(RETRIEVAL_TOP_K) 후보 이미지 검색
3. LightGlue로 쿼리-DB 2D-2D 매칭 -> 매칭된 DB keypoint의 3D 좌표(kp_to_3d_db) 가져오기
4. 2D(쿼리)-3D(world) 대응점으로 pycolmap.absolute_pose_estimation (PnP+RANSAC) -> 6DoF pose

db_build.py가 만든 kp_to_3d_db.pkl + hloc feature/global descriptor 파일을 로드해서 사용한다.
NOTE: 이 파일은 설계만 잡힌 상태 — 실제 구현(모델 로딩, 매칭 로직)은 다음 단계에서 채운다.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


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
        # TODO: kp_to_3d_db.pkl, SuperPoint/NetVLAD 모델, global descriptor 로드

    def localize(self, image_bytes: bytes) -> LocalizationResult:
        # TODO:
        # 1. image_bytes -> SuperPoint keypoints/descriptors
        # 2. NetVLAD global descriptor -> DB에서 top-k 후보 검색 (config.RETRIEVAL_TOP_K)
        # 3. LightGlue 매칭 -> 대응하는 3D 좌표 확보
        # 4. pycolmap.absolute_pose_estimation(PnP+RANSAC) -> pose
        raise NotImplementedError

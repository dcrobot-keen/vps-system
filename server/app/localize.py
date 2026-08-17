"""쿼리 이미지 -> 6DoF pose.

흐름 (ARC eye VL API와 동일한 역할):
1. 쿼리 이미지에서 SuperPoint 추출
2. NetVLAD로 DB에서 top-k(RETRIEVAL_TOP_K) 후보 이미지 검색
3. LightGlue로 쿼리-DB 2D-2D 매칭 -> 매칭된 DB keypoint의 3D 좌표(kp_to_3d_db) 가져오기
4. 2D(쿼리)-3D(world) 대응점으로 pycolmap.estimate_and_refine_absolute_pose (PnP+RANSAC) -> 6DoF pose

db_build.py가 만든 kp_to_3d_db.pkl + hloc feature/global descriptor 파일을 로드해서 사용한다.

SuperPoint/NetVLAD/LightGlue 모델은 Localizer.__init__에서 한 번만 로드해 인스턴스에
캐싱해둔다 (이전엔 hloc.extract_features.main()/match_features.match_from_paths()를
쿼리마다 호출해서 매 요청 모델을 새로 읽어들였고, 그게 요청당 수십 초의 대부분을
차지했다). 전처리(리사이즈, grayscale)와 후처리(keypoint를 원본 해상도로 역스케일)는
hloc.extract_features.ImageDataset/main()의 로직을 그대로 옮겨왔다 — DB 빌드 때와
동일한 좌표 변환이어야 좌표계가 어긋나지 않는다.
"""

from __future__ import annotations

import pickle
from dataclasses import dataclass
from pathlib import Path

import cv2
import h5py
import numpy as np
import pycolmap
import torch

from dc_vps_pipeline import config as pipeline_config
from hloc import extract_features, extractors, match_features, matchers
from hloc.extract_features import resize_image
from hloc.utils.base_model import dynamic_load

# DB가 pipeline/dc_vps_pipeline/config.py의 설정으로 빌드되기 때문에, 쿼리 쪽도 같은
# 설정으로 추출해야 keypoint 좌표계/디스크립터가 호환된다. server venv에
# `pip install -e ../pipeline`로 설치해서(server/README.md 참고) 값을 직접 import한다 —
# 더 이상 복제하지 않으므로 pipeline 쪽 설정을 바꾸면 여기도 자동으로 따라간다.
SUPERPOINT_CONF = extract_features.confs[pipeline_config.SUPERPOINT_CONF]
RETRIEVAL_CONF = extract_features.confs[pipeline_config.RETRIEVAL_CONF]
RETRIEVAL_TOP_K = pipeline_config.RETRIEVAL_TOP_K

MATCHER_CONF = match_features.confs[pipeline_config.MATCHER_CONF]

# PnP+RANSAC inlier가 이보다 적으면 위치 추정 실패로 간주한다.
MIN_INLIERS = 12


@dataclass
class LocalizationResult:
    success: bool
    translation: list[float] | None = None  # [x, y, z], world 좌표계
    quaternion: list[float] | None = None  # [qx, qy, qz, qw]
    num_inliers: int = 0
    reason: str | None = None


def _read_image_bytes(image_bytes: bytes, grayscale: bool) -> np.ndarray:
    """hloc.utils.io.read_image과 동일하되 파일 경로 대신 메모리 바이트를 읽는다."""
    array = np.frombuffer(image_bytes, dtype=np.uint8)
    mode = cv2.IMREAD_GRAYSCALE if grayscale else cv2.IMREAD_COLOR
    image = cv2.imdecode(array, mode | cv2.IMREAD_IGNORE_ORIENTATION)
    if image is None:
        raise ValueError("이미지를 디코딩할 수 없습니다")
    if not grayscale and image.ndim == 3:
        image = image[:, :, ::-1]  # BGR -> RGB
    return image


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

        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.superpoint_model = (
            dynamic_load(extractors, SUPERPOINT_CONF["model"]["name"])(SUPERPOINT_CONF["model"])
            .eval()
            .to(self.device)
        )
        self.netvlad_model = (
            dynamic_load(extractors, RETRIEVAL_CONF["model"]["name"])(RETRIEVAL_CONF["model"])
            .eval()
            .to(self.device)
        )
        self.lightglue_model = (
            dynamic_load(matchers, MATCHER_CONF["model"]["name"])(MATCHER_CONF["model"])
            .eval()
            .to(self.device)
        )

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
        try:
            query_pred = self._extract_superpoint(image_bytes)
            query_global_desc = self._extract_netvlad(image_bytes)
        except ValueError as error:
            return LocalizationResult(success=False, reason=f"이미지 처리 실패: {error}")

        candidates = self._retrieve_candidates(query_global_desc)
        if not candidates:
            return LocalizationResult(success=False, reason="검색 후보를 찾지 못함")

        points2d, points3d = self._gather_correspondences(query_pred, candidates)
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

    # MARK: - feature extraction (hloc.extract_features의 전처리/후처리를 인메모리로 재현)

    def _preprocess(self, image_bytes: bytes, conf: dict) -> tuple[torch.Tensor, np.ndarray]:
        grayscale = conf.get("grayscale", False)
        image = _read_image_bytes(image_bytes, grayscale)
        image = image.astype(np.float32)
        original_size = np.array(image.shape[:2][::-1])  # (width, height)

        resize_max = conf.get("resize_max")
        resize_force = conf.get("resize_force", False)
        if resize_max and (resize_force or max(original_size) > resize_max):
            scale = resize_max / max(original_size)
            size_new = tuple(int(round(x * scale)) for x in original_size)
            image = resize_image(image, size_new, conf.get("interpolation", "cv2_area"))

        if grayscale:
            image = image[None]
        else:
            image = image.transpose((2, 0, 1))  # HxWxC -> CxHxW
        image = image / 255.0

        tensor = torch.from_numpy(image).float()[None]  # add batch dim
        return tensor, original_size

    def _extract_superpoint(self, image_bytes: bytes) -> dict:
        tensor, original_size = self._preprocess(image_bytes, SUPERPOINT_CONF["preprocessing"])
        with torch.no_grad():
            pred = self.superpoint_model({"image": tensor.to(self.device)})
        pred = {k: v[0].cpu().numpy() for k, v in pred.items()}

        network_h, network_w = tensor.shape[-2:]
        scales = (original_size / np.array([network_w, network_h])).astype(np.float32)
        pred["keypoints"] = (pred["keypoints"] + 0.5) * scales[None] - 0.5
        pred["image_size"] = original_size
        return pred

    def _extract_netvlad(self, image_bytes: bytes) -> np.ndarray:
        tensor, _ = self._preprocess(image_bytes, RETRIEVAL_CONF["preprocessing"])
        with torch.no_grad():
            pred = self.netvlad_model({"image": tensor.to(self.device)})
        return pred["global_descriptor"][0].cpu().numpy()

    def _retrieve_candidates(self, query_desc: np.ndarray) -> list[str]:
        query_desc = query_desc.astype(np.float64)
        query_desc = query_desc / np.linalg.norm(query_desc)

        scores = self.db_global_descs @ query_desc
        top_k = min(RETRIEVAL_TOP_K, len(self.db_names))
        top_indices = np.argsort(-scores)[:top_k]
        return [self.db_names[i] for i in top_indices]

    # MARK: - matching (hloc.match_features의 FeaturePairsDataset을 인메모리로 재현)

    def _match_candidate(self, query_pred: dict, candidate_name: str) -> np.ndarray:
        with h5py.File(self.features_path, "r", libver="latest") as fd:
            grp = fd[candidate_name]
            ref_keypoints = grp["keypoints"].__array__().astype(np.float32)
            ref_descriptors = grp["descriptors"].__array__().astype(np.float32)
            ref_scores = grp["scores"].__array__().astype(np.float32)
            ref_image_size = grp["image_size"].__array__()

        qw, qh = query_pred["image_size"]
        rw, rh = ref_image_size

        data = {
            "keypoints0": torch.from_numpy(query_pred["keypoints"].astype(np.float32))[None],
            "descriptors0": torch.from_numpy(query_pred["descriptors"].astype(np.float32))[None],
            "scores0": torch.from_numpy(query_pred["scores"].astype(np.float32))[None],
            "image0": torch.empty((1, 1, int(qh), int(qw))),
            "keypoints1": torch.from_numpy(ref_keypoints)[None],
            "descriptors1": torch.from_numpy(ref_descriptors)[None],
            "scores1": torch.from_numpy(ref_scores)[None],
            "image1": torch.empty((1, 1, int(rh), int(rw))),
        }
        data = {k: v.to(self.device) for k, v in data.items()}

        with torch.no_grad():
            pred = self.lightglue_model(data)
        return pred["matches0"][0].cpu().numpy()

    def _gather_correspondences(
        self, query_pred: dict, candidates: list[str]
    ) -> tuple[np.ndarray, np.ndarray]:
        points2d: list[np.ndarray] = []
        points3d: list[np.ndarray] = []
        kpq = query_pred["keypoints"]

        for candidate in candidates:
            candidate_points_3d = self.kp_to_3d_db.get(candidate)
            if candidate_points_3d is None:
                continue

            matches = self._match_candidate(query_pred, candidate)
            valid = matches > -1
            if not np.any(valid):
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

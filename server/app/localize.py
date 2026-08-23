"""쿼리 이미지 -> 6DoF pose.

흐름 (ARC eye VL API와 동일한 역할):
1. 쿼리 이미지에서 SuperPoint 추출
2. NetVLAD로 모든 방(room)의 DB를 가로질러 top-k(RETRIEVAL_TOP_K) 후보 이미지 검색
3. 후보를 방(room)별로 묶어서, 각 방마다 LightGlue로 2D-2D 매칭 -> 매칭된 DB keypoint의
   3D 좌표(kp_to_3d_db) 가져오기
4. 방마다 2D(쿼리)-3D(world) 대응점으로 pycolmap.estimate_and_refine_absolute_pose
   (PnP+RANSAC) 시도 -> inlier가 제일 많은 방을 채택하되, 2등 방과의 격차가
   MIN_INLIER_MARGIN_RATIO 미만이면(room 판별이 모호하면) 실패로 처리

db_build.py가 만든 kp_to_3d_db.pkl + hloc feature/global descriptor 파일을 로드해서 사용한다.

여러 방을 지원하는 이유: 방마다 스캔 세션의 world 좌표계(ARKit 원점)가 서로 다르기
때문에, 서로 다른 방의 3D 포인트를 하나의 PnP에 섞어 넣을 수 없다 — 그래서 retrieval은
방 경계 없이 전체를 검색하되, 매칭/PnP는 방 단위로 분리해서 돌리고 제일 잘 맞는 방을
고른다. 리턴값의 room_id로 어느 방인지 알 수 있다 (ros2_ws/src/dc_vps_bridge가 방마다
다른 scan_basemap_<room_id> tf를 찾아 쓸 수 있도록).

SuperPoint/NetVLAD/LightGlue 모델은 Localizer.__init__에서 한 번만 로드해 인스턴스에
캐싱해둔다 (이전엔 hloc.extract_features.main()/match_features.match_from_paths()를
쿼리마다 호출해서 매 요청 모델을 새로 읽어들였고, 그게 요청당 수십 초의 대부분을
차지했다). 전처리(리사이즈, grayscale)와 후처리(keypoint를 원본 해상도로 역스케일)는
hloc.extract_features.ImageDataset/main()의 로직을 그대로 옮겨왔다 — DB 빌드 때와
동일한 좌표 변환이어야 좌표계가 어긋나지 않는다.
"""

from __future__ import annotations

import os
import pickle
import threading
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

# 1등 room의 inlier가 2등 room의 inlier보다 이 배수 미만이면 "room 판별 자체가
# 모호함"으로 보고 실패 처리한다 (둘 다 MIN_INLIERS를 넘겨도 마찬가지). retrieval이
# 실제로 room을 가로질러 top-k를 검색하기 때문에, 어떤 쿼리는 전혀 다른 두 room에서
# 둘 다 임계값 근처의 inlier가 나올 수 있다 -- 이 경우 1등을 그냥 채택하면 로봇이
# 완전히 다른 room의 좌표계로 튈 위험이 있으므로, 애매하면 틀린 room을 확신하고
# 리턴하는 대신 실패로 유보한다. PnP는 room마다 이미 CPU에서 전부 돌기 때문에 이
# 검사는 추가 모델 추론(GPU) 없이 이미 계산된 결과를 비교만 한다.
MIN_INLIER_MARGIN_RATIO = 1.5

# pycolmap의 기본 RANSAC 옵션(confidence=0.99999, num_threads=1)은 룸 하나당
# PnP+RANSAC이 1.5초 가까이 걸리게 만든다 -- 프로파일링해보니(2026-08-23) 이게
# GPU 추론(SuperPoint+NetVLAD+LightGlue, room 6개/후보 20개 기준 ~0.6초)보다도
# 훨씬 큰 병목이었다. num_threads를 늘리는 쪽이 지배적 요인(1 -> 8 스레드로 6~7배)이고,
# confidence를 0.999로 낮추는 것도 보탬이 된다(신뢰도 99.9%면 로봇 위치 추정 용도로는
# 충분 -- 논문 벤치마크 수준의 5-nines가 필요한 게 아니다). 코어 16개 기준 8스레드로
# 맞춰서 동시 요청 여지를 절반 남겨둔다.
PNP_RANSAC_CONFIDENCE = 0.999
# 동시 요청이 많은 배포에서는 요청당 스레드를 줄여야 전체 처리량이 오히려 좋아질 수
# 있다(코어 수는 고정인데 요청마다 이 스레드를 다 쓰면 동시 요청끼리 서로 밟는다) --
# DC_VPS_PNP_THREADS로 배포 환경에 맞게 조정한다.
PNP_RANSAC_NUM_THREADS = int(os.environ.get("DC_VPS_PNP_THREADS", min(8, os.cpu_count() or 1)))


@dataclass
class LocalizationResult:
    success: bool
    room_id: str | None = None  # 매칭된 DB(scan_<name>) 디렉터리 이름
    translation: list[float] | None = None  # [x, y, z], 해당 room의 world 좌표계
    quaternion: list[float] | None = None  # [qx, qy, qz, qw]
    num_inliers: int = 0
    runner_up_room_id: str | None = None  # 2등 room (모호성 판단/관측용, 없으면 None)
    runner_up_inliers: int = 0
    reason: str | None = None


def _select_best_room(
    room_inliers: list[tuple[str, int]],
    min_inliers: int = MIN_INLIERS,
    margin_ratio: float = MIN_INLIER_MARGIN_RATIO,
) -> tuple[str | None, int, str | None, int, str | None]:
    """PnP를 시도한 각 room의 (room_id, num_inliers) 목록에서 채택할 room을 고른다.

    반환: (best_room_id, best_inliers, runner_up_room_id, runner_up_inliers, failure_reason).
    failure_reason이 None이 아니면 실패 -- best_room_id는 참고용(디버깅)일 뿐 채택되지 않는다.
    """
    if not room_inliers:
        return None, 0, None, 0, "모든 후보 room에서 PnP+RANSAC 실패"

    ranked = sorted(room_inliers, key=lambda item: item[1], reverse=True)
    best_room_id, best_inliers = ranked[0]
    runner_up_room_id, runner_up_inliers = ranked[1] if len(ranked) > 1 else (None, 0)

    if best_inliers < min_inliers:
        return (
            best_room_id, best_inliers, runner_up_room_id, runner_up_inliers,
            f"PnP 실패 또는 inlier 부족 (num_inliers={best_inliers})",
        )

    if runner_up_inliers > 0 and best_inliers < margin_ratio * runner_up_inliers:
        return (
            best_room_id, best_inliers, runner_up_room_id, runner_up_inliers,
            f"room 매칭이 모호함: '{best_room_id}'({best_inliers} inliers) vs "
            f"'{runner_up_room_id}'({runner_up_inliers} inliers) — {margin_ratio}배 격차 미달",
        )

    return best_room_id, best_inliers, runner_up_room_id, runner_up_inliers, None


@dataclass
class _RoomDB:
    room_id: str
    features_path: Path
    kp_to_3d_db: dict[str, list]
    db_names: list[str]
    db_global_descs: np.ndarray  # (N, D), L2-정규화됨


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
    def __init__(self, db_dirs: list[Path]):
        # room을 서버 재시작 없이 add_room()/remove_room()으로 추가/제거할 수 있다 —
        # 이 lock은 그 변경(rooms dict 교체 + retrieval index 재계산)과 localize() 중의
        # 읽기가 겹치지 않게 보호한다. add_room/remove_room은 I/O(h5/pickle 로드)와 작은
        # 행렬 연산뿐이라 GPU를 쓰지 않는다 -- 무거운 건 DB를 새로 "빌드"하는 쪽
        # (pipeline/db_build.py, SuperPoint/NetVLAD 추출)이고 그건 이 클래스의 책임이
        # 아니다: 여기는 이미 빌드된 DB 디렉터리를 등록/해제하는 것만 담당한다.
        self._lock = threading.Lock()
        self.rooms: dict[str, _RoomDB] = {}
        for db_dir in db_dirs:
            room = self._load_room(db_dir)
            if room.room_id in self.rooms:
                raise ValueError(
                    f"room_id가 중복됩니다: '{room.room_id}' — DB 디렉터리 이름이 겹치지 않게 하세요"
                )
            self.rooms[room.room_id] = room
        self._rebuild_retrieval_index()

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

    @staticmethod
    def _load_room(db_dir: Path) -> _RoomDB:
        room_id = db_dir.name
        features_path = db_dir / f"{SUPERPOINT_CONF['output']}.h5"
        global_features_path = db_dir / f"{RETRIEVAL_CONF['output']}.h5"
        kp_to_3d_path = db_dir / "kp_to_3d_db.pkl"

        for path in (features_path, global_features_path, kp_to_3d_path):
            if not path.exists():
                raise FileNotFoundError(
                    f"DB 파일을 찾을 수 없습니다: {path}. "
                    "pipeline/dc_vps_pipeline/db_build.py로 먼저 DB를 빌드했는지 확인하세요."
                )

        with kp_to_3d_path.open("rb") as f:
            kp_to_3d_db: dict[str, list] = pickle.load(f)

        with h5py.File(global_features_path, "r", libver="latest") as fd:
            db_names = list(fd.keys())
            descs = np.stack(
                [fd[name]["global_descriptor"].__array__() for name in db_names], 0
            ).astype(np.float64)
        db_global_descs = descs / np.linalg.norm(descs, axis=1, keepdims=True)

        return _RoomDB(
            room_id=room_id,
            features_path=features_path,
            kp_to_3d_db=kp_to_3d_db,
            db_names=db_names,
            db_global_descs=db_global_descs,
        )

    def _rebuild_retrieval_index(self) -> None:
        """self.rooms가 바뀔 때마다(add_room/remove_room/__init__) NetVLAD retrieval용
        전역 배열을 다시 만든다. room이 하나도 없어도(zero-room 상태) 동작해야 한다 —
        방금 막 뜬 서버에 아직 room을 하나도 등록 안 한 경우가 정상 상태이기 때문."""
        self.retrieval_index: list[tuple[str, str]] = []  # (room_id, image_name)
        all_descs = [room.db_global_descs for room in self.rooms.values()]
        self.all_global_descs = (
            np.concatenate(all_descs, axis=0) if all_descs else np.zeros((0, 0))
        )
        for room in self.rooms.values():
            self.retrieval_index.extend((room.room_id, name) for name in room.db_names)

    def add_room(self, db_dir: Path, replace: bool = False) -> str:
        """이미 빌드된 DB 디렉터리(pipeline/db_build.py 산출물)를 서버 재시작 없이
        등록한다. room_id는 디렉터리 이름 -- 이미 로드돼 있으면 replace=True일 때만
        덮어쓴다(재스캔 후 DB를 갱신하는 용도). 반환값은 등록된 room_id."""
        room = self._load_room(db_dir)
        with self._lock:
            if room.room_id in self.rooms and not replace:
                raise ValueError(
                    f"room_id '{room.room_id}'가 이미 로드돼 있습니다 "
                    "(갱신하려면 replace=True)"
                )
            self.rooms[room.room_id] = room
            self._rebuild_retrieval_index()
        return room.room_id

    def remove_room(self, room_id: str) -> None:
        with self._lock:
            if room_id not in self.rooms:
                raise KeyError(f"room_id '{room_id}'가 로드돼 있지 않습니다")
            del self.rooms[room_id]
            self._rebuild_retrieval_index()

    def list_rooms(self) -> list[dict]:
        with self._lock:
            return [
                {"room_id": room.room_id, "num_images": len(room.db_names)}
                for room in self.rooms.values()
            ]

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

        correspondences_by_room = self._gather_correspondences_by_room(query_pred, candidates)
        if not correspondences_by_room:
            return LocalizationResult(success=False, reason="2D-3D 대응점 부족")

        camera = {
            "model": "PINHOLE",
            "width": width,
            "height": height,
            "params": [fx, fy, cx, cy],
        }

        pnp_options = pycolmap.AbsolutePoseEstimationOptions()
        pnp_options.ransac.confidence = PNP_RANSAC_CONFIDENCE
        pnp_options.ransac.num_threads = PNP_RANSAC_NUM_THREADS

        room_rets: dict[str, dict] = {}
        for room_id, (points2d, points3d) in correspondences_by_room.items():
            if len(points2d) < 4:
                continue
            ret = pycolmap.estimate_and_refine_absolute_pose(
                points2d, points3d, camera, pnp_options
            )
            if ret is not None:
                room_rets[room_id] = ret

        room_inliers = [(room_id, ret["num_inliers"]) for room_id, ret in room_rets.items()]
        best_room_id, best_inliers, runner_up_room_id, runner_up_inliers, failure_reason = (
            _select_best_room(room_inliers)
        )

        if failure_reason is not None:
            return LocalizationResult(
                success=False,
                num_inliers=best_inliers,
                runner_up_room_id=runner_up_room_id,
                runner_up_inliers=runner_up_inliers,
                reason=failure_reason,
            )

        best_ret = room_rets[best_room_id]
        # cam_from_world(world->camera)를 world_from_cam(camera->world)으로 뒤집는다 —
        # poses.jsonl의 camera_transform과 동일하게 "카메라의 world 좌표계 pose"로 리턴.
        world_from_cam = best_ret["cam_from_world"].inverse()
        qx, qy, qz, qw = world_from_cam.rotation.quat
        return LocalizationResult(
            success=True,
            room_id=best_room_id,
            translation=world_from_cam.translation.tolist(),
            quaternion=[float(qx), float(qy), float(qz), float(qw)],
            num_inliers=best_inliers,
            runner_up_room_id=runner_up_room_id,
            runner_up_inliers=runner_up_inliers,
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

    def _retrieve_candidates(self, query_desc: np.ndarray) -> list[tuple[str, str]]:
        """전체 room을 가로질러 top-k를 검색한다. 반환값은 (room_id, image_name) 목록."""
        if not self.retrieval_index:  # room이 하나도 등록 안 된 상태
            return []
        query_desc = query_desc.astype(np.float64)
        query_desc = query_desc / np.linalg.norm(query_desc)

        scores = self.all_global_descs @ query_desc
        top_k = min(RETRIEVAL_TOP_K, len(self.retrieval_index))
        top_indices = np.argsort(-scores)[:top_k]
        return [self.retrieval_index[i] for i in top_indices]

    # MARK: - matching (hloc.match_features의 FeaturePairsDataset을 인메모리로 재현)

    def _match_candidate(self, query_pred: dict, room_id: str, candidate_name: str) -> np.ndarray:
        features_path = self.rooms[room_id].features_path
        with h5py.File(features_path, "r", libver="latest") as fd:
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

    def _gather_correspondences_by_room(
        self, query_pred: dict, candidates: list[tuple[str, str]]
    ) -> dict[str, tuple[np.ndarray, np.ndarray]]:
        """room마다 서로 다른 world 좌표계를 쓰므로, 대응점을 room별로 분리해서 모은다
        (한 PnP 안에 여러 room의 3D 점을 섞으면 안 됨)."""
        kpq = query_pred["keypoints"]
        points2d_by_room: dict[str, list[np.ndarray]] = {}
        points3d_by_room: dict[str, list[np.ndarray]] = {}

        for room_id, candidate in candidates:
            candidate_points_3d = self.rooms[room_id].kp_to_3d_db.get(candidate)
            if candidate_points_3d is None:
                continue

            matches = self._match_candidate(query_pred, room_id, candidate)
            valid = matches > -1
            if not np.any(valid):
                continue

            for query_idx in np.nonzero(valid)[0]:
                ref_idx = int(matches[query_idx])
                p3d = candidate_points_3d[ref_idx]
                if p3d is None:
                    continue
                points2d_by_room.setdefault(room_id, []).append(kpq[query_idx].astype(np.float64))
                points3d_by_room.setdefault(room_id, []).append(np.asarray(p3d, dtype=np.float64))

        return {
            room_id: (np.stack(points2d_by_room[room_id], 0), np.stack(points3d_by_room[room_id], 0))
            for room_id in points2d_by_room
        }

# server

pipeline이 빌드한 DB를 로드해서 쿼리 이미지 -> 6DoF pose를 리턴하는 FastAPI 서버.

## 설치

이 서버도 쿼리 이미지에서 직접 SuperPoint/NetVLAD/LightGlue를 돌리기 때문에, pipeline과
동일하게 hloc + pycolmap이 필요하다. pipeline에서 이미 `--recursive`로 clone해둔
`third_party/Hierarchical-Localization`을 재사용해서 다시 clone할 필요는 없다.

```bash
python -m venv .venv
source .venv/bin/activate   # Windows는 .venv\Scripts\activate
pip install -r requirements.txt
pip install -e ../pipeline/third_party/Hierarchical-Localization
```

## 실행

```bash
export DC_VPS_DB_DIR=../pipeline/outputs/<scan_name>
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

## API

- `GET /health` — 헬스체크
- `POST /localize` — multipart form.
  - `image`: 쿼리 이미지 파일
  - `fx`, `fy`, `cx`, `cy`, `width`, `height`: 쿼리 이미지를 찍은 카메라의 intrinsics
    (PnP에 필수 — 쿼리 카메라가 스캔에 쓴 iPhone과 다를 수 있으므로 매 요청마다 받는다)
  - 성공 시 `{"translation": [x,y,z], "quaternion": [qx,qy,qz,qw], "num_inliers": N}` 리턴
    (world 좌표계 기준 카메라 pose, `ios-capture`의 poses.jsonl `camera_transform`과 동일한
    camera-to-world 컨벤션). 매칭 실패/inlier 부족 시 422.

```bash
curl -X POST http://localhost:8000/localize \
  -F "image=@query.jpg" \
  -F "fx=1462.0" -F "fy=1462.0" -F "cx=966.5" -F "cy=720.7" \
  -F "width=1920" -F "height=1440"
```

## 구현 메모

`app/localize.py`의 `Localizer.__init__`에서 SuperPoint/NetVLAD/LightGlue 모델을
**서버 시작 시 한 번만** 로드해서 인스턴스에 캐싱해둔다. `localize()`는 이미 로드된
모델로 쿼리 이미지를 바로 처리한다 — 전처리(리사이즈/grayscale)와 후처리(keypoint를
원본 해상도로 역스케일)는 `hloc.extract_features.ImageDataset`/`main()`의 로직을
인메모리로 그대로 옮겨왔고, 매칭은 `hloc.match_features.FeaturePairsDataset`의 텐서
포맷을 그대로 재현해서 캐싱된 LightGlue 모델에 직접 넣는다. DB 빌드 때와 동일한
좌표 변환이라 좌표계가 어긋나지 않는다 (실제 스캔 프레임 재입력 시 ground-truth와
오차 수십 마이크로미터 수준으로 일치하는 것으로 검증함).

NetVLAD 전역 디스크립터로 DB 후보 top-k(`RETRIEVAL_TOP_K`)를 코사인 유사도로 뽑고,
LightGlue로 매칭한 뒤 매칭된 DB keypoint의 3D 좌표(`kp_to_3d_db.pkl`)를 모아
PnP+RANSAC(`pycolmap.estimate_and_refine_absolute_pose`)으로 pose를 추정한다.

**이전엔 요청마다 모델을 새로 로드해서 쿼리 1건에 30초~1분 걸렸는데, 캐싱 후엔
서버 시작 시 모델 로딩에 ~5초, 이후 쿼리는 건당 10~20초대로 줄었다** (2026-08-17,
Apple Silicon Mac, CPU 추론 기준). 여전히 실시간이라 부르긴 어렵지만 로봇 루프에
붙이기엔 훨씬 현실적인 수준. 더 빠르게 하려면 GPU 추론이나 배치 처리가 다음 단계.

`SUPERPOINT_CONF`/`RETRIEVAL_CONF`/`RETRIEVAL_TOP_K`는 `pipeline/dc_vps_pipeline/config.py`와
반드시 같은 값을 써야 한다 (DB가 그 설정으로 빌드됐기 때문). pipeline과 server가 별도
venv라 패키지로 공유하지 않고 값만 복제해뒀으니, pipeline 쪽 설정을 바꾸면 여기도 같이
바꿔야 한다.

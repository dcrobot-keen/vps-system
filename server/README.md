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

`app/localize.py`의 `Localizer.localize()`: 쿼리 이미지 1장을 임시 폴더에 써서
`hloc.extract_features.main()`을 그대로 호출해 SuperPoint/NetVLAD를 추출한다(전처리/
후처리 로직을 pipeline의 db_build.py와 동일하게 재사용하기 위함). NetVLAD 전역
디스크립터로 DB 후보 top-k(`RETRIEVAL_TOP_K`)를 코사인 유사도로 뽑고, LightGlue로
매칭한 뒤 매칭된 DB keypoint의 3D 좌표(`kp_to_3d_db.pkl`)를 모아 PnP+RANSAC
(`pycolmap.estimate_and_refine_absolute_pose`)으로 pose를 추정한다.

현재는 요청마다 SuperPoint/NetVLAD/LightGlue 모델 가중치를 새로 로드한다(요청당 수 초
추가) — 실시간 로봇 루프에 붙이기 전에는 최적화 우선순위가 아니라고 판단해 일단 단순하게
구현했다. 필요해지면 `Localizer.__init__`에서 모델을 한 번만 로드하도록 바꿀 수 있다.

`SUPERPOINT_CONF`/`RETRIEVAL_CONF`/`RETRIEVAL_TOP_K`는 `pipeline/dc_vps_pipeline/config.py`와
반드시 같은 값을 써야 한다 (DB가 그 설정으로 빌드됐기 때문). pipeline과 server가 별도
venv라 패키지로 공유하지 않고 값만 복제해뒀으니, pipeline 쪽 설정을 바꾸면 여기도 같이
바꿔야 한다.

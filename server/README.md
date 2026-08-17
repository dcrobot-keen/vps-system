# server

pipeline이 빌드한 DB를 로드해서 쿼리 이미지 -> 6DoF pose를 리턴하는 FastAPI 서버.

## 설치

hloc(SuperPoint/NetVLAD/LightGlue)이 필요하다. `pipeline/README.md`대로
`pipeline/third_party/Hierarchical-Localization`을 `--recursive`로 clone해둔 뒤 진행할 것
(pipeline과 server가 같은 clone을 공유해서 editable 설치한다).

```
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
```

## 실행

```
set DC_VPS_DB_DIR=..\pipeline\outputs\<scan_name>
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

`DC_VPS_DB_DIR`는 `db_build.py`가 만든 `kp_to_3d_db.pkl` + feature(h5) 파일이 있는
디렉토리를 가리켜야 한다. 앱 임포트 시점에 `Localizer`가 이 DB를 로드하므로, 없으면
서버 시작 자체가 실패한다.

## API

- `GET /health` — 헬스체크
- `POST /localize` — multipart form.
  - `image`: 쿼리 이미지
  - `fx`, `fy`, `cx`, `cy`: 쿼리 카메라 intrinsics (쿼리 이미지 해상도 기준)
  - `width`, `height`: 쿼리 이미지 해상도

  DB를 만든 스캔 카메라와 쿼리 카메라(로봇/iPhone)의 렌즈/해상도가 다를 수 있어
  intrinsics는 서버가 추정하지 않고 호출자가 매 요청마다 함께 보낸다.

  성공 시 `{"translation": [x,y,z], "quaternion": [qx,qy,qz,qw], "num_inliers": N}` 리턴
  (world 좌표계, camera-to-world). 매칭 실패/inlier 부족(< `config.MIN_INLIERS`)이면
  422와 `{"detail": "..."}`을 리턴한다.

## 구현 (`app/localize.py`)

1. 쿼리 이미지에서 SuperPoint 추출 (hloc.extract_features, 임시 디렉토리에 1장만)
2. NetVLAD로 DB에서 top-k(`config.RETRIEVAL_TOP_K`, DB 이미지 수보다 크면 클램프) 후보 검색
3. LightGlue로 쿼리-후보 2D-2D 매칭 -> 매칭된 DB keypoint의 3D 좌표(`kp_to_3d_db.pkl`) 확보
4. `pycolmap.estimate_and_refine_absolute_pose`(PnP+RANSAC)로 world-to-camera pose 추정,
   `num_inliers < MIN_INLIERS`면 실패 처리
5. pycolmap이 리턴하는 world-to-camera를 `.inverse()`로 뒤집어 camera-to-world로 변환해서 리턴
   (ARKit camera_transform/db_build.py와 관례를 맞추기 위함)

## 테스트

pipeline과 동일하게 합성 scan(`dc_vps_pipeline.testing`)으로 DB를 빌드하고, 그 DB를
만든 것과 동일한 쿼리 이미지로 로컬라이즈해서 identity pose(translation≈0,
quaternion≈[0,0,0,1])가 복원되는지 검증한다. 검색/매칭/PnP 전체 경로에 대한
sanity check.

```
pip install -r requirements-dev.txt
python -m pytest tests/ -v
```

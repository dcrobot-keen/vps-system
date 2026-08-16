# server

pipeline이 빌드한 DB를 로드해서 쿼리 이미지 -> 6DoF pose를 리턴하는 FastAPI 서버.

## 설치

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

## API

- `GET /health` — 헬스체크
- `POST /localize` — multipart form, `image` 필드에 쿼리 이미지. 성공 시
  `{"translation": [x,y,z], "quaternion": [qx,qy,qz,qw], "num_inliers": N}` 리턴.

`app/localize.py`의 `Localizer.localize()`는 아직 미구현(TODO) — SuperPoint 추출,
NetVLAD 후보 검색, LightGlue 매칭, PnP+RANSAC pose 추정 로직을 다음 단계에서 채운다.

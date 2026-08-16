# pipeline

scan_<name>/ 폴더(ios-capture 앱 출력)를 받아 hloc DB(2D-3D 대응 테이블)를 빌드한다.

## 설치

```
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
```

## 실행

```
python -m dc_vps_pipeline.db_build <scan_dir> <output_dir>
```

`<output_dir>`에 SuperPoint/NetVLAD feature(h5)와 `kp_to_3d_db.pkl`(keypoint별 world 3D 좌표)이
생성된다. 이 결과물을 `server/`의 `DC_VPS_DB_DIR`로 지정해서 로컬라이제이션 서버에서 사용한다.

## 정합 정책

`dc_vps_pipeline/geometry.py`, `dc_vps_pipeline/config.py` 참고. 요약:

- keypoint를 depth 해상도(256×192)로 스케일 다운해서 lookup (반대 방향 X)
- nearest-neighbor lookup만 사용 (bilinear 금지 — flying pixel 문제)
- confidence < medium인 포인트는 버림
- depth > 5m인 포인트는 버림 (공장 실내 스캔 기준, 필요시 config.py에서 조정)

# pipeline

scan_<name>/ 폴더(ios-capture 앱 출력)를 받아 hloc DB(2D-3D 대응 테이블)를 빌드한다.

## 설치

hloc은 `pip install git+https://...`로 설치하면 third_party git submodule
(SuperGluePretrainedNetwork 등)이 빠져서 SuperPoint import가 깨진다
(`ModuleNotFoundError: No module named 'SuperGluePretrainedNetwork'`).
반드시 `--recursive`로 clone한 뒤 editable 설치할 것.

```
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt

git clone --recursive https://github.com/cvg/Hierarchical-Localization.git third_party/Hierarchical-Localization
pip install -e third_party/Hierarchical-Localization
```

pycolmap(PnP+RANSAC용)은 hloc 설치 시 의존성으로 함께 설치된다.

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

## 테스트

실 iPhone 스캔 데이터(ios-capture 앱, macOS 필요) 없이도 `dc_vps_pipeline/testing.py`가
랜덤 블록 텍스처 RGB + 상수 depth/confidence로 scan_<name>/ 폴더를 합성해서
db_build.py 전체 경로(hloc SuperPoint/NetVLAD 추출 -> depth lookup -> backproject
-> 필터링)를 실제로 검증한다. camera_transform이 identity인 프레임은 backproject된
포인트의 world z가 depth 값과 정확히 같아야 한다는 성질을 이용해 backproject
정확성을, confidence=0/depth=10m 프레임은 필터링 로직을 검증한다.

`dc_vps_pipeline/testing.py`는 패키지 안에 있어 `server/`의 로컬라이제이션 테스트도
`pip install -e ../pipeline`로 동일하게 재사용한다.

```
pip install -r requirements-dev.txt
python -m pytest tests/ -v
```

SuperPoint/NetVLAD로 실제 모델을 돌리므로 프레임 4개 기준 수십 초 소요된다.

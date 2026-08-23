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

## 포인트클라우드 export (scan-to-map-studio 연동)

```
python -m dc_vps_pipeline.export_pointcloud <scan_dir> <output.ply> [--voxel-size 0.03]
```

같은 스캔의 depth 전체를 backproject해서 world-frame 포인트클라우드(PLY)로 내보낸다.
`db_build.py`가 SuperPoint keypoint 위치만 3D로 바꾸는 것과 달리 이건 밀집
포인트클라우드다. 목적: [scan-to-map-studio](https://github.com/dcrobot-keen/scan-to-map-studio)
(iPhone LiDAR 스캔 → 천장 제거 → 2D occupancy grid → 로봇 SLAM 지도와 ICP 정합 →
ROS tf 출력 스튜디오)의 `scripts/remove_ceiling.py` 입력으로 바로 쓸 수 있게 하기 위함.

같은 스캔 세션에서 뽑은 포인트클라우드라 hloc VPS DB(`db_build.py`)와 world 좌표계
원점/방향이 동일하다 — 그래서 scan-to-map-studio가 ICP로 계산해주는
`scan_basemap <-> map` ROS tf를 VPS pose에도 그대로 적용할 수 있다 (로봇/카메라가
없어서 수동으로만 하던 `ros2_ws/src/dc_vps_bridge`의 map 프레임 캘리브레이션을
대체할 수 있는 경로). 검증: 실제 스캔 데이터를 이 명령으로 export → scan-to-map-studio의
`remove_ceiling.py` → `rasterize_base_map.py`까지 수정 없이 그대로 통과해서 유효한
nav2 pgm/yaml 지도가 나오는 것까지 확인함 (2026-08-17).

좌표계 변환: ARKit world 좌표계(Y-up)를 scan-to-map-studio 관례(Z-up, `studio/usdz_import.py`의
`_convert_to_zup`과 동일한 `(x, y, z) -> (x, -z, y)`)로 바꿔서 저장한다.
`--voxel-size`(기본 3cm)로 겹치는 프레임 간 중복 포인트를 한 점으로 합친다.

## 오케스트레이터 — 스캔 하나로 VPS DB + 2D 지도 한 번에

```
python -m dc_vps_pipeline.orchestrate <scan_dir> <output_dir> \
    --scan-to-map-studio-dir <scan-to-map-studio 체크아웃 경로> \
    [--robot-map <robot_map_prefix>] [--project-name <name>]
```

`db_build.py`(hloc DB)를 실행한 뒤, `scan_dir`에 `scan.usdz`(ios-capture의 ARKit mesh
export, `ios-capture/README.md` "scan.usdz 동시 캡처" 참고)가 있으면 그걸 우선 쓰고,
없으면 `export_pointcloud.py`(depth 기반 포인트클라우드)로 폴백한다.
`scan.usdz`가 바닥/벽 커버리지가 훨씬 좋다 (실측 비교: 같은 조건에서 free 셀
1121개 -> 6097개, 지도 형태도 복도 줄무늬가 아니라 명확한 방 폴리곤으로 나옴 —
ARKit의 실시간 mesh fusion이 스로틀링된 depth 프레임 단순 backproject보다 구멍을
잘 메워주기 때문).

`--scan-to-map-studio-dir`를 줬으면 scan-to-map-studio의 `scripts/studio.py new` /
`process`(`--usdz` 또는 `--ply`)를 그 프로젝트 자체 venv(`<dir>/.venv/bin/python`,
`--scan-to-map-studio-python`으로 override 가능)로 subprocess 호출해서 report.html/2D
지도/(있으면) 로봇 지도 정합까지 이어서 만든다. `--scan-to-map-studio-dir`를 생략하면
hloc DB + (usdz 또는 포인트클라우드)까지만 생성.

**scan-to-map-studio 쪽에 `--ply` 입력 옵션이 있어야 한다** — 원래 `.usdz`만 받던
`scripts/studio.py process`/`studio/pipeline.py`의 `run_pipeline()`에 이미 만들어진
포인트클라우드를 바로 받는 경로를 추가했다 (usdz->ply 변환 단계만 건너뛰고 나머지는
동일). 실제 스캔 데이터로 `orchestrate.py` 전체를 `--ply` 경로(hloc DB 빌드 →
export_pointcloud → scan-to-map-studio `new`+`process --ply`)와 `--usdz` 경로(hloc DB
빌드 → scan.usdz 자동 감지 → `new`+`process --usdz`) 둘 다 한 명령으로 돌려서 hloc DB
(`kp_to_3d_db.pkl` 등)와 scan-to-map-studio project(`report.html`, `viewer.html`,
`overlay.glb`, `map/map.pgm`+`.yaml` 등)가 정상 생성되는 것까지 검증함 (2026-08-17).

## 쿼리 결과를 지도에 표시

```
python -m dc_vps_pipeline.visualize_query <image.jpg> <fx> <fy> <cx> <cy> <width> <height> \
    --scan-to-map-studio-project <scan-to-map-studio 프로젝트 폴더> \
    [--server-url http://localhost:8000/localize] [--output map_with_query.png]
```

쿼리 사진을 `server/`(`/localize`)에 보내서 위치를 구한 뒤, scan-to-map-studio가
만든 `map/map.png` 위에 빨간 점으로 찍는다. VPS 서버가 리턴하는 translation은
ARKit world 좌표계(Y-up)라, `export_pointcloud.py`/`studio/usdz_import.py`와 동일한
Z-up 변환((x,y,z) -> (x,-z,y))을 적용한 뒤 `map.yaml`의 origin/resolution으로 픽셀
위치를 계산한다 (`rasterize.py`가 저장 시 상하 반전하는 것까지 반영). 실제
쿼리(inlier 673개)로 찍어보니 방 안 실제 공간(흰색, free)에 정확히 찍히는 것까지
확인함 (2026-08-17).

`<image>`는 서버가 바로 디코딩 가능한 JPEG/PNG여야 한다 — iPhone 사진이 HEIC면
먼저 변환 필요 (예: macOS `sips -s format jpeg in.HEIC out.jpg`). `fx/fy/cx/cy`는
그 사진의 실제 해상도 기준 intrinsics — 스캔 때와 해상도가 다르면 비율로 스케일
해야 한다 (`server/README.md`의 curl 예시 참고).

## 정확도 실측 (VPS 추정 위치 vs 실제 위치)

```
python -m dc_vps_pipeline.measure_accuracy <image.jpg> <fx> <fy> <cx> <cy> <width> <height> \
    --scan-to-map-studio-project <scan-to-map-studio 프로젝트 폴더> \
    [--ground-truth-pixel <col>,<row>]
```

`visualize_query.py`와 같은 방식으로 서버에 쿼리하고 지도에 VPS 추정 위치(빨강
점)를 띄운 뒤, 사용자가 "실제로 여기 서 있었다"는 지점을 지도 위에서 클릭하면
(초록 점) 그 픽셀 거리를 `map.yaml`의 resolution(m/pixel)으로 환산해서 오차를
미터 단위로 출력한다. 지도가 이미 실측 스캔에서 나온 정확한 축척이라는 걸
이용하는 거라 별도로 줄자를 들 필요가 없다. `--ground-truth-pixel`로 픽셀
좌표를 직접 넘기면 창을 안 띄우고 바로 계산한다(스크립트 자동화용).
`estimated_pixel()`/`report_error()`의 거리 계산 로직은 실제 map.yaml
(resolution=0.05m/px)로 10px 오프셋 -> 0.5m 오차가 정확히 나오는 것까지
검증했다(2026-08-22).

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

## `pyproject.toml`은 왜 있나

`server/`가 이 패키지를 `pip install -e ../pipeline`로 설치해서 `dc_vps_pipeline.config`를
직접 import한다 (server/README.md 참고) — DB 빌드에 쓴 hloc 설정(`SUPERPOINT_CONF` 등)을
server의 쿼리 추출도 그대로 따라가야 해서, 값을 복제하는 대신 공유한다. `config.py`를
바꾸면 기존 DB는 다시 빌드해야 하고, server도 (재설치 없이 바로) 같이 바뀐다.

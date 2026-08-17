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

`db_build.py`(hloc DB) + `export_pointcloud.py`(포인트클라우드)를 실행한 뒤,
`--scan-to-map-studio-dir`를 줬으면 scan-to-map-studio의 `scripts/studio.py new` /
`process --ply`를 그 프로젝트 자체 venv(`<dir>/.venv/bin/python`, `--scan-to-map-studio-python`으로
override 가능)로 subprocess 호출해서 report.html/2D 지도/(있으면) 로봇 지도 정합까지
이어서 만든다. `--scan-to-map-studio-dir`를 생략하면 hloc DB + `base_map.ply`까지만 생성.

**scan-to-map-studio 쪽에 `--ply` 입력 옵션이 있어야 한다** — 원래 `.usdz`만 받던
`scripts/studio.py process`/`studio/pipeline.py`의 `run_pipeline()`에 이미 만들어진
포인트클라우드를 바로 받는 경로를 추가했다 (usdz->ply 변환 단계만 건너뛰고 나머지는
동일). 실제 스캔 데이터로 `orchestrate.py` 전체(hloc DB 빌드 → export_pointcloud →
scan-to-map-studio `new`+`process --ply`)를 한 명령으로 돌려서 hloc DB
(`kp_to_3d_db.pkl` 등)와 scan-to-map-studio project(`report.html`, `viewer.html`,
`overlay.glb`, `map/map.pgm`+`.yaml` 등)가 둘 다 정상 생성되는 것까지 검증함
(2026-08-17).

## 정합 정책

`dc_vps_pipeline/geometry.py`, `dc_vps_pipeline/config.py` 참고. 요약:

- keypoint를 depth 해상도(256×192)로 스케일 다운해서 lookup (반대 방향 X)
- nearest-neighbor lookup만 사용 (bilinear 금지 — flying pixel 문제)
- confidence < medium인 포인트는 버림
- depth > 5m인 포인트는 버림 (공장 실내 스캔 기준, 필요시 config.py에서 조정)

## `pyproject.toml`은 왜 있나

`server/`가 이 패키지를 `pip install -e ../pipeline`로 설치해서 `dc_vps_pipeline.config`를
직접 import한다 (server/README.md 참고) — DB 빌드에 쓴 hloc 설정(`SUPERPOINT_CONF` 등)을
server의 쿼리 추출도 그대로 따라가야 해서, 값을 복제하는 대신 공유한다. `config.py`를
바꾸면 기존 DB는 다시 빌드해야 하고, server도 (재설치 없이 바로) 같이 바뀐다.

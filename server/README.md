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
pip install -e ../pipeline   # dc_vps_pipeline.config를 그대로 import하기 위해 (아래 참고)
```

## 실행

단일 방(DB 하나):
```bash
export DC_VPS_DB_DIR=../pipeline/outputs/<scan_name>
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

여러 방(DB 여러 개, 콤마로 구분 — 아래 "여러 방" 참고):
```bash
export DC_VPS_DB_DIRS=../pipeline/outputs/scan_room_a,../pipeline/outputs/scan_room_b
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

`DC_VPS_DB_DIR`/`DC_VPS_DB_DIRS`는 **처음 기동할 때만** 쓰인다 — 그 이후로는
`rooms_manifest.json`(경로는 `DC_VPS_ROOMS_MANIFEST`로 변경 가능)이 현재 로드된
room 목록의 원본이 된다. 자세한 내용은 아래 "room 라이프사이클(재시작 없이
추가/제거)" 참고. 두 env var 다 없고 manifest도 없으면 room 0개로 시작한다(전부
`/rooms`로 나중에 등록 가능) — DB 파일이 없는 명시적 경로를 줬을 때만 시작 실패한다.

## API

- `GET /health` — 헬스체크
- `POST /localize` — multipart form.
  - `image`: 쿼리 이미지 파일
  - `fx`, `fy`, `cx`, `cy`, `width`, `height`: 쿼리 이미지를 찍은 카메라의 intrinsics
    (PnP에 필수 — 쿼리 카메라가 스캔에 쓴 iPhone과 다를 수 있으므로 매 요청마다 받는다)
  - 성공 시 `{"room_id": "scan_...", "translation": [x,y,z], "quaternion": [qx,qy,qz,qw],
    "num_inliers": N, "runner_up_room_id": "scan_..." | null, "runner_up_inliers": N}`
    리턴 (world 좌표계 기준 카메라 pose, `ios-capture`의 poses.jsonl `camera_transform`과
    동일한 camera-to-world 컨벤션. `room_id`는 매칭된 DB 디렉터리 이름 — 아래 "여러 방"
    참고). `runner_up_*`는 2등으로 경합한 room과 그 inlier 수(관측/로깅용, room이 하나뿐이거나
    2등이 없으면 `null`/`0`). 매칭 실패/inlier 부족/room 판별 모호 시 422 — 아래 "여러 방"의
    모호성 처리 참고.

```bash
curl -X POST http://localhost:8000/localize \
  -F "image=@query.jpg" \
  -F "fx=1462.0" -F "fy=1462.0" -F "cx=966.5" -F "cy=720.7" \
  -F "width=1920" -F "height=1440"
```

- `GET /rooms` — 현재 로드된 room 목록: `{"rooms": [{"room_id": "scan_...", "num_images": N}, ...]}`
- `POST /rooms` — 이미 빌드된 DB 디렉터리를 재시작 없이 등록. body
  `{"db_dir": "../pipeline/outputs/<scan_name>", "replace": false}`. `db_dir`는 서버
  프로세스 기준 경로(상대경로면 서버를 실행한 cwd 기준). room_id(디렉터리 이름)가
  이미 로드돼 있으면 `replace: true`가 아닌 한 409. DB 파일이 없으면 400.
- `DELETE /rooms/{room_id}` — 해당 room을 메모리에서 내린다. 없는 room_id면 404.

```bash
curl -X POST http://localhost:8000/rooms \
  -H "Content-Type: application/json" \
  -d '{"db_dir": "../pipeline/outputs/scan_room_c"}'

curl -X DELETE http://localhost:8000/rooms/scan_room_a
```

## 여러 방(room)

`DC_VPS_DB_DIRS`로 여러 DB를 동시에 로드하면, 쿼리 이미지가 어느 DB(room)와
매칭됐는지 자동으로 찾아준다. 각 DB 디렉터리 이름(보통 `scan_<name>`)이 그대로
`room_id`가 된다 — 그러니 여러 방을 등록할 땐 디렉터리 이름이 겹치지 않아야 한다.

동작 방식: NetVLAD retrieval은 room 경계 없이 전체 DB를 가로질러 top-k를 찾고,
그 후보를 room별로 묶어서 room마다 따로 LightGlue 매칭 + PnP를 시도한다 (서로 다른
room은 world 좌표계가 다른 별도 스캔이라, 한 PnP에 여러 room의 3D 점을 섞어 쓸 수
없어서 이렇게 분리했다). 방 개수가 늘수록 room마다 PnP를 시도할 수 있어 쿼리가
느려질 수 있다.

**room 판별 모호성 처리**: inlier가 제일 많은 room을 그냥 채택하지 않는다 — 1등
room의 inlier가 `MIN_INLIERS`를 넘겨도, 2등 room과의 격차가 `MIN_INLIER_MARGIN_RATIO`
(기본 1.5배) 미만이면 "room 판별이 모호함"으로 보고 422를 리턴한다. 서로 다른 두
room이 같은 쿼리에서 둘 다 임계값 근처의 inlier로 경합하는 경우가 실제로 있었는데
(부엌 사진이 어떤 시도에서는 부엌으로, 어떤 시도에서는 거실로 매칭 — 둘 다 inlier
12개), 이럴 때 1등을 그냥 채택하면 로봇이 완전히 다른 room의 좌표계로 튈 수 있어서
더 위험하다. `runner_up_room_id`/`runner_up_inliers`는 이 판단에 이미 쓰인 값을
그대로 응답에 노출한 것 — 성공 응답에도 항상 실려 있어 관측/로깅에 쓸 수 있다.

## room 라이프사이클(재시작 없이 추가/제거)

room을 새로 스캔했거나 다시 빌드했을 때, 예전에는 `DC_VPS_DB_DIRS`를 고쳐서 서버를
재시작해야 했다 — 그때마다 SuperPoint/NetVLAD/LightGlue 모델을 처음부터 다시
로드하고(수 초), 그 사이 다른 room을 쓰던 쿼리도 전부 끊겼다. `/rooms` API는 이미
빌드된 DB 디렉터리를 **모델 재로드 없이** 등록/해제한다 — `Localizer.add_room()`/
`remove_room()`은 h5/pickle을 읽고 NetVLAD retrieval용 배열을 다시 쌓는 것뿐이라
GPU를 쓰지 않고 수십 ms 안에 끝난다.

- **원본 스캔에서 DB를 새로 빌드하는 것도 이제 이 서버가 한 번에 처리한다** —
  `POST /scans`로 스캔 zip을 올리면 서버가 풀어서 `db_build.build_db()`를 돌리고
  결과를 자동으로 `add_room()`으로 등록한다(아래 "스캔 업로드(자동 빌드+등록)"
  참고). `pipeline/dc_vps_pipeline/db_build.py`/`orchestrate.py`를 손으로 돌려서
  `POST /rooms`로 등록하는 예전 2단계 수동 흐름도 여전히 그대로 동작한다(이미
  빌드된 DB가 있을 때, 또는 scan-to-map-studio 연동까지 하고 싶을 때).

## 스캔 업로드(자동 빌드+등록)

`POST /scans`에 스캔 폴더를 그대로 zip으로 올리면(raw body,
`Content-Type: application/zip`, `scan_name`/`replace`는 쿼리 파라미터) 서버가
`scan_<name>/`로 풀고 → DB 빌드 → room 등록까지 한 번에 끝낸다. multipart가
아니라 raw body인 이유는 클라이언트(ios-capture)에 네트워킹 코드가 전혀 없어서
멀티파트 손구현 위험을 피하기 위함. 스캔이 1~2GB일 수 있어서 메모리에 안 올리고
스트리밍으로 디스크에 바로 쓴다.

```bash
curl -X POST "http://<server>:8000/scans?scan_name=scan_20260825_bedroom&replace=true" \
  -H "Content-Type: application/zip" --data-binary @scan_20260825_bedroom.zip
# -> {"scan_name": "scan_20260825_bedroom", "status": "queued"}

curl http://<server>:8000/scans/scan_20260825_bedroom
# -> {"scan_name": ..., "status": "building"|"registering"|"done"|"failed", "room_id": ..., "error": ...}
```

- **한 번에 하나만.** GPU가 하나뿐이라 빌드 중에 다른 업로드가 오면 큐에 쌓지
  않고 바로 `409`로 거절한다(`server/app/scan_jobs.py`) — 현장에서 운영자가
  가끔 의도적으로 올리는 작업이라 큐가 필요할 만큼 빈번하지 않다.
- **GPU 경합.** 빌드(`db_build.build_db`)와 실시간 쿼리(`localize()`의 SuperPoint/
  NetVLAD/LightGlue forward pass)가 같은 GPU를 동시에 쓰지 않게
  `server/app/gpu_lock.py`의 `GPU_LOCK`으로 직렬화한다. `localize()`는 메서드
  전체가 아니라 실제 GPU 구간(`_extract_superpoint`/`_extract_netvlad`/
  `_match_candidate`)만 잠그므로, 빌드가 도는 동안에도 진행 중인 쿼리의
  PnP+RANSAC(CPU, 실제 병목의 대부분) 단계는 계속 돈다 — 빌드가 GPU 구간을 쥐고
  있는 잠깐 동안만 다른 쿼리가 대기한다.
- job 상태는 인메모리라 서버 재시작하면 사라진다(등록된 room 자체는
  `rooms_manifest.json`으로 유지되니 문제없음).
- **등록 상태는 재시작해도 유지된다.** 현재 로드된 room들의 DB 디렉터리 목록을
  `rooms_manifest.json`에 저장해두고, 다음 기동 때 `DC_VPS_DB_DIR(S)` 대신 이
  manifest를 읽는다 — 그래서 env var는 **최초 1회 시딩**에만 쓰이고, 이후로는
  `/rooms`로 바뀐 상태가 진실이 된다. manifest를 지우면 다음 기동 때 다시 env var
  기준으로 시딩한다.
- **동시 요청 안전성**: `add_room`/`remove_room`은 내부 lock으로 보호된다. `/localize`는
  `asyncio.to_thread`로 워커 스레드에서 돈다(아래 "성능/처리량" 참고) — room 등록/해제와
  진행 중인 쿼리가 실제로 겹칠 수 있지만, `self.rooms` 교체는 항상 새 dict/배열을
  통째로 만들어서 바꿔치기하는 방식이라(참고 대입은 원자적) 진행 중인 쿼리가 절반만
  바뀐 상태를 볼 일은 없다.

`ros2_ws/src/dc_vps_bridge`는 응답의 `room_id`를 보고 그 room에 맞는
`scan_basemap_<room_id>` tf(scan-to-map-studio로 각 room을 로봇 map에 각각
등록한 결과)를 자동으로 찾아 쓴다 — 방마다 서로 다른 world 좌표계를 로봇의 공용
`map` 프레임 하나로 이어붙이는 방식이다 (pipeline/README.md 참고). 실제로 DB 2개
(하나는 복제본)를 동시에 로드해서 retrieval이 room 경계를 넘나들지 않고, 3D 정보가
없는 room은 자동으로 걸러지고 다른 room이 정확히 선택되는 것까지 검증함
(2026-08-17).

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
Apple Silicon Mac, CPU 추론 기준).

## 성능/처리량 (2026-08-23, RTX 4080 SUPER + 16core CPU 기준)

GPU 추론(CUDA torch)으로 바꾼 뒤 프로파일링해보니, 실제 병목은 GPU가 아니라
**PnP+RANSAC(pycolmap, CPU)**이었다 — room 하나당 기본 옵션(`confidence=0.99999`,
`num_threads=1`)으로 최대 1.6초 걸리는데, SuperPoint+NetVLAD+LightGlue(GPU, 후보
20개 기준)는 전부 합쳐 ~0.6초밖에 안 든다. `PNP_RANSAC_CONFIDENCE=0.999`(로봇 위치
추정엔 5-nines 신뢰도가 필요 없음) + `PNP_RANSAC_NUM_THREADS`(기본 8, 코어 수의
절반 — `DC_VPS_PNP_THREADS`로 조정 가능)로 튜닝해서 room당 PnP를 ~9배 줄였다
(1.6초 → 0.17초). `/localize`를 `asyncio.to_thread`로 워커 스레드에 돌리는 것도
같이 적용(요청 하나가 이벤트 루프 전체를 막지 않게).

결과: 순차 요청 기준 쿼리 1건 0.88초(이전 2.7초 대비 ~3배), 동시 요청을 늘리면
처리량이 더 오르긴 하지만(순차 1.14 req/s → 동시 3개 1.87 req/s) **동시 6개부터는
1.9 req/s 근처에서 정체**된다. 스레드 수를 낮춰도(`DC_VPS_PNP_THREADS=2`) 처리량이
안 오르는 것까지 확인했으니 이건 CPU 경합이 아니라 **GPU가 물리적으로 하나라
요청마다 순차적으로 큐잉**되는 게 원인이다 — 이 서버 하나로는 초당 ~2건이 사실상
상한선이고, 목표(10 req/s대)에 도달하려면 (a) 여러 요청의 GPU 추론을 한 배치로
묶는 배치 서빙, 또는 (b) GPU 백엔드 서버를 여러 대로 수평 확장(로드밸런서 뒤에)
둘 중 하나가 필요하다 — 아직 둘 다 구현 안 함.

`SUPERPOINT_CONF`/`RETRIEVAL_CONF`/`RETRIEVAL_TOP_K`/`MATCHER_CONF`는
`pipeline/dc_vps_pipeline/config.py`와 반드시 같은 값을 써야 한다 (DB가 그 설정으로
빌드됐기 때문). 예전엔 별도 venv라 값을 복제해뒀었는데, `pipeline/`에 최소
`pyproject.toml`을 추가해서 이제 `pip install -e ../pipeline`로 server venv에
`dc_vps_pipeline` 패키지를 editable 설치하고 `config.py`를 직접 import한다 — 값
복제가 없어졌으니 pipeline 쪽 설정을 바꾸면 server도 재설치 없이 자동으로 따라간다
(editable install이라 소스 변경이 바로 반영됨).

## 테스트

pipeline과 동일하게 합성 scan(`dc_vps_pipeline.testing`)으로 DB를 빌드하고, 그 DB를
만든 것과 동일한 쿼리 이미지로 로컬라이즈해서 identity pose(translation≈0,
quaternion≈[0,0,0,1])가 복원되는지 검증한다. 검색/매칭/PnP 전체 경로에 대한
sanity check.

```
pip install -r requirements-dev.txt
python -m pytest tests/ -v
```

## 방별 좌표계 -> 그룹 기준 좌표계 (`frame`)

`/localize`는 매칭된 room(=`scan_<name>` DB)의 ARKit world 좌표로 pose를 돌려준다. 방이 여러 개인
현장에서 pathfinder 프로젝트·시뮬레이터 월드는 정합 워크스페이스(scan-to-map-studio)가 만든
**그룹 기준 스캔** 좌표계를 쓰므로, 방마다 ScanAlignment가 필요하다.

```bash
DC_VPS_GROUP_ALIGNMENT=/path/to/group_alignment.json uvicorn app.main:app ...
```

를 주면 `/localize` 응답에 `frame: { group, mapId, reference, alignment: {offsetX, offsetZ, yawRadians, method} }`가
붙고(`scan-group-alignment-v1`, `scan-format/SCAN_FORMAT.md`), `/rooms`에 `frames` 요약이 나온다. 기준 스캔은
항등 변환, 정렬 파일에 없는 room은 `frame: null`. 변환 수학은 소비자가 한다 -- ros-chromium의
`VpsCorrectionNode.applyFrame`(ARKit 평면 `x' = x cos + z sin + offsetX`, `z' = -x sin + z cos + offsetZ`, 슬라이스 평면 `y = -z`).
`app/frames.py`, `tests/test_frames.py`.

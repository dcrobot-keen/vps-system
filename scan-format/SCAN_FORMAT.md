# scan_&lt;name&gt;/ 포맷 스펙

> **정본 위치: `vps-system/scan-format/`.** `dc-vps-digital-twin`, `scan-to-map-studio`가 이 폴더(`SCAN_FORMAT.md` + `*.schema.json` + `conformance_check.py`)를 그대로 복사해 쓴다. 셋 다 이미 각자 독립적으로 이 포맷을 파싱하고 있어 하나로 통합하지 않았다 — 대신 스키마/스펙만 공유하고, 실제 파싱 로직은 각자 유지한다. 이유는 [architecture-improvements.md](../../doc/architecture-improvements.md) ④ 참고: `scan-to-map-studio`는 사내망 격리 현장에 USB로 들고 들어가는 용도라 실행 시점에 네트워크로 뭔가를 받아오는 공유 패키지/git submodule 방식을 쓸 수 없다. 스펙이 바뀌면 이 폴더를 먼저 고치고, 나머지 두 저장소의 `scan-format/` 사본에 수동으로 반영한다.
>
> 2026-08-29 기준. 실제 파싱 코드(`ios-capture/vps/ScanSessionManager.swift`가 씀, `pipeline/dc_vps_pipeline/scan_loader.py` + `dc-vps-digital-twin/convert_to_colmap.py`/`convert_to_transforms_json.py`가 읽음)를 직접 확인해 작성했다 — 추측 없음.

## 폴더 구조

```
scan_<name>/
├─ manifest.json
├─ rgb/frame_NNNNN.jpg
├─ depth/frame_NNNNN.depth       # raw float32, (192,256)=(height,width), row-major, 헤더 없음
├─ depth/frame_NNNNN.conf        # depth와 같은 포맷 -- 신뢰도(0/1/2, float32로 저장)
├─ poses/poses.jsonl             # 프레임당 한 줄
└─ scan.usdz                     # LiDAR 메시
```

## manifest.json

전체 필드는 [`manifest.schema.json`](./manifest.schema.json) 참고. `session_name`, `device_model`, `system_version`, `start_time`/`end_time`(유닉스 epoch 초), `frame_count`, `capture_interval_seconds`, `capture_min_distance_meters`.

**2026-08-29 기준 이 파일을 읽는 Python 코드는 없다** — `ios-capture` 앱 자체(`ProjectStore.swift`, 온디바이스 갤러리 UI)만 `start_time`/`frame_count`를 읽는다. `pipeline`, `dc-vps-digital-twin`은 `poses/poses.jsonl`만 보고 `manifest.json`은 아예 열지 않는다.

## poses/poses.jsonl

한 줄 = 프레임 하나. 전체 필드는 [`pose-record.schema.json`](./pose-record.schema.json) 참고.

| 필드 | 타입 | 비고 |
|---|---|---|
| `frame_id` | int | |
| `timestamp` | number | ARKit 프레임 타임스탬프 — **유닉스 epoch가 아니다**. manifest의 `start_time`/`end_time`과 시계가 다르다. |
| `rgb_path` | string | `scan_<name>/` 기준 상대경로 |
| `depth_path` | string | `scan_<name>/` 기준 상대경로. 같은 이름의 `.conf` 파일이 옆에 있다고 가정 |
| `camera_transform` | number[4][4] | row-major, camera-to-world, **ARKit/OpenGL 축 규약**(Y-up). 마지막 행 고정 `[0,0,0,1]` |
| `intrinsics.{fx,fy,cx,cy}` | number | RGB 해상도 기준 |
| `intrinsics.{width,height}` | int | RGB 해상도 |
| `tracking_state` | `"normal"` \| `"notAvailable"` \| `"limited"` | 세 소비자 모두 `"normal"`이 아닌 프레임은 버린다 |

`dc-vps-digital-twin/convert_to_colmap.py`는 여기서 COLMAP(OpenCV 축 규약)으로 변환하고, `convert_to_transforms_json.py`는 ARKit 축 규약이 Nerfstudio/Instant-NGP와 이미 맞는다는 전제로 `camera_transform`을 그대로 `transform_matrix`에 옮긴다.

## depth/*.depth, depth/*.conf

raw binary float32, row-major, 고정 `(192, 256)` = `(height, width)`, 헤더 없음. `.conf`는 신뢰도(개념적으로는 0/1/2 정수)를 같은 float32/192x256 포맷으로 저장한 것.

> **알려진 취약점**: 이 `(192, 256)` 크기는 세 Python 소비자 전부(`pipeline/config.py`, `convert_to_colmap.py`)에 **각자 따로** 하드코딩된 상수이지, `manifest.json`이나 `poses.jsonl` 어디에도 명시적으로 기록되지 않는다. 다른 LiDAR 해상도를 쓰는 기기가 추가되면 이 스펙 문서만 봐서는 알 수 없고, 세 곳의 하드코딩을 전부 찾아 고쳐야 한다. **개선 여지(이번 범위 밖)**: depth 해상도를 `poses.jsonl`의 `intrinsics` 옆에 명시적으로 적어두면 이 리스크가 사라진다 — 지금은 스펙을 공유하는 데까지만 하고, 실제 포맷 변경은 별도 작업으로 남겨둔다.

## scan.usdz

LiDAR 메시. **`scan-to-map-studio`는 이 파일만 쓰고 `manifest.json`/`poses.jsonl`/`depth/`는 전혀 읽지 않는다**(코드로 직접 확인, 2026-08-29) — 그래서 이 저장소의 `scan-format/` 사본에는 `conformance_check.py`가 없다(검증할 것 자체가 없다).

## 검증

같은 폴더의 `conformance_check.py`로 최소 구조/필드 유효성을 확인할 수 있다(단, `manifest.json`/`poses.jsonl`을 실제로 읽는 저장소, 즉 `vps-system`과 `dc-vps-digital-twin`에서만 유의미하다):

```bash
pip install jsonschema
python conformance_check.py <scan_dir>
```

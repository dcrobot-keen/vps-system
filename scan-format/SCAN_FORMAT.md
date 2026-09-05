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

전체 필드는 [`manifest.schema.json`](./manifest.schema.json) 참고. `session_name`, `device_model`, `system_version`, `start_time`/`end_time`(유닉스 epoch 초), `frame_count`, `capture_interval_seconds`, `capture_min_distance_meters`, 그리고 2026-09-05부터 `capture_min_rotation_degrees`와 `depth_encoding`(아래).

**프레임 저장 규칙(2026-09-05부터)**: `elapsed >= capture_interval_seconds` **이고** (`capture_min_distance_meters` 이상 이동 **또는** `capture_min_rotation_degrees` 이상 회전)일 때만 저장한다. 서 있으면 저장하지 않고, 제자리 회전은 각도 임계마다, 걷기는 거리 임계마다 저장되며 interval은 최대 저장률일 뿐이다. `capture_min_rotation_degrees`가 없는 옛 스캔은 "interval이 지나면 무조건" 규칙이라 정지 중에도 초당 10장이 쌓여 있다. JPEG 품질은 0.8(이전 0.85), 해상도는 hloc의 1600 px 리사이즈 때문에 1920×1440을 유지한다.

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
| `intrinsics.{fx,fy,cx,cy}` | number | **저장된** RGB 이미지 해상도 기준 |
| `intrinsics.{width,height}` | int | 저장된 RGB 이미지 크기. 2026-09-05부터 앱은 긴 변 1600 px(1600×1200)로 저장하고 intrinsics를 같은 배율로 기록한다(옛 스캔은 1920×1440). **소비자는 depth 배율을 이 값으로 계산해야 한다** -- `pipeline/geometry.depth_scale(image_size)`, digital-twin은 원래부터 이 값을 씀 |
| `tracking_state` | `"normal"` \| `"notAvailable"` \| `"limited"` | 세 소비자 모두 `"normal"`이 아닌 프레임은 버린다 |

`dc-vps-digital-twin/convert_to_colmap.py`는 여기서 COLMAP(OpenCV 축 규약)으로 변환하고, `convert_to_transforms_json.py`는 ARKit 축 규약이 Nerfstudio/Instant-NGP와 이미 맞는다는 전제로 `camera_transform`을 그대로 `transform_matrix`에 옮긴다.

## depth/*.depth, depth/*.conf

raw binary, row-major, `(192, 256)` = `(height, width)`, 헤더 없음. 인코딩은 두 버전이 있고 `manifest.json`의 `depth_encoding`이 어느 쪽인지 말해준다.

| | v1 (`depth_encoding` 키 없음, 2026-09-05 이전 스캔) | v2 (`depth_encoding.format_version: 2`) |
|---|---|---|
| `.depth` | float32 미터 | **uint16 little-endian 밀리미터**, `0` = 미측정 |
| `.conf` | float32로 저장된 0/1/2 | **uint8** 0/1/2 (ARKit `confidenceMap` 원본 그대로) |
| 프레임당 크기 | 196,608 + 196,608 B | 98,304 + 49,152 B |

v2로 바꾼 이유: v1은 `.conf`가 값 셋(0/1/2)을 4바이트씩 쓰고 `.depth`도 LiDAR 정밀도(cm급)에 비해 과한 float32라, 방 하나에 700 MB 중 약 180 MB가 0으로 채워진 바이트였다. 정밀도 손실은 없다(mm 양자화, 65.5 m 범위).

```json
"depth_encoding": { "format_version": 2, "width": 256, "height": 192, "depth": "uint16_mm", "confidence": "uint8" }
```

**읽는 쪽 규칙**: `depth_encoding`이 있으면 그대로 따르고, 없으면 v1. 파일 크기로도 구분된다(`4·w·h` = float32, `2·w·h` = uint16, `w·h` = uint8) — `pipeline/dc_vps_pipeline/scan_loader.py`(`load_depth_raw`/`load_confidence_raw`)와 `dc-vps-digital-twin/convert_to_colmap.py`는 2026-09-05부터 둘 다 읽고, 어느 쪽이든 float32 미터 / float32 0-1-2 배열로 돌려준다. 새로 쓰는 코드는 이 로더를 거쳐야 한다.

> v1에서 `(192, 256)`가 소비자마다 하드코딩돼 있던 문제는 v2의 `width`/`height`로 해소된다(v1 스캔은 여전히 하드코딩 상수에 의존). `conformance_check.py`는 매니페스트의 인코딩에 맞춰 두 파일의 크기를 검사한다.

## scan.usdz

LiDAR 메시. **`scan-to-map-studio`는 이 파일만 쓰고 `manifest.json`/`poses.jsonl`/`depth/`는 전혀 읽지 않는다**(코드로 직접 확인, 2026-08-29) — 그래서 이 저장소의 `scan-format/` 사본에는 `conformance_check.py`가 없다(검증할 것 자체가 없다).

## 프로젝트 zip (여러 스캔을 한 번에 내보낼 때)

ios-capture가 프로젝트(여러 스캔 묶음) 단위로 내보내는 zip은 스캔 폴더 하나짜리 zip과
두 가지가 다르다.

1. 스캔 폴더마다 자기 이름이 최상위 접두사로 붙는다: `scan_A/rgb/...`, `scan_B/rgb/...`.
   폴더 하나만 내보낼 때는 접두사 없이 `rgb/`, `depth/`, `poses/`가 최상위다(이전과 동일).
2. 최상위에 `group_alignment.json`(포맷 `scan-group-alignment-v1`)이 하나 들어간다.
   스캔마다 기준 스캔 좌표계로 옮기는 강체 변환이다.

```json
{
  "format": "scan-group-alignment-v1",
  "group": "우리집 1층",
  "reference": "scan_20260904_210428",
  "up_axis_convention": "top = -z",
  "alignments": {
    "scan_20260904_210551": { "offsetX": 3.412, "offsetZ": -1.087, "yawRadians": -0.1047, "method": "app" },
    "scan_20260904_210652": { "offsetX": 0, "offsetZ": 0, "yawRadians": 0, "method": "identity" }
  }
}
```

- `reference`는 그룹의 첫 스캔이며 항상 identity라 `alignments`에 들어가지 않는다.
  나머지 스캔은 정렬 여부와 관계없이 전부 들어간다.
- 변환은 ARKit 지면 평면 (x, z)에서 "회전 후 이동"이다(`ScanAlignment.applyXZ`):
  `x' = x·cos(yaw) + z·sin(yaw) + offsetX`, `z' = −x·sin(yaw) + z·cos(yaw) + offsetZ`.
  scan-to-map-studio의 Z-up 평면에서는 `(x, y) = (x, −z)`이므로 같은 변환이
  "yaw만큼 반시계 회전 + (offsetX, −offsetZ) 이동"이 된다. 이 대응은
  `studio/merge_slicemaps.py` 한 곳에서만 처리한다.
- `method`: 앱이 내보낼 때는 `app`(사용자가 정렬 화면이나 앵커링으로 놓은 값) 또는
  `identity`(정렬한 적 없음). 데스크탑 정합 도구가 값을 고치면 `pins`, `icp`, `manual`
  등으로 바뀌고 `metrics`(inlier, conflict, rmse_m, overlap_m)가 붙을 수 있다.
- 소비자: scan-to-map-studio `scripts/merge_slicemaps.py`(스캔별 slicemap을 이 변환으로 한
  격자에 합성). 이 파일은 그 저장소의 `tests/test_merge_slicemaps.py`와 이 저장소의
  `GroupAlignmentExportTests`가 양쪽에서 고정한다.

### 지도용 프로파일 (부분집합)

프로젝트 zip은 두 프로파일로 나간다(앱 `ScanExportProfile`).

| 프로파일 | 들어가는 것 | 크기(방 하나) | 용도 |
|---|---|---|---|
| 전체 | 위 폴더 구조 전부 | 수백 MB | VPS DB 빌드(hloc), 텍스처 |
| 지도용 | `manifest.json`, `poses/poses.jsonl`, `scan.usdz`, `floorplan.png`, `floorplan.json` (+ `group_alignment.json`) | 수 MB | 2D 지도, 슬라이스, 시뮬레이터 월드, 정렬 워크스페이스 |

지도용은 scan_<name>/의 **부분집합**이라 `conformance_check.py`를 통과하지 않는다
(rgb/depth 없음). scan-to-map-studio의 `studio.py process --usdz`, `slice_map.py`,
`merge_slicemaps.py`, `align_workspace.py`는 이 부분집합만으로 동작하고, vps-system
`pipeline`(DB 빌드)은 전체 프로파일이 필요하다.

## 검증

같은 폴더의 `conformance_check.py`로 최소 구조/필드 유효성을 확인할 수 있다(단, `manifest.json`/`poses.jsonl`을 실제로 읽는 저장소, 즉 `vps-system`과 `dc-vps-digital-twin`에서만 유의미하다):

```bash
pip install jsonschema
python conformance_check.py <scan_dir>
```

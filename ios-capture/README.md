# ios-capture

iPhone LiDAR(12 Pro 이상)에서 RGB + LiDAR depth + confidence + ARKit pose(6DoF) +
camera intrinsics를 프레임 단위로 동기화해서 저장하는 ARKit 캡처 앱.

macOS + Xcode가 필요하다. 이 폴더의 `ScanSessionManager.swift`를 새 Xcode
"App" 프로젝트(iOS, Swift, ARKit)에 추가해서 사용한다.

## 출력 폴더 구조

```
scan_<name>/
├── manifest.json          # 세션 메타데이터
├── rgb/
│   ├── frame_00001.jpg
│   └── ...
├── depth/
│   ├── frame_00001.depth  # Float32 raw depth, 256x192
│   └── ...
└── poses/
    └── poses.jsonl        # 프레임별 pose+intrinsics, 한 줄에 하나
```

## poses.jsonl 한 줄 포맷

```json
{"frame_id": 1, "timestamp": 1755302400.123, "rgb_path": "rgb/frame_00001.jpg", "depth_path": "depth/frame_00001.depth", "camera_transform": [[r00,r01,r02,tx],[r10,r11,r12,ty],[r20,r21,r22,tz],[0,0,0,1]], "intrinsics": {"fx":1450.2,"fy":1450.2,"cx":960.1,"cy":540.5,"width":1920,"height":1440}, "tracking_state": "normal"}
```

## 실무 주의사항

- **해상도**: sceneDepth/confidence는 RGB(1920×1440)보다 낮은 256×192로 나온다. depth는
  원본 그대로 저장하고, keypoint↔depth 정합은 Python DB 빌드 단계에서 처리한다.
- **tracking_state 필터링**: `.normal`이 아닌 프레임(`.limited` 등)은 pose 신뢰도가 낮으므로
  DB 빌드 시 제외하거나 낮은 가중치로 처리한다.
- **프레임 스로틀링**: 60fps 그대로 저장하면 용량이 폭발한다. 시간 간격(0.3~0.5초) 또는
  이동거리(20cm) 기준으로 샘플링한다.
- **좌표계 방향**: `capturedImage`, depth, confidence 모두 landscape-right 기준으로 나온다.
  저장 단계에서는 회전 보정을 하지 않고 raw 방향 그대로 저장한다 (intrinsics도 raw 기준).
- **export**: 로컬 저장 후 zip으로 묶어 AirDrop/파일 앱/서버 업로드. `pipeline/`의 DB 빌드
  스크립트가 이 폴더 구조를 그대로 파싱한다.

## TODO

- [ ] Xcode 프로젝트로 변환 (App target, ARKit + Photos/FileSystem 권한)
- [ ] JPEG 인코딩 + 파일 저장 구현 (`saveRGB`)
- [ ] depth/confidence raw 저장 구현 (`saveDepth`)
- [ ] 이동거리/시간 기반 스로틀링 구현 (`shouldCapture`)
- [ ] manifest.json 작성 (세션 시작/종료 시각, 프레임 수, 기기 모델)
- [ ] zip export + 공유 UI

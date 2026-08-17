# ios-capture

iPhone LiDAR(12 Pro 이상)에서 RGB + LiDAR depth + confidence + ARKit pose(6DoF) +
camera intrinsics를 프레임 단위로 동기화해서 저장하는 ARKit 캡처 앱.

macOS + Xcode가 필요하다. `vps.xcodeproj`가 이 폴더에 이미 있으니 그냥 열면 된다
(별도 프로젝트 생성/파일 드래그 불필요 — 실기기에서 빌드·설치까지 확인된 상태).

## 열기 & 실행

1. `ios-capture/vps.xcodeproj`를 Xcode로 연다.
2. 타겟 → **Signing & Capabilities**: 본인 Apple ID/팀 선택 (ARKit은 시뮬레이터에서
   동작하지 않으므로 실기기 필요).
3. LiDAR 탑재 기기(iPhone 12 Pro 이상 Pro 라인, iPad Pro)를 연결하고 빌드 & 실행.

소스 파일은 `vps/` 그룹 아래에 있다:
- `DCVPSCaptureApp.swift` (`@main` App 진입점)
- `ContentView.swift` (카메라 프리뷰 + 시작/정지/내보내기 UI)
- `ScanSessionManager.swift` (ARSession 캡처 로직) — `import Combine` 필요
  (`@Published`/`ObservableObject`용, 빌드 시 실제로 필요했던 import)
- `ZipArchiver.swift` (외부 의존성 없는 zip 내보내기) — `Data`의
  `withUnsafeBytes(of:)` 호출이 다른 오버로드와 모호해져서 `Swift.withUnsafeBytes`로
  명시적으로 한정해야 컴파일된다

앱 UI: 세션 이름을 입력하고 "시작"을 누르면 캡처가 시작되고, "정지"를 누르면
`Documents/scan_<name>/`에 저장이 끝난다. "내보내기"를 누르면 해당 폴더를 zip으로
묶어 공유 시트(AirDrop/파일 앱/서버 업로드 등)를 띄운다.

## 원래 별도 저장소였음

이 프로젝트는 원래 `~/code/vps01-app/vps`에 별도 git 저장소(GitHub:
`dcrobot-keen/vps-scan-app`)로 만들어졌다가, vps-system 모노레포와 소스가
갈라지는 걸 막기 위해 이 폴더로 합쳐졌다. 앞으로 앱 수정은 여기서 하고, 별도
저장소는 필요 없으면 정리해도 된다.

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

- [x] Xcode 프로젝트로 변환 (`vps.xcodeproj`, 저장소에 포함됨)
- [x] JPEG 인코딩 + 파일 저장 구현 (`saveRGB`)
- [x] depth/confidence raw 저장 구현 (`saveDepth`) — confidence는 pipeline의
      `load_depth_raw`(float32 전용)와 맞추기 위해 float32로 변환 저장한다.
- [x] 이동거리/시간 기반 스로틀링 구현 (`shouldCapture`)
- [x] manifest.json 작성 (세션 시작/종료 시각, 프레임 수, 기기 모델)
- [x] zip export + 공유 UI (`ZipArchiver.swift`, `ContentView.swift`)
- [x] 실기기(LiDAR 탑재) 빌드 검증 — 실제 iPhone에 설치해서 스캔 완료, pipeline
      DB 빌드까지 end-to-end 검증됨

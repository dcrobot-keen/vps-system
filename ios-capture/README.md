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
- `DCVPSCaptureApp.swift` (`@main` App 진입점, 루트 뷰는 `ProjectListView`)
- `ProjectListView.swift` (프로젝트 목록 — 새 프로젝트 만들기/삭제/내보내기 UI)
- `ProjectStore.swift` (`Documents/scan_*/` 폴더를 프로젝트 목록으로 읽고 삭제/zip
  내보내기를 처리하는 `ObservableObject`) — `import Combine` 필요 (`ScanSessionManager`와
  같은 이유)
- `ProjectDetailView.swift` (목록에서 프로젝트를 탭하면 나오는 뷰어 — scan.usdz가
  있으면 SceneKit 3D 미리보기, RGB 캡처 사진 썸네일 그리드)
- `ScanView.swift` (프로젝트 하나를 실제로 스캔하는 화면 — 카메라 프리뷰 + 시작/정지)
- `ScanSessionManager.swift` (ARSession 캡처 로직 + 실시간 mesh 프리뷰) —
  `import Combine` 필요(`@Published`/`ObservableObject`용, 빌드 시 실제로 필요했던 import)
- `ZipArchiver.swift` (외부 의존성 없는 zip 내보내기) — `Data`의
  `withUnsafeBytes(of:)` 호출이 다른 오버로드와 모호해져서 `Swift.withUnsafeBytes`로
  명시적으로 한정해야 컴파일된다
- `MeshExporter.swift` (`ARMeshAnchor` -> 무채색 `scan.usdz`, 실시간 프리뷰용
  `SCNGeometry` 변환도 재사용) — 실기기 검증 완료 (아래 "scan.usdz 동시 캡처" 참고)

색/텍스처(사진 기반 mesh 컬러링, Gaussian Splatting 등 Digital Twin급 시각화)는
이 앱의 범위에서 뺐다 — 이 앱은 VPS/지도화에 필요한 raw 데이터(rgb/depth/poses)와
무채색 mesh만 책임지고, 시각화는 GPU 서버 쪽 별도 프로젝트로 분리했다.

## 앱 UI (프로젝트 개념)

**목록 화면**(`ProjectListView`, 앱 시작 시 첫 화면): `Documents/scan_*/` 폴더들을
프로젝트로 나열한다. 오른쪽 위 **+**로 새 프로젝트 이름을 입력하면(중복 이름은
막음) 스캔 화면으로 넘어간다. 행을 **탭하면 뷰어**(`ProjectDetailView`)로 이동,
왼쪽으로 스와이프하면 **삭제**, 행 오른쪽 아이콘으로 **내보내기**(zip으로 묶어
공유 시트 — AirDrop/파일 앱/서버 업로드 등). 내보내기 버튼은 `.buttonStyle(.borderless)`로
탭 영역을 분리해서 행 전체의 NavigationLink와 안 겹치게 했다.

**뷰어 화면**(`ProjectDetailView`): scan.usdz가 있으면 "3D mesh 보기" 버튼으로
SceneKit(`SCNView`, `allowsCameraControl`로 핀치 확대/드래그 회전) 뷰어를 띄운다.
그 아래 캡처된 RGB 사진들을 썸네일 그리드로 보여준다 (`ImageIO`의
`CGImageSourceCreateThumbnailAtIndex`로 원본을 다 디코딩하지 않고 축소본만
비동기 로드 — 사진이 수백 장이어도 화면에 보이는 것만 로드됨).

**QuickLook 대신 SceneKit을 쓰는 이유**: 처음엔 `QLPreviewController`(시스템 AR
Quick Look 뷰어)를 썼는데, 실기기에서 첫 진입 시 몇 초 프리징이 확인됐다(QuickLook
프레임워크의 첫 사용 초기화 비용으로 추정). 앱 시작 시 미리 인스턴스를 만들어
비용을 앞당기는 것도 시도했지만, 그 타이밍이 iOS의 launch 애니메이션/제스처
시퀀스와 메인 스레드를 다퉈서 오히려 `Gesture: System gesture gate timed out.`
경고와 함께 실행 자체가 늦어졌다. 앱이 스캔 화면에서 이미 SceneKit/ARSCNView를
쓰고 있어서, 뷰어도 SceneKit(`SCNScene(url:)`로 usdz 직접 로드)으로 바꾸니 추가
초기화 비용 자체가 없어져서 지연이 근본적으로 사라졌다.

**SceneKit 뷰어 성능 튜닝**: vertex 수십만 개짜리 usdz를 그대로 로드하니 처음엔
조작(회전/확대)이 버벅였다 — `SCNScene(url:)` 파싱을 메인 스레드에서 동기로 하던 것을
백그라운드로 옮기고, `rendersContinuously = false`(카메라를 실제로 만질 때만
다시 그림, `allowsCameraControl`이 알아서 그 타이밍에 트리거함) +
`preferredFramesPerSecond = 30`으로 유휴 상태에서 GPU를 계속 태우지 않게 했다.
그래도 느리면 mesh를 그대로 렌더링하는 것 자체(15만+ vertex, anchor당 별도
draw call 38개)가 한계일 수 있어서, 뷰어용으로 단순화(decimation)한 버전을
따로 만드는 것도 고려할 만하다.

**스캔 화면**(`ScanView`): 카메라 프리뷰(+ 실시간 mesh 와이어프레임, 아래 참고)가
바로 뜬다. **"스캔 시작"** → 캡처 시작, **"정지 & 저장"** → `scan_<프로젝트명>/`에
저장(rgb/depth/poses, 있으면 scan.usdz, manifest.json), **"완료"** → 목록 화면으로
복귀(목록이 새로고침되어 방금 만든 프로젝트가 보임).

## 스캔 중 실시간 mesh 프리뷰

카메라 화면 위에 지금까지 재구성된 LiDAR mesh를 반투명 와이어프레임(cyan)으로
겹쳐 그린다 — 어디를 아직 못 찍었는지 스캔하면서 바로 확인할 수 있어서, 지도
커버리지 부족 문제를 스캔 단계에서 예방하는 목적이다. `ScanSessionManager`가
`ARSCNViewDelegate`도 구현해서 `renderer(_:didAdd:for:)`/`didUpdate:for:` 콜백이
올 때마다 `MeshExporter.scnGeometry(for:worldSpace:)`(scan.usdz export와 같은
파싱 로직, `worldSpace: false`로 호출 — SceneKit이 넘겨주는 node가 이미
anchor 위치에 있어서 또 좌표 변환하면 이중 적용됨)로 만든 geometry를 그 node에
얹는다.

**⚠️ 실기기 미검증**: Swift 문법 파싱만 확인했다. 특히 `SCNMaterial.fillMode = .lines`
(와이어프레임 렌더링) 부분이 예상과 다르게 동작하거나 컴파일 에러가 날 수 있다 —
`scan.usdz` export 때 ModelIO 브릿지 API 3개가 연달아 없었던 전례가 있으니 감안할 것.
그 경우 `.fillMode`를 빼고 반투명 단색 채우기(`material.transparency = 0.5` 등)로
대체하면 된다.

## Digital Twin급 시각화(사진 기반 텍스처링/Gaussian Splatting)는 별도 프로젝트

한때 `MeshColorizer.swift`(vertex color)와 `MeshTexturer.swift`(chart 기반 UV
텍스처)로 scan.usdz에 실제 사진 색을 입히는 걸 시도했다 — occlusion 체크, 각도/거리
기반 프레임 선택, chart 단위 UV unwrap까지 상당히 다듬었지만, 최종적으로 이 앱
안에서 처리하기엔 결과물 품질(이음새, 해상도)에 근본적인 한계가 있다고 판단해서
제거했다. 이 종류의 "여러 사진을 하나의 일관된 표면 텍스처로 합성"하는 문제는
Gaussian Splatting(SuGaR 등) 쪽이 구조적으로 더 잘 풀고, 그건 GPU 서버가 필요한
완전히 다른 작업이라 별도 프로젝트로 분리했다. 이 앱은 그 파이프라인의 입력
데이터(rgb/depth/poses)를 만드는 역할까지만 담당한다.

## 원래 별도 저장소였음

이 프로젝트는 원래 `~/code/vps01-app/vps`에 별도 git 저장소(GitHub:
`dcrobot-keen/vps-scan-app`)로 만들어졌다가, vps-system 모노레포와 소스가
갈라지는 걸 막기 위해 이 폴더로 합쳐졌다. 앞으로 앱 수정은 여기서 하고, 별도
저장소는 필요 없으면 정리해도 된다.

## 출력 폴더 구조

```
scan_<name>/
├── manifest.json          # 세션 메타데이터
├── scan.usdz               # LiDAR mesh (있으면) — scan-to-map-studio --usdz 입력용
├── rgb/
│   ├── frame_00001.jpg
│   └── ...
├── depth/
│   ├── frame_00001.depth  # Float32 raw depth, 256x192
│   └── ...
└── poses/
    └── poses.jsonl        # 프레임별 pose+intrinsics, 한 줄에 하나
```

## scan.usdz 동시 캡처

`ARWorldTrackingConfiguration.sceneReconstruction`을 켜서(`.meshWithClassification`,
안 되면 `.mesh`) 스캔하는 동안 ARKit이 실시간으로 만드는 mesh(`ARMeshAnchor`)를
"정지" 시점에 모아 `MeshExporter.swift`가 `scan.usdz`로 내보낸다. rgb/depth/poses와
**같은 ARSession**에서 나온 mesh라 world 좌표계가 VPS DB와 완전히 동일하다 — 두
스캔을 따로 찍어 나중에 ICP로 정합할 필요가 없다. 또한 ARKit의 실시간 mesh fusion은
스로틀링된 depth 프레임을 단순 backproject하는 것보다 구멍이 덜 뚫린 메시를 만들어줘서,
`pipeline/export_pointcloud.py`보다 지도 품질이 나을 걸로 기대한다.

`scan.usdz`가 생기면 `pipeline/dc_vps_pipeline/orchestrate.py`가 자동으로 감지해서
`export_pointcloud.py`(depth 기반 sparse 포인트클라우드) 대신 이걸 우선 쓴다 —
실측 비교 결과 커버리지가 훨씬 좋다(같은 스캔 기준 free 셀 1121개 -> 6097개,
지도 형태도 복도 줄무늬가 아니라 명확한 방 폴리곤으로 나옴).

**실기기 검증 완료** (2026-08-17): 처음엔 세 번 연속 컴파일/런타임 에러가 났다 —
1. `MDLAsset.export(to:)`가 iOS에서 `.usdz` 확장자를 인식 못 함
   ("Unknown extension on URL"로 `MDLErrorDomain` 실패)
2. `SCNScene(mdlAsset:)`, `SCNNode(mdlObject:)`, `SCNGeometry(mdlMesh:)` — ModelIO↔SceneKit
   브릿지 API들이 이 SDK(iOS 26.6)엔 없음(컴파일 에러)

최종적으로 ModelIO를 아예 안 거치고, SceneKit 고유 API(`SCNGeometrySource`/
`SCNGeometryElement`)로 직접 geometry를 만들어 `SCNScene.write(to:)`로 저장하는
방식으로 해결했다. 실제 스캔(anchor 38개, vertex 15만 개)에서 `scan.usdz`(4.7MB)가
정상 생성되고, OpenUSD(`pxr`)로 읽었을 때 164,382개 포인트가 정상 추출되는 것,
scan-to-map-studio의 `remove_ceiling.py`→`rasterize_base_map.py`를 그대로 통과해서
유효한 지도가 나오는 것까지 확인함.

## poses.jsonl 한 줄 포맷

```json
{"frame_id": 1, "timestamp": 1755302400.123, "rgb_path": "rgb/frame_00001.jpg", "depth_path": "depth/frame_00001.depth", "camera_transform": [[r00,r01,r02,tx],[r10,r11,r12,ty],[r20,r21,r22,tz],[0,0,0,1]], "intrinsics": {"fx":1450.2,"fy":1450.2,"cx":960.1,"cy":540.5,"width":1920,"height":1440}, "tracking_state": "normal"}
```

## 실무 주의사항

- **스캔 중 뒤로 스와이프**: `ScanView`는 스캔 중엔 back 버튼을 숨기지만, iOS 기본
  스와이프-뒤로가기 제스처까지 막진 않는다. 스캔 중 스와이프로 나가면 `manifest.json`
  없이 rgb/depth만 남은 미완성 폴더가 생긴다(크래시나 데이터 손상은 아님, 그냥
  버려지는 폴더 — 목록에서 삭제하면 됨). 실제로 자주 발생하면 제스처를 막는 처리 추가 검토.
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
- [x] zip export + 공유 UI (`ZipArchiver.swift`, `ProjectListView.swift`)
- [x] 실기기(LiDAR 탑재) 빌드 검증 — 실제 iPhone에 설치해서 스캔 완료, pipeline
      DB 빌드까지 end-to-end 검증됨
- [x] `scan.usdz` 동시 캡처(`MeshExporter.swift`) 실기기 검증 완료 — 3번의 시행착오
      끝에 SceneKit 고유 API로 해결, scan-to-map-studio 파이프라인 통과까지 확인
- [ ] 스캔 중 실시간 mesh 프리뷰 — 실기기 미검증 (위 "스캔 중 실시간 mesh 프리뷰" 참고)
- [ ] 프로젝트 목록/삭제/내보내기 UI(`ProjectListView.swift`, `ProjectStore.swift`) —
      실기기 미검증. Swift 문법 파싱만 확인함. `ProjectStore.swift`는 최초 빌드에서
      `import Combine` 누락으로 컴파일 에러 발생, 수정함
- [ ] 프로젝트 뷰어(`ProjectDetailView.swift`, scan.usdz SceneKit 미리보기 + 사진
      썸네일) — 실기기 부분 검증: 초기 QuickLook 버전이 첫 진입 시 프리징(+ 미리
      warm-up 시도가 launch 시퀀스와 충돌)하는 걸 확인하고 SceneKit 기반으로 교체함.
      SceneKit 버전 자체는 아직 실기기 미검증

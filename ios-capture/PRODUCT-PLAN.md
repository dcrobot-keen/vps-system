# ios-capture → App Store 제품화 계획

> 2026-09-04 시작. 방향 **C**: 기본은 서버 없이 완결되는 **범용 LiDAR 룸 스캐너**(1.0 스코프),
> 로봇 스택(VPS 서버) 연동은 설정의 **"고급 모드"** 뒤에 숨긴 선택 기능.
> 이유: App Store 심사관은 우리 서버가 없다. 외부 서비스 없이는 쓸모없는 앱은 리젝된다.

## 전체 파이프라인에서 이 앱의 위치 (2026-09-04 재검토)

워크스페이스 전체 그림(아티팩트 "로봇 프로젝트 스택")에 비춰 C를 다시 점검한 결론.

- **이 앱은 파이프라인의 유일한 캡처 헤드다.** vps-system(pipeline/server) → dc-vps-digital-twin → scan-to-map-studio → pathfinder → ros-chromium 전부가 이 앱이 만든 `scan_<name>/`에서 시작한다. 즉 이 앱의 진짜 "API"는 화면이 아니라 **스캔 포맷 계약**(정본: `vps-system/scan-format/` — ④에서 실제 파싱 코드 기준으로 스키마화)이다.
- **C는 유효하다, 그러나 "고급 모드"는 "서버 업로드 토글"이 아니라 "로봇 파이프라인 계약 전체"로 재정의한다**: 포맷 fidelity(raw depth/pose/rgb + scan.usdz를 스펙 그대로), 정합 파일(`registration_transform.json`) 가져오기, VPS 업로드, 향후 플릿/로봇 연동. 소비자 코어(A)는 그 위에 얹힌 UX다. 코드상으론 이미 하나의 게이트(`ServerSettingsStore.isAdvancedModeEnabled`)로 시작했으니 파이프라인 기능은 전부 이 게이트 뒤로 모은다.
- **소비자 차별점은 파이프라인에서 나온다** — 온디바이스 위치 확인(ARWorldMap, 서버 없음), 얼굴 자동 모자이크, 원본 depth/pose 보존(다른 스캐너 앱은 메시만 줌). 이건 마케팅 포인트로 그대로 쓴다. 반대로 소비자 앱은 파이프라인 헤드의 **배포 채널**이 된다(스캔 데이터가 늘수록 캡처 품질 검증이 늘어남).
- **C가 만드는 진짜 리스크**: 소비자 제품 압력(UX 리팩터, iOS 버전 대응, 기능 추가)이 스캔 포맷 계약을 **조용히** 깨는 것. 지금 앱 쪽엔 이를 막는 자동 게이트가 없다(`conformance_check.py`는 데스크탑에서 결과물에 돌리는 것). → 아래 C-체크리스트에 "스캔 포맷 회귀 게이트"를 필수로 추가.
- **App Review 2.3.1(숨겨진 기능 금지)**: 고급 모드는 "숨김"이 아니라 설정 화면에 보이는 옵션이어야 하고, 심사 노트에 용도를 명시한다. 지금 구현(설정 토글 + 설명 footer)이 그 형태.
- **대안 D(두 빌드 타깃 분리 — 소비자 App Store 빌드 / 내부 파이프라인 빌드)**는 고급 모드 게이트가 커져 UX가 갈라지기 시작하면 전환한다. 단일 게이트를 유지하는 이유가 바로 그 전환을 싸게 만들기 위함.
- 소속 정리 액션: `LocalizeView`의 "정합 파일 가져오기"는 파이프라인 기능이므로 고급 모드가 켜져 있을 때만 노출(일반 사용자에겐 의미 없음). 위치 확인 자체는 소비자 기능으로 유지.
- 아티팩트 v1은 2026-08-29 스냅샷이라 ⑫~⑮(MapNode, pathfinder 다중 프로젝트, nav.html/Phase 8/TB3, 플릿 대시보드)와 iOS 신규 기능(위치 확인/deface/갤러리/App Store 준비)이 빠져 있다 → v2 갱신 필요.

## 제품 정의 (1.0)

- 대상: LiDAR iPhone/iPad 사용자 중 방/공간을 3D로 남기고 싶은 사람
- 핵심 흐름: 스캔 → 메시(scan.usdz) + 사진 → (선택) 텍스처 베이킹(textured.glb) → 보기/확대 → Files/공유로 내보내기
- 차별점 후보: 얼굴 자동 모자이크(개인정보), 서버 없는 온디바이스 위치 확인, 완전 오프라인, 원본 데이터(depth/pose) 보존
- 고급 모드(설정에서 켬): VPS 서버 업로드, 정합 파일 가져오기 등 로봇 스택 연동

## 상태 체크리스트

### A. App Store 하드 요건
- [x] 배포 타깃 26.5 → **17.0** (`ContentUnavailableView`가 17+ 최소, 그 외 16 이하 API만 사용)
- [x] `UIRequiredDeviceCapabilities` = arkit + 런타임 LiDAR 확인(`DeviceSupport`) + 미지원 기기 안내 화면(`UnsupportedDeviceView`)
- [x] `NSLocalNetworkUsageDescription` (고급 모드 LAN 업로드용)
- [x] Files 앱 노출: `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`
- [x] 서버 연동을 "고급 모드" 뒤로 (기본 꺼짐, `ServerSettingsStore.isAdvancedModeEnabled`)
- [x] `LocalizeView`의 "정합 파일 가져오기"(툴바 다운로드 아이콘)도 고급 모드 게이트 뒤로 — 파이프라인(scan-to-map-studio) 산출물이라 일반 사용자에겐 의미 없음
- [ ] 심사 노트에 고급 모드 용도 명시(App Review 2.3.1 "숨겨진 기능" 오해 방지) + 서버 없이 전체 플로우 데모 가능함을 명시
- [x] **제품명/브랜드/번들 ID — 결정(2026-09-04): "ScanMesh" / "스캔메시", `com.dcrobot.scanmesh`** — App Store 사전 검색으로 동일/유사 이름 없음을 확인하고 선택. `INFOPLIST_KEY_CFBundleDisplayName`(홈 화면 아이콘 이름), `PRODUCT_BUNDLE_IDENTIFIER`, `ProjectListView`의 네비게이션 타이틀("스캔메시")까지 반영. Xcode 내부 타깃/프로덕트 이름 자체는 여전히 "vps"(cosmetic, 사용자에게 안 보임 — 바꾸려면 Xcode의 Rename 리팩터로 해야 안전, 필수 아님)
- [x] 개발자 계정: **개인**으로 결정(2026-09-04) — 현재 팀 `GW4C35M572` 그대로 사용
- [ ] 앱 아이콘, 런치 스크린(현재 자동 생성), 스크린샷(iPhone 6.9"/6.5", **iPad 13"** — 아래 iPad 지원 결정으로 인해 필수)
- [x] **개인정보 처리방침 — GitHub Pages로 결정(2026-09-04)**: `docs/privacy/index.html`(한/영 병기) 작성 + `vps-system` 저장소에 Pages 활성화. URL: `https://dcrobot-keen.github.io/vps-system/privacy/`. **문의 이메일 주소가 아직 placeholder — 제출 전 실제 주소로 교체 필요**
- [ ] App Privacy 라벨(App Store Connect에서 별도 입력) — 사진 저장, 고급 모드 시 서버 전송 항목 신고
- [x] **로컬라이제이션 — 정적 UI 문자열** — `vps/Localizable.xcstrings` 작성(ko 소스 + en 번역, 37개 항목: 화면 타이틀/버튼/탭/섹션 헤더·푸터/placeholder/빈 상태 안내 전부). 이 과정에서 실제 버그 2개 발견·수정: `ServerSettingsView`/`ScanView`가 `Text("A" + "B")`처럼 두 리터럴을 `+`로 이어붙이던 곳이 있었는데, `+`는 `String`에만 있어서 그 결과가 `String`으로 타입이 굳어 `Text(_:LocalizedStringKey)`가 아니라 `Text(_:String)`(그대로 표시, 지역화 절대 안 됨) 쪽으로 조용히 빠지고 있었다 — 리터럴을 하나로 합치고(`ScanView`의 경우 `LocalizedStringKey` 타입 명시까지) 고침. **범위 밖(다음 배치)**: `statusMessage`/`guidanceMessage`/`*ErrorMessage`류(`@Published var x: String`에 동적으로 조립해 대입 후 `Text(변수)`로 표시 — 애초에 `String` 타입이라 String Catalog가 못 잡음, `String(localized:)`로 만드는 리팩터가 따로 필요)와 `LocalizeView.coordinateLine`의 `label` 매개변수(같은 이유)는 한국어로 남음. `\(count)장`처럼 리터럴에 보간이 있는 것들(`"캡처된 사진 (\(rgbURLs.count)장)"` 등 6곳)은 Text/Label에 직접 리터럴로 들어가 있어 로컬라이즈 대상은 맞지만, Xcode 실제 추출기가 만드는 정확한 `%lld`/`%@` 키 형식을 여기서 손으로 재현하면 틀릴 위험이 있어 이번엔 안 넣었다 — **맥에서 한 번 빌드하면 `SWIFT_EMIT_LOC_STRINGS=YES`가 이미 켜져 있어 같은 카탈로그에 자동으로 추가됨, 그때 en 번역만 채우면 됨**
- [x] **iPad 지원 유지로 결정(2026-09-04)** — `TARGETED_DEVICE_FAMILY = "1,2"` 이미 그 상태(변경 불필요). iPad 스크린샷/레이아웃 QA는 여전히 필요(위 체크리스트 항목)
- [ ] 심사 노트: 서버 없이 전체 플로우 데모 가능함을 명시, LiDAR 기기 필요 명시

### B. 실기 검증 (맥 + LiDAR 기기 필요)
- [x] **맥 + 실기기 빌드 성공 확인(2026-09-04)** — 배포 타깃 17.0 하향, `INFOPLIST_FILE=Info.plist` + `GENERATE_INFOPLIST_FILE=YES` 병합 둘 다 실기기 빌드로 통과(CI의 시뮬레이터 빌드보다 더 강한 확인). availability 에러 없음.
- [x] **deface 실기 검증(2026-09-04) — 두 orientation 검출로 바꾼 수정이 실제로 얼굴을 잡음.** 확인됨.
- [x] **사진 갤러리 실기 검증(2026-09-04) — 실사용 중 버그 2개 발견·수정.**
  1. 캡처된 사진이 옆으로 누워 보임 — `rgb/*.jpg`는 ARKit `capturedImage`의
     raw(landscape) 버퍼를 그대로 저장하는 정책(Python 파이프라인이 원본 픽셀
     그대로 읽어야 해서 EXIF 보정 자체를 안 걸어둠)인데, 세로로 들고 스캔하는
     일반적인 사용 방식에서는 그게 그대로 90도 누워 보였다. 디스크의 원본
     바이트는 그대로 두고 화면 표시용으로만(`UIImage.imageOrientation`,
     재인코딩 없음) `.right`로 세워서 보여주도록 수정
     (`PhotoGalleryView.swift`의 `UIImage.forCapturedPhotoDisplay`, `ThumbnailView`/
     `ZoomableImageView` 둘 다 적용). `floorplan.png` 뷰어는 이 보정이 필요 없어
     `ZoomableImageView`에 `displayOrientation` 파라미터(기본값 `.up`)를 추가해
     구분.
  2. 썸네일을 탭하면 첫 번째 탭은 항상 엉뚱한(첫) 사진이 나오고 두 번째/세 번째
     탭부터 제대로 나옴 — `fullScreenCover(isPresented:)` + 별도 `selectedPhotoIndex`
     조합은 SwiftUI가 같은 `PhotoGalleryView` 인스턴스/State 저장소를 재사용해서
     `init`의 `State(initialValue: startIndex)`가 처음 한 번만 적용되는 전형적인
     함정이었다. `fullScreenCover(item:)` + `Identifiable` 아이템(`PhotoGalleryItem`,
     탭마다 새 UUID)으로 바꿔 매번 새 State가 만들어지게 수정 — 이미 쓰고 있던
     `ShareItem`/`fullScreenCover(item:)` 패턴과 동일.
- [ ] 위치 확인(ARWorldMap) — 아직 실기 확인 안 됨(AR 바닥 오버레이 회전 방향
  포함, 위 "E. 바닥 평면 & 경로 오버레이" 절 참고)
- [ ] 발열/프레임 드롭: 긴 스캔(5분+)에서 `thermalState` 관찰(방금 넣은 캡처 루프 오프로딩 + 발열 안내가 실제로 도움이 되는지)

### C. 엔지니어링 품질
- [x] **스캔 포맷 회귀 게이트, XCTest 부분** — `manifest.json`/`poses.jsonl`을 만드는 로직을 순수 함수로 뽑아낸 `ScanRecordBuilder.swift`(ARFrame 의존 제거, `ScanSessionManager`가 그대로 씀)를 만들고, `vpsTests/ScanFormatConformanceTests.swift`가 `vps-system/scan-format/*.schema.json`(정본)을 직접 읽어 그 출력과 대조(필수 키·타입, `tracking_state` enum까지). 대조기는 `MiniSchemaValidator.swift`(이 두 스키마에 필요한 만큼만 지원하는 좁은 서브셋)
  - [ ] CI 부분(미배선): 이 테스트가 만드는 fixture 스캔 폴더에 `conformance_check.py`를 추가로 돌려 Python 소비자 쪽에서도 이중 확인 — CI 구축 시 같이
- [x] **첫 XCTest들 — 실기(시뮬레이터) 실행 확인 완료(2026-09-04)** — 타깃 이름은 `vpsTests`가 아니라 `ScanMeshTests`로 만들어짐(이름 충돌 회피, 기능상 무관). `RegistrationTransformTests` 7개 + `ScanFormatConformanceTests` 3개, **10개 전부 통과**(실패 0) — `#filePath` 기준 상대경로로 `vps-system/scan-format/*.schema.json`을 찾는 부분(가장 우려했던 지점)도 실제로 동작함 확인. 실기기에서는 별개 문제(CoreDeviceError 1001 "Root install style" — Xcode 26.6의 SDK가 26.5로 표시되는 버전 불일치로 추정, 기기 자체 문제 아님)로 못 돌렸지만 시뮬레이터로 로직 검증은 끝남
- [x] **CI 테스트 게이트 승격 완료 + 실제로 그린 확인(2026-09-04)** — 사용자가 맥에서 만든 `ScanMeshTests` 타깃(pbxproj 변경)을 푸시, `ios.yml`의 `xcodebuild test`에서 `continue-on-error` 제거 → 정식 필수 게이트. 승격 직후 실제 CI에서 연달아 2개의 진짜 버그를 더 잡음:
  1. 시뮬레이터 destination을 `name=iPhone 16`으로 고정해뒀더니 러너 이미지가 바뀌며 그 모델이 사라져 "Unable to find a device matching..."로 실패 → 이름을 고정하지 않고 `xcrun simctl list devices available -j`를 `jq`로 파싱해 그 시점에 실제로 있는 iPhone 시뮬레이터의 UDID를 매번 동적으로 골라 쓰도록 변경(`Pick an available iPhone simulator` 스텝).
  2. 단순 `head -n1`으로 고른 시뮬레이터가 iOS 26.4.1이었는데 테스트 타깃의 `IPHONEOS_DEPLOYMENT_TARGET`이 (Xcode의 새 타깃 마법사가 앱의 17.0을 상속하지 않고 자기 기본값인) 26.5로 남아있어서 "Cannot test target ... doesn't match ... deployment target"로 실패 → 두 타깃의 배포 타깃을 17.0으로 맞추고, 픽업 스크립트도 (하이픈 구분 런타임 버전 키를 숫자로 변환해) 항상 최신 iOS 런타임을 고르도록 방어적으로 재작성.
  3. 그 다음 실행은 테스트 10개가 실제로 다 통과했는데도 exit 65로 실패 — 스킴의 `parallelizable="YES"`라 xcodebuild가 시뮬레이터 클론 2개(Clone 1/Clone 2 of iPhone 17)를 동시에 띄웠고 그중 하나가 앱 실행에 실패(`FBSOpenApplicationServiceError`, "test runner hung before establishing connection") — 코드 문제가 아니라 CI 러너의 병렬 시뮬레이터 부팅 리소스 경합. 테스트 10개엔 병렬화 이득이 없어 스킴 `parallelizable`을 `NO`로 내리고 `xcodebuild test`에 `-disable-concurrent-testing`도 추가.
  이후 실행([33845939535](https://github.com/dcrobot-keen/vps-system/actions/runs/33845939535))에서 빌드+테스트 전체 **초록불로 최종 확인**. (사소한 뒷정리 거리: 첫 시도 때 생긴 빈 `vpsTests` 타깃이 pbxproj에 같이 남아있음 — 소스 파일이 없어 CI엔 무해하지만, Xcode에서 그 타깃만 지워도 됨. 급하지 않음.)
- [x] **캡처 루프 오프로딩** — `ScanSessionManager`에 `processingQueue`(백그라운드 직렬 큐) 추가, `saveRGB`/`saveDepth`(얼굴 검출+JPEG 인코딩+raw depth/confidence 쓰기)를 ARSession 델리게이트 콜백 스레드 밖으로 이동. `NSLock` 기반 백프레셔(`tryBeginProcessing`/`endProcessing`) — 이전 프레임 처리가 안 끝났으면 새 프레임은 버림(큐에 안 쌓음). `appendPose`는 가벼운 값만 읽어서 그대로 동기 유지. `ProcessInfo.thermalState`를 `updateGuidance`의 최우선 순위로 추가(`.serious`/`.critical`일 때 안내), 저장 실패 누적 시 3회부터 `guidanceMessage`로 한 번 알림(`recordSaveFailure`)
- [ ] 방향 추적: 가로/세로 모두 허용 중 → 실제 기기 방향을 Vision에 정확히 전달(지금은 두 방향 시도로 땜질) — 남아있는 별개 항목
- [x] **`try?`를 OSLog + 에러 표시로** — `ScanSessionManager`/`FaceRedactor`/`TextureBaker`의 모든 `print()`를 `os.Logger`(subsystem `com.dcrobot.scanmesh`)로 교체. 문자열 보간 값은 기본적으로 `os.Logger`가 private 처리(Console.app에 `<private>`로 보임)하므로 진단에 필요한 것(에러 메시지, 파일 경로, 라벨 등)은 전부 `privacy: .public` 명시(숫자는 기본 public이라 그대로 둠). `writeManifest`/`posesFile.close()`를 do/catch로 바꿔 `exportMesh`/`exportWorldMap`과 같은 패턴(실패 시 `statusMessage`에 접미사)으로 통일. 프레임당 저장 실패는 `saveFailureCount` 누적 + 임계값(3) 도달 시 1회만 안내(매 프레임 알리면 그 자체가 방해). `ImportedFileStore.importFile`도 조용한 실패 → `importErrorMessage` + 알림창으로 변경(사용자가 직접 시킨 동작이라 실패를 알아야 함)
- [ ] 저장 공간 표시/경고, 프로젝트 용량 표시
- [ ] 업로드 background URLSession(고급 모드)
- [ ] 테스트 확장: ZipArchiver, PCD/PLY/GLB 로더, manifest 기록, FaceRedactor(얼굴 샘플 이미지 필요)
- [x] CI 착수 + **실제 GitHub Actions 러너에서 검증 완료**: `.github/workflows/ios.yml` + `vps.xcodeproj/xcshareddata/xcschemes/vps.xcscheme`(원래 커밋 안 돼 있던 스킴을 새로 만듦). 첫 실행은 "Scheme vps is not currently configured for the build action"로 실패 — 스킴 XML의 설명 주석에 `--`(이 세션이 습관적으로 쓰는 구분자)가 들어있어 Xcode의 스킴 파서가 파일 전체를 로드 실패로 처리한 것이 원인이었다(XML 1.0 스펙상 주석 본문에 `--`는 금지). 주석을 지우자 `xcodebuild build`가 실제 Xcode 26.6에서 통과(초록불) — 이 세션 최초로 진짜 컴파일 성공을 확인한 사례. `xcodebuild test`는 `vpsTests` 타깃이 없어 예상대로 "Scheme vps is not currently configured for the test action"로 실패하지만 `continue-on-error`라 전체는 통과 — **타깃 생성 후 이 continue-on-error를 지워서 필수 게이트로 승격할 것**
- [ ] TestFlight 외부 테스터

**실제 CI 검증(2026-09-04):** 위 세 항목(String Catalog, 캡처 루프 오프로딩, OSLog) 커밋 후 GitHub Actions에서 `xcodebuild build` 그대로 통과(초록불, 52초) — `os.Logger` + `privacy: .public`, `NSLock` 백프레셔, `Localizable.xcstrings`, `LocalizedStringKey` 타입 명시까지 전부 실제 Xcode 26.6에서 컴파일 확인됨.

### D. 출시 후
- [ ] iCloud/Files 동기화, 프로젝트 이름 변경/정리 UI
- [ ] 고급 모드 확장(정합 파일 자동 수신 등)

### E. 바닥 평면 & 경로 오버레이 (2026-09-04 신규 요청)

두 가지를 요청받음: ① 스캔 후 바닥만 2D 이미지로 export, ② 그 위에 VPS 길찾기 경로 +
스캔 경로를 오버레이. 검토 결과 scan-to-map-studio에 이미 바닥 평면 생성
(`slice_map.py`/`rasterize.py`/`vectorize.py`)과 pathfinder에 경로 계산 API
(`/api/path/nodelink`, `/api/path/obstacle`)가 서버 쪽에 있지만, 둘 다 vectorize된
그래프(GeoJSON)가 있어야 하고 그건 스튜디오 파이프라인 산출물이라 앱만으로는 못 만듦.
그래서 스코프를 둘로 나누기로 사용자와 합의:

- **1단계(이번, 완료)**: 온디바이스 즉석 버전. `FloorPlanRenderer.swift`(신규) —
  스캔 종료 시점의 LiDAR mesh(`ARMeshAnchor`, `meshWithClassification` 지원 기기는
  실제 바닥/벽 face classification 사용, 미지원 기기는 최저 높이 대역 휴리스틱으로
  대체)에서 바닥을 위에서 내려다본 2D 이미지를 만들어 `scan_<name>/floorplan.png`로
  저장(`ScanSessionManager.exportFloorPlan`, `scan.usdz`와 같은 시점에 같이 생성).
  색 관례는 scan-to-map-studio/studio/rasterize.py(OccupancyGrid, ROS map_server
  계열: free=흰색, occupied=검정, unknown=회색, resolution 0.05m/px)와 일부러
  맞췄고, 경로/마커 색은 scan-to-map-studio/studio/viewer_html.py의 웹 뷰어와 같은
  값(#3ba0ff/#ff3b3b)을 재사용 — 다른 저장소의 뷰어와 나란히 놓아도 같은 스캔으로
  알아볼 수 있게. 이번 세션에서 실제로 이동한 카메라 경로(`poses.jsonl`과 같은
  소스, `ScanSessionManager.scanPathXZ`)를 파란 선 + 시작(초록)/끝(빨강) 마커로
  겹친다. `ProjectDetailView`에 "바닥 평면 보기" 버튼(조건: `project.hasFloorPlan`)
  → 핀치줌 뷰어(`PhotoGalleryView`의 `ZoomableImageView` 재사용) + 공유 버튼
  (기존 `ShareSheet` 재사용). `scan.usdz`와 달리 다운스트림이 소비하는 스캔 포맷
  계약의 일부가 아니라 앱 자체 편의 산출물이라 스캔 포맷 회귀 게이트 대상은 아님.
  - 순수 래스터화 로직(`FloorPlanRenderer.rasterize`, world-space 삼각형 + 경로
    좌표만 받음, `ARMeshAnchor` 의존 없음 — `ScanRecordBuilder`를 `ARFrame`에서
    분리한 것과 같은 이유/패턴)을 `ScanMeshTests/FloorPlanRendererTests.swift`로
    검증(바닥=흰색, 벽=검정, 배경=회색, 경로=파랑, 시작/끝 마커 색, 초대형 스캔의
    해상도 자동 하향, 빈 입력 시 nil). `render(meshAnchors:scanPathXZ:)` 자체는
    `ARMeshAnchor`를 테스트에서 못 만들어 미검증 — 실기기/시뮬레이터 실행으로
    확인 필요(아래 실기 검증 항목 참고).
  - [x] **실기 검증 완료(2026-09-04)** — 실제 스캔에서 `floorplan.png`가 "제법
    그럴듯하게" 나옴을 확인(사용자 실기기 확인).
- **1.5단계(이번, 추가 요청 반영)**: 위 확인 직후 두 가지를 더 요청받음 —
  ① "텍스처 결과 보기"의 실제 사진 바닥 색이 `floorplan.png`에도 입혀지길 원함,
  ② "위치 확인(서버 없이)" 화면에서 반투명 바닥 평면 + 실시간 위치를 AR 카메라
  화면 위에 직접 겹쳐서 보고 싶어함(지금까지는 화면 상단의 별도 2D 개략도(Canvas)
  뿐이었음). 둘 다 구현:
  - **바닥 실사 색칠**: `TextureBaker.bake`에 `onBakedFaceColors` 콜백을 추가해
    GLB export 직전 welded mesh의 face별 최종 색(홀 채우기까지 끝난 뒤)을 그대로
    넘겨받는다 — 별도 GPU 패스 없이 이미 하던 베이킹 결과를 재사용. 이 mesh는
    `scan.usdz`를 재로드한 것이라 classification이 없으므로, `floorplan.json`에
    저장해둔 바닥 높이 대역(`floor_height_min/max`, ±3cm 허용)으로 "이 face가
    바닥이었을 가능성이 높다"를 다시 판정한다(`FloorPlanRenderer.floorPatches`).
    그 패치들을 기존 `floorplan.png`(분류 기반, 바닥=흰색) 위에 덧칠하고 경로/마커를
    다시 그려 얹은 뒤(`FloorPlanRenderer.recolorFloor`) 같은 파일에 덮어쓴다
    (`ProjectDetailView.recolorFloorPlan`, "텍스처 생성"/"텍스처 다시 생성" 버튼을
    누를 때마다 같이 갱신됨). `floorplan.png`/`floorplan.json`이 없거나 바닥 높이
    정보가 없으면(구버전 스캔, classification 미지원 기기에서 바닥이 하나도 안
    잡힌 경우) 조용히 건너뜀 — 부가 기능이라 텍스처 베이킹 자체에 영향 없음.
  - **위치확인 AR 오버레이**: `LocalizeSessionManager`가 `floorplan.png` +
    `floorplan.json`(`FloorPlanRenderer.PersistedMeta`)으로 AR 평면 배치 정보
    (`FloorPlanOverlay`: 중심 world (x,z), 바닥 높이(y), 실제 크기(m))를 한 번
    계산해두고, 매 프레임 raw ARKit world 위치(GroundPose 변환 전 — floorplan.png와
    같은 좌표계라 추가 변환 불필요)를 `worldPosition`으로 게시한다. `LocalizeView`의
    `ARLocalizePreview`가 `SCNPlane`(반투명, opacity 0.6, `lightingModel = .constant`로
    AR 조명 추정에 어두워지지 않게)을 그 위치/크기에 눕혀 놓고, 작은 구슬 마커를
    `worldPosition`에 계속 옮겨 "지금 여기" 표시. 기존 상단 2D 개략도는 그대로 둠
    (AR 오버레이가 실패해도 위치확인 자체는 동작해야 하므로 병행).
    - [ ] **실기 검증 안 됨** — 이 환경(Windows, Xcode 없음)에서 SCNPlane 회전
      방향(-90도, X축)과 텍스처 UV가 실제로 "화면에 보이는 대로" 바닥에 정확히
      겹치는지 확인할 방법이 없었다(코드 상 `ARLocalizePreview` 주석에 명시). 만약
      이미지가 뒤집히거나 회전돼 보이면 회전 부호/`contentsTransform` 조정 필요.
    - [x] 순수 함수(`FloorPlanRenderer.floorPatches`/`recolorFloor`)는
      `FloorPlanRendererTests`로 검증, 실제 CI에서 통과 확인 예정.
- **2단계(미착수, 별도 작업)**: VPS 길찾기 경로(pathfinder route) 오버레이 —
  scan-to-map-studio에 "이 스캔의 vectorize된 그래프 내려주기" API가 먼저 필요하고,
  도착점 선택 UI, 고급 모드 서버 체인(업로드→스튜디오 처리 대기→pathfinder 호출)까지
  새로 설계해야 함 — vps-system/scan-to-map-studio/pathfinder 세 저장소에 걸친 별도
  작업으로 남겨둠.

## 결정 (2026-09-04) — 4개 전부 완료
1. ~~제품명(영/한) + 번들 ID~~ → **ScanMesh / 스캔메시**, `com.dcrobot.scanmesh`
2. ~~개발자 계정 주체~~ → **개인**
3. ~~1.0에 iPad 포함 여부~~ → **포함**
4. ~~개인정보 처리방침 호스팅 위치~~ → **GitHub Pages**(`docs/privacy/`, 위 참고)

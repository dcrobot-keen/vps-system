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
- [ ] 로컬라이제이션: 개발 언어 ko로 설정함 → `Localizable.xcstrings` 만들고 영어 번역
- [x] **iPad 지원 유지로 결정(2026-09-04)** — `TARGETED_DEVICE_FAMILY = "1,2"` 이미 그 상태(변경 불필요). iPad 스크린샷/레이아웃 QA는 여전히 필요(위 체크리스트 항목)
- [ ] 심사 노트: 서버 없이 전체 플로우 데모 가능함을 명시, LiDAR 기기 필요 명시

### B. 실기 검증 (맥 + LiDAR 기기 필요)
- [ ] 이번에 넣은 기능: deface(orientation 수정 후 재검증, `[deface]` 로그 확인), 위치 확인(ARWorldMap), 사진 갤러리
- [ ] 배포 타깃 17.0으로 내린 뒤 빌드 통과 확인 (availability 에러 나면 그 API만 처리)
- [ ] `INFOPLIST_FILE=Info.plist` + `GENERATE_INFOPLIST_FILE=YES` 병합이 정상인지(키 중복 에러 없음)
- [ ] 발열/프레임 드롭: 긴 스캔(5분+)에서 `thermalState` 관찰

### C. 엔지니어링 품질
- [x] **스캔 포맷 회귀 게이트, XCTest 부분** — `manifest.json`/`poses.jsonl`을 만드는 로직을 순수 함수로 뽑아낸 `ScanRecordBuilder.swift`(ARFrame 의존 제거, `ScanSessionManager`가 그대로 씀)를 만들고, `vpsTests/ScanFormatConformanceTests.swift`가 `vps-system/scan-format/*.schema.json`(정본)을 직접 읽어 그 출력과 대조(필수 키·타입, `tracking_state` enum까지). 대조기는 `MiniSchemaValidator.swift`(이 두 스키마에 필요한 만큼만 지원하는 좁은 서브셋)
  - [ ] CI 부분(미배선): 이 테스트가 만드는 fixture 스캔 폴더에 `conformance_check.py`를 추가로 돌려 Python 소비자 쪽에서도 이중 확인 — CI 구축 시 같이
- [x] 첫 XCTest들 (`vpsTests/RegistrationTransformTests.swift`, `MiniSchemaValidator.swift`, `ScanFormatConformanceTests.swift`) — **Xcode에서 Unit Testing Bundle 타깃 `vpsTests` 추가 필요**(폴더 지정만 하면 셋 다 자동 포함)
- [ ] 캡처 루프 오프로딩: JPEG 인코딩 + 얼굴 검출을 ARSession 델리게이트 스레드 밖 큐로, 백프레셔(프레임 드롭) + `ProcessInfo.thermalState`
- [ ] 방향 추적: 가로/세로 모두 허용 중 → 실제 기기 방향을 Vision에 정확히 전달(지금은 두 방향 시도로 땜질)
- [ ] `try?`로 삼키는 에러를 사용자 표시 + OSLog로
- [ ] 저장 공간 표시/경고, 프로젝트 용량 표시
- [ ] 업로드 background URLSession(고급 모드)
- [ ] 테스트 확장: ZipArchiver, PCD/PLY/GLB 로더, manifest 기록, FaceRedactor(얼굴 샘플 이미지 필요)
- [x] CI 착수 + **실제 GitHub Actions 러너에서 검증 완료**: `.github/workflows/ios.yml` + `vps.xcodeproj/xcshareddata/xcschemes/vps.xcscheme`(원래 커밋 안 돼 있던 스킴을 새로 만듦). 첫 실행은 "Scheme vps is not currently configured for the build action"로 실패 — 스킴 XML의 설명 주석에 `--`(이 세션이 습관적으로 쓰는 구분자)가 들어있어 Xcode의 스킴 파서가 파일 전체를 로드 실패로 처리한 것이 원인이었다(XML 1.0 스펙상 주석 본문에 `--`는 금지). 주석을 지우자 `xcodebuild build`가 실제 Xcode 26.6에서 통과(초록불) — 이 세션 최초로 진짜 컴파일 성공을 확인한 사례. `xcodebuild test`는 `vpsTests` 타깃이 없어 예상대로 "Scheme vps is not currently configured for the test action"로 실패하지만 `continue-on-error`라 전체는 통과 — **타깃 생성 후 이 continue-on-error를 지워서 필수 게이트로 승격할 것**
- [ ] TestFlight 외부 테스터

### D. 출시 후
- [ ] iCloud/Files 동기화, 프로젝트 이름 변경/정리 UI
- [ ] 고급 모드 확장(정합 파일 자동 수신 등)

## 결정 (2026-09-04) — 4개 전부 완료
1. ~~제품명(영/한) + 번들 ID~~ → **ScanMesh / 스캔메시**, `com.dcrobot.scanmesh`
2. ~~개발자 계정 주체~~ → **개인**
3. ~~1.0에 iPad 포함 여부~~ → **포함**
4. ~~개인정보 처리방침 호스팅 위치~~ → **GitHub Pages**(`docs/privacy/`, 위 참고)

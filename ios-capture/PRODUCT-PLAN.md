# ios-capture → App Store 제품화 계획

> 2026-09-04 시작. 방향 **C**: 기본은 서버 없이 완결되는 **범용 LiDAR 룸 스캐너**(1.0 스코프),
> 로봇 스택(VPS 서버) 연동은 설정의 **"고급 모드"** 뒤에 숨긴 선택 기능.
> 이유: App Store 심사관은 우리 서버가 없다. 외부 서비스 없이는 쓸모없는 앱은 리젝된다.

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
- [ ] **제품명/브랜드/번들 ID** — 현재 `com.dcrobot.keen.vps`, 타이틀 "dc-vps 스캔". **사용자 결정 필요**
- [ ] 개발자 계정: 개인(팀 `GW4C35M572`) vs 회사 Organization — **사용자 결정 필요**
- [ ] 앱 아이콘, 런치 스크린(현재 자동 생성), 스크린샷(iPhone 6.9"/6.5", iPad 13")
- [ ] 개인정보 처리방침 URL + App Privacy 라벨(사진 저장, 고급 모드 시 서버 전송)
- [ ] 로컬라이제이션: 개발 언어 ko로 설정함 → `Localizable.xcstrings` 만들고 영어 번역
- [ ] iPad 지원 유지 여부(1.0은 iPhone만으로 줄이는 것도 방법 — `TARGETED_DEVICE_FAMILY`)
- [ ] 심사 노트: 서버 없이 전체 플로우 데모 가능함을 명시, LiDAR 기기 필요 명시

### B. 실기 검증 (맥 + LiDAR 기기 필요)
- [ ] 이번에 넣은 기능: deface(orientation 수정 후 재검증, `[deface]` 로그 확인), 위치 확인(ARWorldMap), 사진 갤러리
- [ ] 배포 타깃 17.0으로 내린 뒤 빌드 통과 확인 (availability 에러 나면 그 API만 처리)
- [ ] `INFOPLIST_FILE=Info.plist` + `GENERATE_INFOPLIST_FILE=YES` 병합이 정상인지(키 중복 에러 없음)
- [ ] 발열/프레임 드롭: 긴 스캔(5분+)에서 `thermalState` 관찰

### C. 엔지니어링 품질
- [x] 첫 XCTest (`vpsTests/RegistrationTransformTests.swift`) — **Xcode에서 Unit Testing Bundle 타깃 `vpsTests` 추가 필요**(폴더 지정만 하면 자동 포함)
- [ ] 캡처 루프 오프로딩: JPEG 인코딩 + 얼굴 검출을 ARSession 델리게이트 스레드 밖 큐로, 백프레셔(프레임 드롭) + `ProcessInfo.thermalState`
- [ ] 방향 추적: 가로/세로 모두 허용 중 → 실제 기기 방향을 Vision에 정확히 전달(지금은 두 방향 시도로 땜질)
- [ ] `try?`로 삼키는 에러를 사용자 표시 + OSLog로
- [ ] 저장 공간 표시/경고, 프로젝트 용량 표시
- [ ] 업로드 background URLSession(고급 모드)
- [ ] 테스트 확장: ZipArchiver, PCD/PLY/GLB 로더, manifest 기록, FaceRedactor(얼굴 샘플 이미지 필요)
- [ ] CI: Xcode Cloud 또는 GitHub Actions(macOS) — 빌드 + 테스트
- [ ] TestFlight 외부 테스터

### D. 출시 후
- [ ] iCloud/Files 동기화, 프로젝트 이름 변경/정리 UI
- [ ] 고급 모드 확장(정합 파일 자동 수신 등)

## 결정 필요 (사용자)
1. 제품명(영/한) + 번들 ID
2. 개발자 계정 주체(개인/회사)
3. 1.0에 iPad 포함 여부
4. 개인정보 처리방침 호스팅 위치(회사 사이트? GitHub Pages?)

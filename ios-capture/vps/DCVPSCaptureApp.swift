import SwiftUI

@main
struct DCVPSCaptureApp: App {
    // VPS 업로드가 백그라운드 URLSession을 쓰는데, 그 완료 이벤트를 받으려면
    // UIApplicationDelegate가 있어야 한다(SwiftUI App 라이프사이클엔 없음) --
    // AppDelegate.swift 참고.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            if DeviceSupport.isScanningSupported {
                // 화면이 프로젝트 목록 하나뿐이라 탭 바를 두지 않는다 -- "가져온 파일"
                // (외부 3D 파일 뷰어, 스캔 흐름과 무관)은 목록의 ⋯ 메뉴에서 시트로 연다
                // (2026-09-04 IA 검토).
                ProjectGroupListView()
            } else {
                // LiDAR 없는 기기 -- 스캔이 앱의 전부라 뷰어만 남기는 것보다 이유를
                // 정확히 알려주는 쪽이 낫다(App Store 심사 요건이기도 함).
                UnsupportedDeviceView()
            }
        }
    }
}

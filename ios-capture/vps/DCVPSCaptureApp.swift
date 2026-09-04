import SwiftUI

@main
struct DCVPSCaptureApp: App {
    var body: some Scene {
        WindowGroup {
            if DeviceSupport.isScanningSupported {
                TabView {
                    ProjectListView()
                        .tabItem { Label("프로젝트", systemImage: "camera.viewfinder") }
                    ImportedFilesView()
                        .tabItem { Label("가져온 파일", systemImage: "square.and.arrow.down") }
                }
            } else {
                // LiDAR 없는 기기 -- 스캔이 앱의 전부라 뷰어만 남기는 것보다 이유를
                // 정확히 알려주는 쪽이 낫다(App Store 심사 요건이기도 함).
                UnsupportedDeviceView()
            }
        }
    }
}

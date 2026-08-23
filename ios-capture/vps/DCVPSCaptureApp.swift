import SwiftUI

@main
struct DCVPSCaptureApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                ProjectListView()
                    .tabItem { Label("프로젝트", systemImage: "camera.viewfinder") }
                ImportedFilesView()
                    .tabItem { Label("가져온 파일", systemImage: "square.and.arrow.down") }
            }
        }
    }
}

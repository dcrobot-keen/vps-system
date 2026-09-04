import SwiftUI

/// `.sheet(item:)`으로 공유 시트를 띄우기 위한 최소 wrapper. `ProjectGroupDetailView`
/// (프로젝트 zip 내보내기)와 `ProjectDetailView`(바닥 평면 공유)가 같이 쓴다.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

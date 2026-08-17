import ARKit
import SwiftUI

struct ContentView: View {
    @StateObject private var manager = ScanSessionManager()
    @State private var sessionName = ContentView.defaultSessionName()
    @State private var shareItem: ShareItem?
    @State private var isExporting = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ARPreview(session: manager.session)
                .ignoresSafeArea()
                .onAppear { manager.startPreview() }

            VStack(spacing: 12) {
                Text(manager.statusMessage)
                    .foregroundStyle(.white)
                Text("프레임: \(manager.frameCount)")
                    .foregroundStyle(.white)
                    .monospacedDigit()

                if !manager.isRunning {
                    TextField("세션 이름", text: $sessionName)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 40)
                }

                HStack(spacing: 16) {
                    Button(manager.isRunning ? "정지" : "시작") {
                        if manager.isRunning {
                            manager.stopSession()
                        } else {
                            manager.startSession(name: sessionName)
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("내보내기") {
                        isExporting = true
                        manager.exportZip { url in
                            isExporting = false
                            if let url {
                                shareItem = ShareItem(url: url)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(manager.isRunning || manager.lastOutputDir == nil || isExporting)
                }
            }
            .padding()
            .background(.black.opacity(0.55))
            .cornerRadius(12)
            .padding()
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: [item.url])
        }
    }

    static func defaultSessionName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ARPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = true
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

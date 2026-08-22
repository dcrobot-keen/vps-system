import ARKit
import SwiftUI

/// 프로젝트 하나를 실제로 스캔하는 화면. "스캔 시작"으로 캡처를 시작하고 "정지 & 저장"을
/// 누르면 `scan_<projectName>/`에 저장이 끝난다 (VPS용 rgb/depth/poses + 있으면
/// scan.usdz). "완료"를 눌러야 목록 화면으로 돌아간다 — 그래야 결과(프레임 수, mesh
/// export 성공 여부)를 확인할 시간을 준다.
struct ScanView: View {
    let projectName: String
    var onSaved: () -> Void = {}

    @StateObject private var manager = ScanSessionManager()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottom) {
            ARPreview(session: manager.session, delegate: manager)
                .ignoresSafeArea()
                .onAppear { manager.startPreview() }

            VStack(spacing: 12) {
                Text(manager.statusMessage)
                    .foregroundStyle(.white)
                Text("프레임: \(manager.frameCount)")
                    .foregroundStyle(.white)
                    .monospacedDigit()

                if manager.isRunning {
                    Button("정지 & 저장") {
                        manager.stopSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else if manager.lastOutputDir != nil {
                    Button("완료") {
                        onSaved()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("스캔 시작") {
                        manager.startSession(name: projectName)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .background(.black.opacity(0.55))
            .cornerRadius(12)
            .padding()
        }
        .navigationTitle(projectName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(manager.isRunning)
    }
}

/// 실시간 mesh 프리뷰(cyan 와이어프레임)를 겹쳐 그리기 위해 ARSCNViewDelegate를
/// ScanSessionManager에 연결한다 (ScanSessionManager.swift 하단 extension 참고).
struct ARPreview: UIViewRepresentable {
    let session: ARSession
    let delegate: ARSCNViewDelegate

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.delegate = delegate
        view.automaticallyUpdatesLighting = true
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

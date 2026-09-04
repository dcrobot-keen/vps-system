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

            if let guidance = manager.guidanceMessage {
                VStack {
                    Text(guidance)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.orange.opacity(0.85))
                        .clipShape(Capsule())
                        .padding(.top, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: manager.guidanceMessage)
            }

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
                    Text(Self.preScanTips)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
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

    /// VPS DB 품질에 도움 되는 것으로 확인된 스캔 습관 — 실시간으로 감지하기 어려운
    /// 것들(질감 있는 표면 위주, 여러 각도에서 훑기)만 시작 전에 짧게 안내한다.
    /// 감지 가능한 것들(트래킹, 거리, 구역 길이)은 스캔 중 `guidanceMessage`로 대신한다.
    // 한 리터럴로 합치고 타입을 LocalizedStringKey로 명시했다 -- 원래는 두 문자열을
    // +로 이어붙여서 String으로 타입이 굳었었는데(ServerSettingsView에서도 같은
    // 문제를 발견해 고침), String이면 애초에 static let 자체가 지역화 대상이 아니라
    // Text(Self.preScanTips)가 Text(_:String)(그대로 표시) 쪽으로 빠진다.
    private static let preScanTips: LocalizedStringKey =
        "천천히, 흔들지 않게 움직여주세요. 흰 벽보다는 가구·표지판처럼 특징이 뚜렷한 곳 위주로, 같은 곳도 2~3개 각도에서 훑어주면 좋아요."
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

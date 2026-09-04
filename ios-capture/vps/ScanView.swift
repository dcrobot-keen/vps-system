import ARKit
import SwiftUI

/// 프로젝트 하나를 실제로 스캔하는 화면. "스캔 시작"으로 캡처를 시작하고 "정지 & 저장"을
/// 누르면 `scan_<projectName>/`에 저장이 끝난다 (VPS용 rgb/depth/poses + 있으면
/// scan.usdz). "완료"를 눌러야 목록 화면으로 돌아간다 — 그래야 결과(프레임 수, mesh
/// export 성공 여부)를 확인할 시간을 준다.
///
/// 프로젝트에 지도(worldmap)가 있는 이전 스캔이 있으면 시작 전에 "이전 스캔 위치에
/// 맞추기"를 제안한다 -- 켜고 시작하면 이전 지도로 재국지화한 뒤 그 pose를 이 스캔의
/// 정렬 변환으로 삼고 캡처한다(ScanSessionManager.startAnchoring). 겹치는 게 없는 다른
/// 방끼리는 나중에 기하로 맞출 수 없으니, 방을 찍을 때 문 밖을 조금 같이 찍어두고
/// 다음 방은 그 문 근처에서 시작하는 게 요령이다.
struct ScanView: View {
    let projectName: String
    /// 프로젝트 안에 지도가 있는 이전 스캔들(최근 것부터). 비어 있으면 맞추기 제안 없음.
    var anchorCandidates: [ScanSessionManager.AnchorCandidate] = []
    /// 저장 후 "완료"에서 호출. 맞추기에 성공했으면 "이 스캔 좌표계 -> 프로젝트 기준"
    /// 변환, 아니면 nil(정렬 화면에서 손으로 맞춘다).
    var onSaved: (ScanAlignment?) -> Void = { _ in }

    @StateObject private var manager = ScanSessionManager()
    @Environment(\.dismiss) private var dismiss
    @State private var availableStorageBytes: Int64?
    @State private var useAnchoring = true

    private var isRelocalizing: Bool {
        if case .relocalizing? = manager.anchorPhase { return true }
        return false
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ARPreview(session: manager.session, delegate: manager)
                .ignoresSafeArea()
                .onAppear {
                    manager.startPreview()
                    availableStorageBytes = DeviceStorage.availableBytes()
                }

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
                if case .anchored(let label)? = manager.anchorPhase {
                    Label("\(label) 위치에 맞춰짐", systemImage: "link")
                        .font(.caption)
                        .foregroundStyle(.cyan)
                }

                if manager.isRunning {
                    Button("정지 & 저장") {
                        manager.stopSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else if manager.lastOutputDir != nil {
                    Button("완료") {
                        onSaved(manager.anchoredAlignment)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                } else if let phase = manager.anchorPhase {
                    anchoringPanel(phase)
                } else {
                    preScanPanel
                }
            }
            .padding()
            .background(.black.opacity(0.55))
            .cornerRadius(12)
            .padding()
        }
        .navigationTitle(projectName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(manager.isRunning || isRelocalizing)
    }

    /// 시작 전: 스캔 요령, 저장 공간, (있으면) 이전 스캔 위치에 맞추기 토글, 시작 버튼.
    private var preScanPanel: some View {
        VStack(spacing: 12) {
            Text(Self.preScanTips)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if let availableStorageBytes {
                // 보간이 있는 리터럴이라 String Catalog 추출 대상이지만, 정확한
                // %lld 키 형식을 손으로 재현하는 대신 맥에서 다음 빌드할 때
                // SWIFT_EMIT_LOC_STRINGS가 자동으로 채워주게 둔다(이 세션의
                // 기존 방침, Localizable.xcstrings 주석 참고).
                Text("저장 공간: \(DeviceStorage.formatted(availableStorageBytes)) 사용 가능")
                    .font(.caption2)
                    .foregroundStyle(
                        availableStorageBytes < DeviceStorage.lowStorageWarningBytes
                            ? .orange : .white.opacity(0.6)
                    )
                if availableStorageBytes < DeviceStorage.lowStorageWarningBytes {
                    Text("저장 공간이 부족할 수 있어요")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            if !anchorCandidates.isEmpty {
                Toggle("이전 스캔 위치에 맞추기", isOn: $useAnchoring)
                    .tint(.cyan)
                    .foregroundStyle(.white)
                if useAnchoring {
                    Text("지금 서 있는 곳(문 근처)이 이전 스캔에 찍혀 있어야 해요. 위치가 잡히면 자동으로 캡처가 시작됩니다.")
                        .font(.caption)
                        .foregroundStyle(.cyan)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button("스캔 시작") {
                if useAnchoring, !anchorCandidates.isEmpty {
                    manager.startAnchoring(name: projectName, candidates: anchorCandidates)
                } else {
                    manager.startSession(name: projectName)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// 맞추는 중/실패: 안내 + "맞추지 않고 시작"/"취소". 성공(.anchored)하면 캡처가 바로
    /// 시작돼 이 패널은 안 보인다.
    @ViewBuilder
    private func anchoringPanel(_ phase: ScanSessionManager.AnchorPhase) -> some View {
        switch phase {
        case .relocalizing(let label):
            Text("위치 맞추는 중 — \(label)을(를) 찍었던 곳(문 근처)을 천천히 비춰주세요")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.cyan)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ProgressView()
                .tint(.white)
            anchoringButtons
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
            anchoringButtons
        case .anchored:
            EmptyView()
        }
    }

    private var anchoringButtons: some View {
        HStack(spacing: 12) {
            Button("취소") { manager.cancelAnchoring() }
                .buttonStyle(.bordered)
                .tint(.white)
            Button("맞추지 않고 시작") { manager.skipAnchoring() }
                .buttonStyle(.borderedProminent)
        }
    }

    /// VPS DB 품질에 도움 되는 것으로 확인된 스캔 습관 — 실시간으로 감지하기 어려운
    /// 것들(질감 있는 표면 위주, 여러 각도에서 훑기)만 시작 전에 짧게 안내한다.
    /// 감지 가능한 것들(트래킹, 거리, 구역 길이)은 스캔 중 `guidanceMessage`로 대신한다.
    /// 문 밖을 같이 찍으라는 건 다음 방을 "이전 스캔 위치에 맞추기"로 이어 붙이기 위해서.
    // 한 리터럴로 합치고 타입을 LocalizedStringKey로 명시했다 -- 원래는 두 문자열을
    // +로 이어붙여서 String으로 타입이 굳었었는데(ServerSettingsView에서도 같은
    // 문제를 발견해 고침), String이면 애초에 static let 자체가 지역화 대상이 아니라
    // Text(Self.preScanTips)가 Text(_:String)(그대로 표시) 쪽으로 빠진다.
    private static let preScanTips: LocalizedStringKey =
        "천천히, 흔들지 않게 움직여주세요. 흰 벽보다는 가구·표지판처럼 특징이 뚜렷한 곳 위주로, 같은 곳도 2~3개 각도에서 훑어주면 좋아요. 다음 방과 이어 붙이려면 문 밖 복도도 1~2m 같이 훑어두세요."
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

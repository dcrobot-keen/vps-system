import ARKit
import SwiftUI
import UniformTypeIdentifiers

/// "서버 없이 지금 어디쯤인지 확인"하는 화면. 저장된 ARWorldMap으로 재국지화를
/// 시도하고, 성공하면 상단 2D 뷰(바닥 평면 배경 + 궤적 + 내 위치·방향)에 보여준다.
/// 프로젝트 단위로 열면(`candidates` 여러 개) 스캔 지도를 하나씩 시도하고, 잡힌 스캔의
/// 정렬 변환으로 기준 좌표계에 표시한다(LocalizeSessionManager 참고).
///
/// registration_transform.json이 기준 스캔 폴더에 있으면(직접 넣거나 "정합 파일
/// 가져오기"로) map(로봇 SLAM) 좌표로도 함께 보여준다 -- 이 가져오기는 로봇
/// 파이프라인 산출물이라 고급 모드가 켜져 있을 때만 노출된다.
struct LocalizeView: View {
    let candidates: [LocalizeCandidate]
    let startIndex: Int

    @StateObject private var manager = LocalizeSessionManager()
    @Environment(\.dismiss) private var dismiss
    @State private var isImportingCalibration = false
    @State private var importErrorMessage: String?

    @AppStorage(ServerSettingsStore.advancedModeKey) private var isAdvancedModeEnabled = false

    /// 스캔 하나(ProjectDetailView에서).
    init(project: ScanProject) {
        candidates = [LocalizeCandidate(id: project.id, label: project.id, folderURL: project.url, alignment: .identity)]
        startIndex = 0
    }

    /// 프로젝트(ProjectGroupDetailView에서) -- 정렬 변환 포함 후보들.
    init(candidates: [LocalizeCandidate], startIndex: Int = 0) {
        self.candidates = candidates
        self.startIndex = startIndex
    }

    private var isProjectMode: Bool { candidates.count > 1 }

    var body: some View {
        ZStack(alignment: .bottom) {
            ARLocalizePreview(session: manager.session)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topDownView
                    .frame(height: 260)
                    .background(.black.opacity(0.55))

                infoPanel
                    .padding()
                    .background(.black.opacity(0.55))
            }
        }
        .navigationTitle("위치 확인")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isAdvancedModeEnabled {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isImportingCalibration = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
        }
        .fileImporter(isPresented: $isImportingCalibration, allowedContentTypes: [.json]) { result in
            handleCalibrationImport(result)
        }
        .onAppear { manager.start(candidates: candidates, startIndex: startIndex, autoCycle: true) }
        .onDisappear { manager.stop() }
    }

    // MARK: - 상단: top-down 2D 위치 표시 (world x/z, 화면 위 = +z -- FloorPlanLayer 참고)

    private var topDownView: some View {
        Canvas { context, size in
            var bounds = TopDownBounds()
            for layer in manager.layers { bounds.include(layer, alignment: manager.alignment(forLayer: layer)) }
            for trajectory in manager.trajectoriesXZ { for p in trajectory { bounds.include(x: p.x, z: p.y) } }
            if let c = manager.currentXZ { bounds.include(x: c.x, z: c.y) }
            let mapping = TopDownMapping(bounds: bounds.padded(fraction: 0.05, minimum: 1), size: size, fill: 0.95)

            for layer in manager.layers {
                let isActive = layer.id == manager.candidates[safe: manager.activeIndex]?.id
                context.drawFloorPlanLayer(layer, alignment: manager.alignment(forLayer: layer), mapping: mapping, opacity: 0.7)
                if isProjectMode, isActive {
                    context.strokeFloorPlanOutline(
                        layer, alignment: manager.alignment(forLayer: layer), mapping: mapping,
                        color: .cyan.opacity(0.8), lineWidth: 1.5, dash: [5, 4]
                    )
                }
            }

            var trailPath = Path()
            for trajectory in manager.trajectoriesXZ {
                for p in trajectory {
                    let q = mapping.point(x: p.x, z: p.y)
                    trailPath.addEllipse(in: CGRect(x: q.x - 1, y: q.y - 1, width: 2, height: 2))
                }
            }
            context.fill(trailPath, with: .color(.white.opacity(0.35)))

            if let c = manager.currentXZ {
                let center = mapping.point(x: c.x, z: c.y)
                if let f = manager.currentForwardXZ {
                    let d = mapping.direction(x: f.x, z: f.y)
                    let len = max(hypot(d.dx, d.dy), 1e-6)
                    let arrowLength: CGFloat = 18
                    let tip = CGPoint(x: center.x + arrowLength * d.dx / len, y: center.y + arrowLength * d.dy / len)
                    var arrow = Path()
                    arrow.move(to: center)
                    arrow.addLine(to: tip)
                    context.stroke(arrow, with: .color(.cyan), lineWidth: 2.5)
                }
                var dot = Path()
                dot.addEllipse(in: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
                context.fill(dot, with: .color(.cyan))
            }
        }
    }

    // MARK: - 하단: 상태 + 지도 선택 + 좌표 텍스트

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statusText)
                .foregroundStyle(.white)
                .font(.subheadline.weight(.semibold))

            if isProjectMode {
                mapPicker
            }

            if let mapPose = manager.mapPose {
                coordinateLine(label: "map 좌표", pose: mapPose)
            } else if let groundPose = manager.groundPose {
                coordinateLine(label: isProjectMode ? "프로젝트 기준 좌표" : "스캔 기준 좌표(정합 파일 없음)", pose: groundPose)
            }

            if let importErrorMessage {
                Text(importErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("닫기") { dismiss() }
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 프로젝트 모드: "지금 근처 스캔"을 직접 고르거나 자동 순환에 맡긴다.
    private var mapPicker: some View {
        HStack(spacing: 8) {
            Text("지도")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
            Menu {
                Button {
                    manager.resumeAutoCycle()
                } label: {
                    Label("자동 순환", systemImage: manager.isAutoCycling ? "checkmark" : "arrow.triangle.2.circlepath")
                }
                Divider()
                ForEach(Array(manager.candidates.enumerated()), id: \.element.id) { index, candidate in
                    Button {
                        manager.select(index: index)
                    } label: {
                        if index == manager.activeIndex, !manager.isAutoCycling {
                            Label(candidate.label, systemImage: "checkmark")
                        } else {
                            Text(candidate.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(manager.candidates[safe: manager.activeIndex]?.label ?? "-")
                    if manager.isAutoCycling {
                        Text("(자동 순환)")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.15), in: Capsule())
            }
        }
    }

    private func coordinateLine(label: String, pose: GroundPose) -> some View {
        // Text의 "\(value, format:)" 특수 보간은 LocalizedStringKey 리터럴에만 적용되고
        // +로 이어붙인 일반 String에는 못 쓰므로, 값을 먼저 문자열로 포맷한 뒤 평범한
        // 문자열 보간으로 합친다.
        let x = String(format: "%.2f", pose.x)
        let y = String(format: "%.2f", pose.y)
        let headingDeg = String(format: "%.0f", pose.headingRad * 180 / .pi)
        return Text("\(label): x=\(x)m, y=\(y)m, heading=\(headingDeg)°")
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
    }

    private var statusText: String {
        switch manager.phase {
        case .loadingWorldMap: return "위치 지도를 불러오는 중..."
        case .relocalizing:
            if isProjectMode, let label = manager.candidates[safe: manager.activeIndex]?.label {
                return "재추적 중 — \(label)을(를) 찍었던 곳을 천천히 비춰주세요"
            }
            return "재추적 중 — 스캔했던 곳을 천천히 비춰주세요"
        case .tracking:
            if isProjectMode, let label = manager.candidates[safe: manager.activeIndex]?.label {
                return "확인됨 (\(label) 지도)"
            }
            return "확인됨"
        case .failed(let message): return "실패: \(message)"
        }
    }

    // MARK: - 정합 파일 가져오기

    /// registration_transform.json은 scan-to-map-studio(별도 데스크탑 파이프라인)가
    /// 만드는 파일이라 iPhone에 자동으로 안 들어온다 -- Files 앱 등에서 이 파일을
    /// 골라 기준 스캔 폴더로 복사해 넣어준다. 보안 스코프 리소스라 접근 전/후로
    /// start/stopAccessingSecurityScopedResource를 짝지어 호출해야 한다.
    private func handleCalibrationImport(_ result: Result<URL, Error>) {
        importErrorMessage = nil
        switch result {
        case .failure(let error):
            importErrorMessage = "가져오기 실패: \(error.localizedDescription)"
        case .success(let sourceURL):
            guard let referenceURL = manager.referenceFolderURL else { return }
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
            do {
                let destURL = referenceURL.appendingPathComponent("registration_transform.json")
                let data = try Data(contentsOf: sourceURL)
                try data.write(to: destURL)
                manager.reloadCalibration()
            } catch {
                importErrorMessage = "복사 실패: \(error.localizedDescription)"
            }
        }
    }
}

/// 재국지화 자체는 mesh 시각화가 필요 없어 ScanView.ARPreview보다 훨씬 가볍다
/// (ARSCNViewDelegate 불필요).
private struct ARLocalizePreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = true
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

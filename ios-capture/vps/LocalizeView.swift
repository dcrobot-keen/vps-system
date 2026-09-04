import ARKit
import SceneKit
import SwiftUI
import UniformTypeIdentifiers

/// "서버 없이 지금 어디쯤인지 확인"하는 화면. 저장된 ARWorldMap으로 재국지화를
/// 시도하고, 성공하면 이 스캔 좌표계(scan_basemap) 기준 위치를 상단 2D 뷰에
/// 점+화살표로 보여준다. registration_transform.json이 이 스캔 폴더에 있으면(직접
/// 넣거나 "정합 파일 가져오기"로 넣으면) map(로봇 SLAM) 좌표로도 함께 보여준다 --
/// 이 가져오기는 로봇 파이프라인 산출물이라 고급 모드가 켜져 있을 때만 노출된다.
struct LocalizeView: View {
    let project: ScanProject

    @StateObject private var manager = LocalizeSessionManager()
    @Environment(\.dismiss) private var dismiss
    @State private var isImportingCalibration = false
    @State private var importErrorMessage: String?

    /// registration_transform.json은 scan-to-map-studio(로봇 파이프라인) 산출물이라
    /// 일반 사용자에겐 의미가 없다 -- "정합 파일 가져오기" 버튼 자체를 고급 모드
    /// 뒤로 숨긴다. 위치 확인 기능(재국지화, 스캔 기준 좌표 표시)은 고급 모드와
    /// 무관하게 항상 쓸 수 있다.
    @AppStorage(ServerSettingsStore.advancedModeKey) private var isAdvancedModeEnabled = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ARLocalizePreview(
                session: manager.session,
                overlay: manager.floorPlanOverlay,
                worldPosition: manager.worldPosition
            )
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
        .onAppear { manager.start(project: project) }
        .onDisappear { manager.stop() }
    }

    // MARK: - 상단: top-down 2D 위치 표시

    private var topDownView: some View {
        Canvas { context, size in
            let displayPose = manager.mapPose ?? manager.groundPose
            let bounds = TopDownBounds(trajectory: manager.trajectory, current: displayPose.map { SIMD2($0.x, $0.y) })
            let mapPoint: (SIMD2<Double>) -> CGPoint = { bounds.project($0, into: size) }

            var trailPath = Path()
            for point in manager.trajectory {
                let p = mapPoint(point)
                trailPath.addEllipse(in: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2))
            }
            context.fill(trailPath, with: .color(.white.opacity(0.25)))

            if let pose = displayPose {
                let center = mapPoint(SIMD2(pose.x, pose.y))
                let arrowLength: CGFloat = 18
                let tip = CGPoint(
                    x: center.x + arrowLength * CGFloat(cos(pose.headingRad)),
                    y: center.y - arrowLength * CGFloat(sin(pose.headingRad))
                )
                var arrow = Path()
                arrow.move(to: center)
                arrow.addLine(to: tip)
                context.stroke(arrow, with: .color(.cyan), lineWidth: 2.5)

                var dot = Path()
                dot.addEllipse(in: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
                context.fill(dot, with: .color(.cyan))
            }
        }
    }

    // MARK: - 하단: 상태 + 좌표 텍스트

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statusText)
                .foregroundStyle(.white)
                .font(.subheadline.weight(.semibold))

            if let mapPose = manager.mapPose {
                coordinateLine(label: "map 좌표", pose: mapPose)
            } else if let groundPose = manager.groundPose {
                coordinateLine(label: "스캔 기준 좌표(정합 파일 없음)", pose: groundPose)
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
        case .relocalizing: return "재추적 중 — 스캔했던 곳을 천천히 비춰주세요"
        case .tracking: return "확인됨"
        case .failed(let message): return "실패: \(message)"
        }
    }

    // MARK: - 정합 파일 가져오기

    /// registration_transform.json은 scan-to-map-studio(별도 데스크탑 파이프라인)가
    /// 만드는 파일이라 iPhone에 자동으로 안 들어온다 -- Files 앱 등에서 이 파일을
    /// 골라 스캔 폴더로 복사해 넣어준다. 보안 스코프 리소스라 접근 전/후로
    /// start/stopAccessingSecurityScopedResource를 짝지어 호출해야 한다.
    private func handleCalibrationImport(_ result: Result<URL, Error>) {
        importErrorMessage = nil
        switch result {
        case .failure(let error):
            importErrorMessage = "가져오기 실패: \(error.localizedDescription)"
        case .success(let sourceURL):
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
            do {
                let destURL = project.url.appendingPathComponent("registration_transform.json")
                let data = try Data(contentsOf: sourceURL)
                try data.write(to: destURL)
                manager.reloadCalibration()
            } catch {
                importErrorMessage = "복사 실패: \(error.localizedDescription)"
            }
        }
    }
}

/// 재국지화 자체는 mesh 시각화가 필요 없어 ScanView.ARPreview보다 훨씬 가볍지만,
/// 바닥 오버레이(SCNPlane)와 실시간 위치 마커는 SceneKit 노드로 직접 얹는다 --
/// Coordinator가 두 노드를 한 번만 만들고 이후엔 위치/이미지만 갱신한다(매 프레임
/// updateUIView가 불려도 노드를 다시 만들지 않도록).
private struct ARLocalizePreview: UIViewRepresentable {
    let session: ARSession
    let overlay: FloorPlanOverlay?
    let worldPosition: SIMD3<Float>?

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = true
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.apply(overlay: overlay, worldPosition: worldPosition, to: uiView.scene)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// floorplan.png를 실제 바닥 위에 반투명하게 겹치고(색이 AR 조명 추정 때문에
    /// 어두워지지 않도록 lightingModel = .constant), 지금 위치를 작은 구슬 마커로
    /// 보여준다. 평면/마커 모두 world 좌표(ARSession 좌표계, GroundPose 변환 없음)에
    /// 그대로 놓는다 -- floorplan.png를 만들 때 쓴 좌표계와 같아서 추가 변환이
    /// 필요 없다.
    ///
    /// 주의: SCNPlane 회전 방향(-90도, X축)과 이미지 UV가 실제로 "화면에서 보이는
    /// 대로" 바닥에 겹치는지는 이 환경(Windows, Xcode 없음)에서 실기기로 확인할
    /// 방법이 없었다 -- 만약 이미지가 좌우/상하로 뒤집혀 보이면 회전 부호나
    /// material.diffuse.contentsTransform을 조정해야 한다.
    final class Coordinator {
        private var planeNode: SCNNode?
        private var markerNode: SCNNode?
        private var appliedImage: UIImage?

        func apply(overlay: FloorPlanOverlay?, worldPosition: SIMD3<Float>?, to scene: SCNScene) {
            if let overlay, appliedImage !== overlay.image {
                planeNode?.removeFromParentNode()
                let plane = SCNPlane(width: CGFloat(overlay.worldWidth), height: CGFloat(overlay.worldDepth))
                let material = SCNMaterial()
                material.diffuse.contents = overlay.image
                material.lightingModel = .constant
                material.isDoubleSided = true
                plane.materials = [material]

                let node = SCNNode(geometry: plane)
                node.opacity = 0.6
                // SCNPlane은 로컬 XY 평면(법선 +Z)에 놓이므로, world XZ 평면(실제
                // 바닥, 법선 +Y)에 눕히려면 로컬 X축으로 -90도 돌린다.
                node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
                node.position = SCNVector3(overlay.centerX, overlay.floorY, overlay.centerZ)
                scene.rootNode.addChildNode(node)

                planeNode = node
                appliedImage = overlay.image
            } else if overlay == nil, planeNode != nil {
                planeNode?.removeFromParentNode()
                planeNode = nil
                appliedImage = nil
            }

            guard let worldPosition else {
                markerNode?.isHidden = true
                return
            }
            if markerNode == nil {
                let marker = Self.makeMarkerNode()
                scene.rootNode.addChildNode(marker)
                markerNode = marker
            }
            markerNode?.isHidden = false
            markerNode?.position = SCNVector3(worldPosition.x, worldPosition.y, worldPosition.z)
        }

        private static func makeMarkerNode() -> SCNNode {
            let sphere = SCNSphere(radius: 0.08)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.cyan
            material.lightingModel = .constant
            sphere.materials = [material]
            return SCNNode(geometry: sphere)
        }
    }
}

/// 궤적 점들 + 현재 위치를 감싸는 정사각형 범위를 잡아 Canvas 크기에 맞춰
/// 투영한다. 화면 좌표는 y가 아래로 증가하므로 world y는 뒤집어서 그린다(+y가
/// 화면 위쪽이 되도록).
private struct TopDownBounds {
    let centerX: Double
    let centerY: Double
    let span: Double

    init(trajectory: [SIMD2<Double>], current: SIMD2<Double>?) {
        var points = trajectory
        if let current { points.append(current) }
        guard !points.isEmpty else {
            centerX = 0
            centerY = 0
            span = 4 // 데이터가 아직 없을 때의 기본 표시 범위(m)
            return
        }
        let minX = points.map(\.x).min()!
        let maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!
        let maxY = points.map(\.y).max()!
        centerX = (minX + maxX) / 2
        centerY = (minY + maxY) / 2
        span = max(maxX - minX, maxY - minY, 2) // 최소 2m -- 너무 좁으면 점이 화면 밖으로 튐
    }

    func project(_ point: SIMD2<Double>, into size: CGSize) -> CGPoint {
        let scale = Double(min(size.width, size.height)) * 0.85 / span
        let x = Double(size.width) / 2 + (point.x - centerX) * scale
        let y = Double(size.height) / 2 - (point.y - centerY) * scale
        return CGPoint(x: x, y: y)
    }
}

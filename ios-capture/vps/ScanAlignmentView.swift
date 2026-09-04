import SwiftUI
import UIKit

/// 프로젝트 안 스캔들을 위에서 내려다본 2D 화면에서 정렬한다. 각 스캔의 floorplan.png
/// (+ floorplan.json의 좌표 매핑)를 겹쳐 보여주되 못 본 곳은 투명하게 뚫고 벽을 스캔마다
/// 다른 색(기준 흰색, 고른 스캔 주황, 나머지 회색)으로 칠해 겹침이 보이게 한다. 고른
/// 스캔 위를 한 손가락으로 끌어 옮기고 두 손가락으로 돌리며(이미지 중심 기준), 빈 곳을
/// 끌면 화면이 움직이고 핀치로 확대한다. "자동 맞춤"은 손으로 대충 놓은 자리를 초기값으로
/// 2D ICP(ScanRegistration)가 벽을 맞춰 마무리한다. 첫 번째 스캔이 기준(고정)이고,
/// 나머지의 변환(`ScanAlignment`)이 저장돼 합칠 때(ScanGroupMerger)와 프로젝트 단위 위치
/// 확인(LocalizeView)에 그대로 쓰인다 -- 미리보기와 합치기가 같은 `ScanAlignment.applyXZ`를
/// 쓰므로 여기서 맞춘 대로 결과가 나온다. 수직(바닥 높이)은 합칠 때 자동으로 맞춘다.
/// 그리기/좌표는 FloorPlanLayer.swift의 공용 코드.
struct ScanAlignmentView: View {
    let group: ScanGroup
    let scans: [ScanProject]
    let onSave: ([String: ScanAlignment]) -> Void

    /// 레이어 역할별 벽 색. 틴트 이미지는 역할마다 미리 만들어둔다(loadLayers).
    private enum Role: Hashable {
        case reference, selected, other

        var tint: UIColor {
            switch self {
            case .reference: return UIColor(red: 1, green: 1, blue: 1, alpha: 1)
            case .selected: return UIColor(red: 1, green: 0.62, blue: 0.15, alpha: 1)
            case .other: return UIColor(red: 0.6, green: 0.6, blue: 0.65, alpha: 1)
            }
        }

        var outline: Color {
            switch self {
            case .reference: return .white.opacity(0.7)
            case .selected: return .orange
            case .other: return .clear
            }
        }
    }

    private enum DragMode {
        case moveLayer(base: ScanAlignment)
        case panCanvas(base: CGSize)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var layers: [FloorPlanLayer] = []
    @State private var tintedImages: [String: [Role: UIImage]] = [:]
    @State private var alignments: [String: ScanAlignment] = [:]
    @State private var selectedScanID: String?
    @State private var isLoading = true

    /// 화면 범위는 처음 열 때(와 "전체 보기"에서만) 잡는다 -- 드래그할 때마다 다시 맞추면
    /// 화면이 같이 움직여서 조작이 안 된다. 그 위에 핀치 줌/팬(`zoom`, `pan`)을 얹는다.
    @State private var bounds = TopDownBounds()
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero

    @State private var dragMode: DragMode?
    /// 두 손가락 제스처(회전/확대)가 시작되면 같이 발동한 한 손가락 드래그는 끝날 때까지 무시.
    @State private var isDragSuppressed = false
    @State private var rotationBase: ScanAlignment?
    @State private var rotationPivot: SIMD2<Float>?
    @State private var magnifyBase: (zoom: CGFloat, pan: CGSize)?

    @State private var isAutoAligning = false
    @State private var autoAlignMessage: String?
    @State private var autoAlignFailed = false

    private var referenceScanID: String? { group.scanIDs.first }
    private var selectedLayer: FloorPlanLayer? { layers.first { $0.id == selectedScanID } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    ZStack(alignment: .topTrailing) {
                        canvas(mapping: mapping(for: proxy.size))
                            .gesture(
                                dragGesture(size: proxy.size)
                                    .simultaneously(with: rotationGesture())
                                    .simultaneously(with: magnifyGesture(size: proxy.size))
                            )
                        Button {
                            fitAll()
                        } label: {
                            Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                                .padding(8)
                                .background(.black.opacity(0.5), in: Circle())
                                .foregroundStyle(.white)
                        }
                        .padding(10)
                        .accessibilityLabel("전체 보기")
                    }
                }
                .background(Color(white: 0.12))

                controls
                    .padding()
                    .background(.bar)
            }
            .navigationTitle("스캔 정렬")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        onSave(alignments)
                        dismiss()
                    }
                }
            }
            .task { await loadLayers() }
        }
    }

    // MARK: - 그리기

    private func mapping(for size: CGSize) -> TopDownMapping {
        TopDownMapping(bounds: bounds, size: size).zoomed(by: zoom, pan: pan)
    }

    private func role(of layer: FloorPlanLayer) -> Role {
        if layer.id == selectedScanID { return .selected }
        if layer.id == referenceScanID { return .reference }
        return .other
    }

    private func canvas(mapping: TopDownMapping) -> some View {
        Canvas { context, _ in
            // 고른 스캔을 맨 위에 그린다.
            let ordered = layers.filter { $0.id != selectedScanID } + layers.filter { $0.id == selectedScanID }
            for layer in ordered {
                let alignment = alignments[layer.id] ?? .identity
                let layerRole = role(of: layer)
                context.drawFloorPlanLayer(
                    layer, alignment: alignment, mapping: mapping,
                    opacity: layerRole == .other ? 0.55 : 1,
                    image: tintedImages[layer.id]?[layerRole]
                )
                if layerRole != .other {
                    context.strokeFloorPlanOutline(
                        layer, alignment: alignment, mapping: mapping,
                        color: layerRole.outline,
                        lineWidth: layerRole == .selected ? 2 : 1,
                        dash: layerRole == .reference ? [6, 4] : []
                    )
                }
            }
        }
    }

    // MARK: - 컨트롤

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoading {
                ProgressView("바닥 평면 불러오는 중…")
            } else if layers.count < 2 {
                Text("바닥 평면이 있는 스캔이 2개 이상이어야 정렬할 수 있습니다")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Picker("맞출 스캔", selection: $selectedScanID) {
                    ForEach(layers.filter { $0.id != referenceScanID }) { layer in
                        Text(layer.label).tag(Optional(layer.id))
                    }
                }
                .pickerStyle(.menu)

                // +yaw는 위에서 내려다보면(화면 위 = -z) 반시계 방향 -- FloorPlanLayer 참고.
                HStack(spacing: 12) {
                    Button {
                        adjustYaw(by: 5)
                    } label: {
                        Label("+5°", systemImage: "rotate.left")
                    }
                    Button {
                        adjustYaw(by: -5)
                    } label: {
                        Label("−5°", systemImage: "rotate.right")
                    }
                    Button {
                        autoAlign()
                    } label: {
                        if isAutoAligning {
                            ProgressView()
                        } else {
                            Label("자동 맞춤", systemImage: "wand.and.stars")
                        }
                    }
                    .disabled(isAutoAligning)
                    Spacer()
                    Button("초기화") {
                        if let selectedScanID {
                            alignments[selectedScanID] = .identity
                            autoAlignMessage = nil
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(selectedScanID == nil)

                if let autoAlignMessage {
                    Text(autoAlignMessage)
                        .font(.footnote)
                        .foregroundStyle(autoAlignFailed ? Color.orange : Color.secondary)
                }

                Text("주황색이 고른 스캔, 흰색 점선이 기준 스캔입니다. 스캔 위를 한 손가락으로 끌어 옮기고 두 손가락으로 돌리세요. 빈 곳을 끌면 화면이 움직이고, 핀치로 확대합니다. 대충 맞춘 뒤 \"자동 맞춤\"을 누르면 벽을 기준으로 정확히 맞춥니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func adjustYaw(by degrees: Float) {
        guard let selectedScanID, let layer = selectedLayer else { return }
        let current = alignments[selectedScanID] ?? .identity
        let pivot = layer.center(with: current)
        alignments[selectedScanID] = current.rotated(by: degrees * .pi / 180, aboutX: pivot.x, z: pivot.z)
    }

    /// 현재 정렬 기준으로 모든 스캔이 들어오게 화면 범위를 다시 잡고 줌/팬을 초기화.
    private func fitAll() {
        var b = TopDownBounds()
        for layer in layers { b.include(layer, alignment: alignments[layer.id] ?? .identity) }
        bounds = b.padded(fraction: 0.15, minimum: 1)
        zoom = 1
        pan = .zero
    }

    // MARK: - 제스처

    /// 두 손가락 제스처가 시작될 때: 같이 시작돼버린 드래그가 있으면 그 변화를 되돌리고
    /// 드래그가 끝날 때까지 무시한다.
    private func suppressDrag() {
        if let dragMode {
            switch dragMode {
            case .moveLayer(let base):
                if let selectedScanID { alignments[selectedScanID] = base }
            case .panCanvas(let base):
                pan = base
            }
        }
        dragMode = nil
        isDragSuppressed = true
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard !isDragSuppressed else { return }
                let currentMapping = mapping(for: size)
                if dragMode == nil {
                    // 고른 스캔 위에서 시작한 드래그는 스캔 이동, 그 밖은 화면 이동.
                    let start = currentMapping.world(at: value.startLocation)
                    if let selectedScanID, let layer = selectedLayer,
                       layer.contains(x: start.x, z: start.z, alignment: alignments[selectedScanID] ?? .identity) {
                        dragMode = .moveLayer(base: alignments[selectedScanID] ?? .identity)
                    } else {
                        dragMode = .panCanvas(base: pan)
                    }
                }
                switch dragMode {
                case .moveLayer(let base):
                    guard let selectedScanID else { return }
                    // 화면 x -> world x, 화면 y(아래로 증가) -> world +z (화면 위 = -z).
                    var a = base
                    a.offsetX = base.offsetX + Float(value.translation.width / currentMapping.scale)
                    a.offsetZ = base.offsetZ + Float(value.translation.height / currentMapping.scale)
                    alignments[selectedScanID] = a
                case .panCanvas(let base):
                    pan = CGSize(width: base.width + value.translation.width, height: base.height + value.translation.height)
                case nil:
                    break
                }
            }
            .onEnded { _ in
                dragMode = nil
                isDragSuppressed = false
            }
    }

    private func rotationGesture() -> some Gesture {
        RotationGesture()
            .onChanged { angle in
                guard let selectedScanID, let layer = selectedLayer else { return }
                if rotationBase == nil {
                    suppressDrag()
                    let base = alignments[selectedScanID] ?? .identity
                    rotationBase = base
                    let pivot = layer.center(with: base)
                    rotationPivot = SIMD2(pivot.x, pivot.z)
                }
                guard let base = rotationBase, let pivot = rotationPivot else { return }
                // 제스처 각도는 화면에서 시계 방향이 양수, yaw는 위에서 봤을 때 반시계가
                // 양수라 부호를 뒤집어야 손가락을 따라 돈다. 이미지 중심을 축으로 돌려서
                // 회전해도 스캔이 화면 밖으로 날아가지 않는다.
                alignments[selectedScanID] = base.rotated(by: -Float(angle.radians), aboutX: pivot.x, z: pivot.y)
            }
            .onEnded { _ in
                rotationBase = nil
                rotationPivot = nil
            }
    }

    private func magnifyGesture(size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if magnifyBase == nil {
                    suppressDrag()
                    magnifyBase = (zoom, pan)
                }
                guard let base = magnifyBase else { return }
                let newZoom = min(max(base.zoom * value, 0.5), 30)
                // 화면 중심이 제자리에 있도록 pan 보정(screen = pan + zoom * base_point).
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let baseX = (center.x - base.pan.width) / base.zoom
                let baseY = (center.y - base.pan.height) / base.zoom
                pan = CGSize(width: center.x - newZoom * baseX, height: center.y - newZoom * baseY)
                zoom = newZoom
            }
            .onEnded { _ in magnifyBase = nil }
    }

    // MARK: - 자동 맞춤

    /// 고른 스캔의 벽 점을 나머지 스캔들(현재 정렬 적용)의 벽 점에 ICP로 맞춘다. 초기값은
    /// 지금 손으로 놓은 자리. 겹치는 벽이 적으면(대응 비율 낮음) 결과를 버리고 알린다.
    private func autoAlign() {
        guard let selectedScanID, let source = selectedLayer else { return }
        let others = layers.filter { $0.id != selectedScanID }
        func transformed(_ points: (FloorPlanLayer) -> [SIMD2<Float>]) -> [SIMD2<Float>] {
            others.flatMap { layer -> [SIMD2<Float>] in
                let a = alignments[layer.id] ?? .identity
                return points(layer).map { p in
                    let q = a.applyXZ(x: p.x, z: p.y)
                    return SIMD2(q.x, q.z)
                }
            }
        }
        let target = transformed { $0.wallPointsXZ }
        let freeTarget = transformed { $0.freePointsXZ }
        guard !source.wallPointsXZ.isEmpty, !target.isEmpty else {
            autoAlignFailed = true
            autoAlignMessage = "벽이 잡힌 바닥 평면이 있어야 자동 맞춤을 할 수 있습니다"
            return
        }
        let sourcePoints = source.wallPointsXZ
        let initial = alignments[selectedScanID] ?? .identity
        isAutoAligning = true
        autoAlignMessage = nil

        Task.detached(priority: .userInitiated) {
            let result = ScanRegistration.align(source: sourcePoints, target: target, freeTarget: freeTarget, initial: initial)
            await MainActor.run {
                isAutoAligning = false
                let inlierPercent = Int((result.inlierFraction * 100).rounded())
                let conflictPercent = Int((result.conflictFraction * 100).rounded())
                if !result.isReliable {
                    autoAlignFailed = true
                    autoAlignMessage = "겹치는 벽을 충분히 찾지 못했습니다(겹침 \(inlierPercent)%, 모순 \(conflictPercent)%). 같은 공간을 겹쳐 찍은 스캔에서만 자동 맞춤이 됩니다 -- 다른 방이면 손으로 놓거나, 다음부터 \"이전 스캔 위치에 맞추기\"로 찍어주세요."
                } else {
                    alignments[selectedScanID] = result.alignment
                    autoAlignFailed = false
                    let rmseCm = String(format: "%.1f", result.rmse * 100)
                    autoAlignMessage = "자동 맞춤 완료 · 벽 평균 오차 \(rmseCm)cm · 대응 \(inlierPercent)%"
                }
            }
        }
    }

    // MARK: - 로드

    /// floorplan.png/floorplan.json이 있는 스캔만 레이어로 올린다(없는 스캔은 화면에
    /// 보여줄 게 없어 정렬 대상에서 빠지지만, 저장된 변환은 그대로 유지된다). 역할별
    /// 틴트 이미지도 여기서 한 번에 만든다(픽셀 단위 작업이라 백그라운드).
    private func loadLayers() async {
        let scansSnapshot = scans
        let referenceID = referenceScanID
        let (loaded, tinted): ([FloorPlanLayer], [String: [Role: UIImage]]) = await Task.detached(priority: .userInitiated) {
            let layers = scansSnapshot.enumerated().compactMap { index, scan in
                FloorPlanLayer.load(scanID: scan.id, label: "스캔 \(index + 1)", folderURL: scan.url, forAlignment: true)
            }
            var images: [String: [Role: UIImage]] = [:]
            for layer in layers {
                let roles: [Role] = layer.id == referenceID ? [.reference] : [.selected, .other]
                var byRole: [Role: UIImage] = [:]
                for role in roles { byRole[role] = layer.tintedImage(role.tint) }
                images[layer.id] = byRole
            }
            return (layers, images)
        }.value

        layers = loaded
        tintedImages = tinted
        alignments = group.alignments
        if selectedScanID == nil {
            selectedScanID = loaded.first { $0.id != referenceID }?.id
        }
        fitAll()
        isLoading = false
    }
}

import SwiftUI
import UIKit

/// 프로젝트 안 스캔들을 위에서 내려다본 2D 화면에서 손으로 정렬한다. 각 스캔의
/// floorplan.png(+ floorplan.json의 좌표 매핑)를 겹쳐 보여주고, 고른 스캔을 한 손가락
/// 드래그로 옮기고 두 손가락으로 돌린다(±5° 버튼으로 미세 조정). 첫 번째 스캔이
/// 기준(고정)이고, 나머지의 변환(`ScanAlignment`)이 저장돼 합칠 때(ScanGroupMerger)
/// 그대로 쓰인다 -- 미리보기와 합치기가 같은 `ScanAlignment.applyXZ`를 쓰므로 여기서
/// 맞춘 대로 결과가 나온다. 수직(바닥 높이)은 합칠 때 자동으로 맞춘다.
///
/// 좌표: world (x, z) 평면을 그대로 그린다(화면 위 = -z). floorplan.png는 row 0이
/// 가장 큰 z(originTopZ)라 뒤집지 않고 그대로 그리면 맞는다 -- LocalizeView의 배경
/// 지도가 뒤집어야 했던 건 GroundPose(y = -z) 좌표계였기 때문이고 여기와는 다르다.
struct ScanAlignmentView: View {
    let group: ScanGroup
    let scans: [ScanProject]
    let onSave: ([String: ScanAlignment]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var layers: [Layer] = []
    @State private var alignments: [String: ScanAlignment] = [:]
    @State private var selectedScanID: String?
    @State private var bounds: Bounds?
    @State private var dragBase: ScanAlignment?
    @State private var rotationBase: Float?

    /// 스캔 하나의 바닥 평면 이미지 + 그 이미지의 world 좌표 매핑.
    struct Layer: Identifiable {
        let id: String
        let label: String
        let image: UIImage
        let meta: FloorPlanRenderer.PersistedMeta

        var worldWidth: Float { Float(meta.widthPx) * meta.resolutionMetersPerPixel }
        var worldDepth: Float { Float(meta.heightPx) * meta.resolutionMetersPerPixel }

        /// 정렬 변환 적용 후 이미지 네 모서리의 world (x, z) -- 화면 범위 계산과
        /// 선택 표시용. TL, TR, BR, BL 순서.
        func corners(with alignment: ScanAlignment) -> [(x: Float, z: Float)] {
            let x0 = meta.originX, z0 = meta.originTopZ
            let x1 = x0 + worldWidth, z1 = z0 - worldDepth
            return [(x0, z0), (x1, z0), (x1, z1), (x0, z1)].map { alignment.applyXZ(x: $0.0, z: $0.1) }
        }
    }

    /// 편집 중엔 고정된 화면 범위(계속 다시 맞추면 드래그할 때 화면이 같이 움직여서
    /// 조작이 안 됨). 처음 열 때 모든 스캔을 넉넉히 담는 범위로 한 번만 잡는다.
    struct Bounds {
        var minX: Float, maxX: Float, minZ: Float, maxZ: Float
    }

    private var referenceScanID: String? { group.scanIDs.first }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    let mapping = Mapping(bounds: bounds, size: proxy.size)
                    canvas(mapping: mapping)
                        .gesture(dragGesture(mapping: mapping).simultaneously(with: rotationGesture()))
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

    private func canvas(mapping: Mapping) -> some View {
        Canvas { context, _ in
            for layer in layers {
                let alignment = alignments[layer.id] ?? .identity
                let isSelected = layer.id == selectedScanID
                let isReference = layer.id == referenceScanID

                // 이미지 왼쪽 위 모서리(row 0, col 0)의 world 위치를 정렬 변환한 자리에
                // 원점을 놓고 yaw만큼 돌린 뒤 이미지를 그린다 -- 정렬 변환이 "회전 후
                // 이동"이고 화면 y가 -z라, 화면 회전각은 yaw 그대로다(ScanAlignment 참고).
                let topLeft = alignment.applyXZ(x: layer.meta.originX, z: layer.meta.originTopZ)
                let origin = mapping.point(x: topLeft.x, z: topLeft.z)
                let size = CGSize(
                    width: CGFloat(layer.worldWidth) * mapping.scale,
                    height: CGFloat(layer.worldDepth) * mapping.scale
                )
                context.drawLayer { inner in
                    inner.translateBy(x: origin.x, y: origin.y)
                    inner.rotate(by: Angle(radians: Double(alignment.yawRadians)))
                    inner.opacity = isSelected ? 0.9 : (isReference ? 0.75 : 0.5)
                    inner.draw(Image(uiImage: layer.image), in: CGRect(origin: .zero, size: size))
                }

                if isSelected || isReference {
                    var outline = Path()
                    let corners = layer.corners(with: alignment).map { mapping.point(x: $0.x, z: $0.z) }
                    outline.move(to: corners[0])
                    for c in corners.dropFirst() { outline.addLine(to: c) }
                    outline.closeSubpath()
                    context.stroke(
                        outline,
                        with: .color(isSelected ? .cyan : .white.opacity(0.6)),
                        style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: isReference && !isSelected ? [6, 4] : [])
                    )
                }
            }
        }
    }

    /// world (x, z) <-> 화면 좌표. 종횡비를 유지하고 가운데 정렬한다.
    private struct Mapping {
        let scale: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
        let maxZ: Float
        let minX: Float

        init(bounds: Bounds?, size: CGSize) {
            let b = bounds ?? Bounds(minX: -2, maxX: 2, minZ: -2, maxZ: 2)
            let spanX = max(b.maxX - b.minX, 0.5)
            let spanZ = max(b.maxZ - b.minZ, 0.5)
            scale = min(size.width / CGFloat(spanX), size.height / CGFloat(spanZ)) * 0.9
            offsetX = (size.width - CGFloat(spanX) * scale) / 2
            offsetY = (size.height - CGFloat(spanZ) * scale) / 2
            maxZ = b.maxZ
            minX = b.minX
        }

        func point(x: Float, z: Float) -> CGPoint {
            CGPoint(
                x: offsetX + CGFloat(x - minX) * scale,
                y: offsetY + CGFloat(maxZ - z) * scale
            )
        }
    }

    // MARK: - 조작

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if layers.count < 2 {
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

                HStack(spacing: 12) {
                    Button {
                        adjustYaw(by: -5)
                    } label: {
                        Label("−5°", systemImage: "rotate.left")
                    }
                    Button {
                        adjustYaw(by: 5)
                    } label: {
                        Label("+5°", systemImage: "rotate.right")
                    }
                    Spacer()
                    Button("초기화") {
                        if let selectedScanID { alignments[selectedScanID] = .identity }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(selectedScanID == nil)

                Text("점선이 기준 스캔입니다. 고른 스캔을 한 손가락으로 끌어 옮기고, 두 손가락으로 돌려서 겹치는 부분을 맞추세요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func adjustYaw(by degrees: Float) {
        guard let selectedScanID else { return }
        var a = alignments[selectedScanID] ?? .identity
        a.yawRadians += degrees * .pi / 180
        alignments[selectedScanID] = a
    }

    private func dragGesture(mapping: Mapping) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let selectedScanID else { return }
                let base = dragBase ?? (alignments[selectedScanID] ?? .identity)
                if dragBase == nil { dragBase = base }
                var a = base
                // 화면 x -> world x, 화면 y(아래로 증가) -> world -z.
                a.offsetX = base.offsetX + Float(value.translation.width / mapping.scale)
                a.offsetZ = base.offsetZ - Float(value.translation.height / mapping.scale)
                alignments[selectedScanID] = a
            }
            .onEnded { _ in dragBase = nil }
    }

    private func rotationGesture() -> some Gesture {
        RotationGesture()
            .onChanged { angle in
                guard let selectedScanID else { return }
                let base = rotationBase ?? (alignments[selectedScanID] ?? .identity).yawRadians
                if rotationBase == nil { rotationBase = base }
                var a = alignments[selectedScanID] ?? .identity
                a.yawRadians = base + Float(angle.radians)
                alignments[selectedScanID] = a
            }
            .onEnded { _ in rotationBase = nil }
    }

    // MARK: - 로드

    /// floorplan.png/floorplan.json이 있는 스캔만 레이어로 올린다(없는 스캔은 화면에
    /// 보여줄 게 없어 정렬 대상에서 빠지지만, 저장된 변환은 그대로 유지된다).
    private func loadLayers() async {
        let scansSnapshot = scans
        let loaded: [Layer] = await Task.detached(priority: .userInitiated) {
            scansSnapshot.enumerated().compactMap { index, scan in
                guard let meta = FloorPlanRenderer.PersistedMeta.load(from: scan.url),
                      let image = UIImage(contentsOfFile: scan.url.appendingPathComponent("floorplan.png").path)
                else { return nil }
                return Layer(id: scan.id, label: "스캔 \(index + 1) (\(scan.id))", image: image, meta: meta)
            }
        }.value

        layers = loaded
        alignments = group.alignments
        if selectedScanID == nil {
            selectedScanID = loaded.first { $0.id != referenceScanID }?.id
        }

        var b = Bounds(minX: .greatestFiniteMagnitude, maxX: -.greatestFiniteMagnitude,
                       minZ: .greatestFiniteMagnitude, maxZ: -.greatestFiniteMagnitude)
        for layer in loaded {
            for c in layer.corners(with: alignments[layer.id] ?? .identity) {
                b.minX = min(b.minX, c.x); b.maxX = max(b.maxX, c.x)
                b.minZ = min(b.minZ, c.z); b.maxZ = max(b.maxZ, c.z)
            }
        }
        if b.minX < b.maxX {
            // 옮길 여지를 두기 위해 양쪽으로 넉넉히(전체 폭의 절반, 최소 2m) 넓힌다.
            let padX = max((b.maxX - b.minX) * 0.5, 2)
            let padZ = max((b.maxZ - b.minZ) * 0.5, 2)
            bounds = Bounds(minX: b.minX - padX, maxX: b.maxX + padX, minZ: b.minZ - padZ, maxZ: b.maxZ + padZ)
        }
    }
}

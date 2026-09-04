import SwiftUI
import UIKit

/// 프로젝트 안 스캔들을 위에서 내려다본 2D 화면에서 손으로 정렬한다. 각 스캔의
/// floorplan.png(+ floorplan.json의 좌표 매핑)를 겹쳐 보여주고, 고른 스캔을 한 손가락
/// 드래그로 옮기고 두 손가락으로 돌린다(±5° 버튼으로 미세 조정). 첫 번째 스캔이
/// 기준(고정)이고, 나머지의 변환(`ScanAlignment`)이 저장돼 합칠 때(ScanGroupMerger)와
/// 프로젝트 단위 위치 확인(LocalizeView)에 그대로 쓰인다 -- 미리보기와 합치기가 같은
/// `ScanAlignment.applyXZ`를 쓰므로 여기서 맞춘 대로 결과가 나온다. 수직(바닥 높이)은
/// 합칠 때 자동으로 맞춘다. 그리기/좌표는 FloorPlanLayer.swift의 공용 코드.
struct ScanAlignmentView: View {
    let group: ScanGroup
    let scans: [ScanProject]
    let onSave: ([String: ScanAlignment]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var layers: [FloorPlanLayer] = []
    @State private var alignments: [String: ScanAlignment] = [:]
    @State private var selectedScanID: String?
    /// 편집 중엔 고정된 화면 범위(계속 다시 맞추면 드래그할 때 화면이 같이 움직여서
    /// 조작이 안 됨). 처음 열 때 모든 스캔을 넉넉히 담는 범위로 한 번만 잡는다.
    @State private var bounds = TopDownBounds()
    @State private var dragBase: ScanAlignment?
    @State private var rotationBase: Float?

    private var referenceScanID: String? { group.scanIDs.first }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    let mapping = TopDownMapping(bounds: bounds, size: proxy.size)
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

    private func canvas(mapping: TopDownMapping) -> some View {
        Canvas { context, _ in
            for layer in layers {
                let alignment = alignments[layer.id] ?? .identity
                let isSelected = layer.id == selectedScanID
                let isReference = layer.id == referenceScanID
                context.drawFloorPlanLayer(
                    layer, alignment: alignment, mapping: mapping,
                    opacity: isSelected ? 0.9 : (isReference ? 0.75 : 0.5)
                )
                if isSelected || isReference {
                    context.strokeFloorPlanOutline(
                        layer, alignment: alignment, mapping: mapping,
                        color: isSelected ? .cyan : .white.opacity(0.6),
                        lineWidth: isSelected ? 2 : 1,
                        dash: isReference && !isSelected ? [6, 4] : []
                    )
                }
            }
        }
    }

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

    private func dragGesture(mapping: TopDownMapping) -> some Gesture {
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

    /// floorplan.png/floorplan.json이 있는 스캔만 레이어로 올린다(없는 스캔은 화면에
    /// 보여줄 게 없어 정렬 대상에서 빠지지만, 저장된 변환은 그대로 유지된다).
    private func loadLayers() async {
        let scansSnapshot = scans
        let loaded: [FloorPlanLayer] = await Task.detached(priority: .userInitiated) {
            scansSnapshot.enumerated().compactMap { index, scan in
                FloorPlanLayer.load(scanID: scan.id, label: "스캔 \(index + 1)", folderURL: scan.url)
            }
        }.value

        layers = loaded
        alignments = group.alignments
        if selectedScanID == nil {
            selectedScanID = loaded.first { $0.id != referenceScanID }?.id
        }

        var b = TopDownBounds()
        for layer in loaded { b.include(layer, alignment: alignments[layer.id] ?? .identity) }
        // 옮길 여지를 두기 위해 양쪽으로 넉넉히(전체 폭의 절반, 최소 2m) 넓힌다.
        bounds = b.padded(fraction: 0.5, minimum: 2)
    }
}

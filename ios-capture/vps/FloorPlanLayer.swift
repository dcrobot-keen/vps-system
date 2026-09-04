import SwiftUI
import UIKit

/// 스캔 하나의 바닥 평면 이미지(floorplan.png) + 그 이미지의 world 좌표 매핑
/// (floorplan.json). 정렬 화면(ScanAlignmentView)과 위치 확인 화면(LocalizeView)이
/// 같이 쓴다 -- 둘 다 위에서 내려다본 world (x, z) 평면에 각 스캔의 바닥 평면을
/// 정렬 변환(`ScanAlignment`) 적용해 겹쳐 그린다.
///
/// 방향 관례: **화면 위 = +z**. floorplan.png는 row 0이 그 이미지의 가장 큰 z라
/// (FloorPlanRenderer) 뒤집지 않고 그대로 그리면 맞는다. 두 화면이 같은 관례를 써야
/// 정렬 화면에서 맞춘 모양 그대로 위치 확인 화면에 나온다(예전 LocalizeView는
/// GroundPose(y = -z) 기준으로 위 = -z였고 이미지를 뒤집어 그렸다 -- 정렬 화면과
/// 상하가 반대라 통일했다).
struct FloorPlanLayer: Identifiable {
    let id: String
    let label: String
    let image: UIImage
    let meta: FloorPlanRenderer.PersistedMeta

    var worldWidth: Float { Float(meta.widthPx) * meta.resolutionMetersPerPixel }
    var worldDepth: Float { Float(meta.heightPx) * meta.resolutionMetersPerPixel }

    /// 정렬 변환 적용 후 이미지 네 모서리의 world (x, z) -- TL, TR, BR, BL 순서.
    func corners(with alignment: ScanAlignment) -> [(x: Float, z: Float)] {
        let x0 = meta.originX, z0 = meta.originTopZ
        let x1 = x0 + worldWidth, z1 = z0 - worldDepth
        return [(x0, z0), (x1, z0), (x1, z1), (x0, z1)].map { alignment.applyXZ(x: $0.0, z: $0.1) }
    }

    /// floorplan.png/floorplan.json이 둘 다 있어야 만들어진다(없는 스캔은 화면에
    /// 보여줄 게 없음). 파일 I/O라 호출부가 백그라운드에서 부르는 게 좋다.
    static func load(scanID: String, label: String, folderURL: URL) -> FloorPlanLayer? {
        guard let meta = FloorPlanRenderer.PersistedMeta.load(from: folderURL),
              let image = UIImage(contentsOfFile: folderURL.appendingPathComponent("floorplan.png").path)
        else { return nil }
        return FloorPlanLayer(id: scanID, label: label, image: image, meta: meta)
    }
}

/// world (x, z)의 축 정렬 범위. 레이어 모서리/궤적/현재 위치를 다 넣어 잡는다.
struct TopDownBounds {
    var minX = Float.greatestFiniteMagnitude
    var maxX = -Float.greatestFiniteMagnitude
    var minZ = Float.greatestFiniteMagnitude
    var maxZ = -Float.greatestFiniteMagnitude

    var isEmpty: Bool { minX > maxX || minZ > maxZ }

    mutating func include(x: Float, z: Float) {
        minX = min(minX, x); maxX = max(maxX, x)
        minZ = min(minZ, z); maxZ = max(maxZ, z)
    }

    mutating func include(_ layer: FloorPlanLayer, alignment: ScanAlignment) {
        for c in layer.corners(with: alignment) { include(x: c.x, z: c.z) }
    }

    /// 양쪽으로 여유를 둔다 -- 비율(전체 폭 기준)과 최소값(m) 중 큰 쪽.
    func padded(fraction: Float, minimum: Float) -> TopDownBounds {
        guard !isEmpty else { return self }
        let padX = max((maxX - minX) * fraction, minimum)
        let padZ = max((maxZ - minZ) * fraction, minimum)
        return TopDownBounds(minX: minX - padX, maxX: maxX + padX, minZ: minZ - padZ, maxZ: maxZ + padZ)
    }
}

/// world (x, z) <-> 화면 좌표. 종횡비를 유지하고 가운데 정렬, 화면 위 = +z.
struct TopDownMapping {
    let scale: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
    let minX: Float
    let maxZ: Float

    init(bounds: TopDownBounds, size: CGSize, fill: CGFloat = 0.9) {
        let b = bounds.isEmpty ? TopDownBounds(minX: -2, maxX: 2, minZ: -2, maxZ: 2) : bounds
        let spanX = max(b.maxX - b.minX, 0.5)
        let spanZ = max(b.maxZ - b.minZ, 0.5)
        scale = min(size.width / CGFloat(spanX), size.height / CGFloat(spanZ)) * fill
        offsetX = (size.width - CGFloat(spanX) * scale) / 2
        offsetY = (size.height - CGFloat(spanZ) * scale) / 2
        minX = b.minX
        maxZ = b.maxZ
    }

    func point(x: Float, z: Float) -> CGPoint {
        CGPoint(x: offsetX + CGFloat(x - minX) * scale, y: offsetY + CGFloat(maxZ - z) * scale)
    }

    /// world 방향 벡터(x, z)를 화면 방향으로(정규화 안 함). 화면 위 = +z라 z는 부호 반전.
    func direction(x: Float, z: Float) -> CGVector {
        CGVector(dx: CGFloat(x), dy: CGFloat(-z))
    }
}

extension GraphicsContext {
    /// 이미지 왼쪽 위 모서리(row 0, col 0)의 world 위치를 정렬 변환한 자리에 원점을 놓고
    /// yaw만큼 돌린 뒤 이미지를 그린다. 정렬 변환이 "회전 후 이동"이고 화면 y가 -z라,
    /// 화면 회전각은 yaw 그대로다(`ScanAlignment` 참고 -- 부호가 바뀌면 정렬 화면과
    /// 합치기 결과가 어긋난다).
    func drawFloorPlanLayer(_ layer: FloorPlanLayer, alignment: ScanAlignment, mapping: TopDownMapping, opacity: Double) {
        let topLeft = alignment.applyXZ(x: layer.meta.originX, z: layer.meta.originTopZ)
        let origin = mapping.point(x: topLeft.x, z: topLeft.z)
        let size = CGSize(
            width: CGFloat(layer.worldWidth) * mapping.scale,
            height: CGFloat(layer.worldDepth) * mapping.scale
        )
        drawLayer { inner in
            inner.translateBy(x: origin.x, y: origin.y)
            inner.rotate(by: Angle(radians: Double(alignment.yawRadians)))
            inner.opacity = opacity
            inner.draw(Image(uiImage: layer.image), in: CGRect(origin: .zero, size: size))
        }
    }

    func strokeFloorPlanOutline(_ layer: FloorPlanLayer, alignment: ScanAlignment, mapping: TopDownMapping, color: Color, lineWidth: CGFloat, dash: [CGFloat] = []) {
        let corners = layer.corners(with: alignment).map { mapping.point(x: $0.x, z: $0.z) }
        var outline = Path()
        outline.move(to: corners[0])
        for c in corners.dropFirst() { outline.addLine(to: c) }
        outline.closeSubpath()
        stroke(outline, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, dash: dash))
    }
}

import SwiftUI
import UIKit

/// 스캔 하나의 바닥 평면 이미지(floorplan.png) + 그 이미지의 world 좌표 매핑
/// (floorplan.json). 정렬 화면(ScanAlignmentView)과 위치 확인 화면(LocalizeView)이
/// 같이 쓴다 -- 둘 다 위에서 내려다본 world (x, z) 평면에 각 스캔의 바닥 평면을
/// 정렬 변환(`ScanAlignment`) 적용해 겹쳐 그린다.
///
/// 방향 관례: **화면 위 = -z, 오른쪽 = +x** -- ARKit world(+y 위, 오른손 좌표계)를
/// 실제로 위에서 내려다본 방향이다(카메라 시작 방향 -z가 위). 위 = +z로 두면 거울상이라
/// 실제로 왼쪽으로 돌 때 화면에선 오른쪽으로 도는 것처럼 보인다(2026-09-04 위치 확인
/// 화면에서 그렇게 보고돼 고침). floorplan.png는 row 0이 그 이미지의 가장 작은 z라
/// (FloorPlanRenderer, format_version 2) 뒤집지 않고 그대로 그리면 맞는다. 두 화면이
/// 같은 관례를 써야 정렬 화면에서 맞춘 모양 그대로 위치 확인 화면에 나온다.
struct FloorPlanLayer: Identifiable {
    let id: String
    let label: String
    /// 그리기용 -- 못 본 곳(회색)은 투명하게 뚫려 있어 겹쳐 그려도 밑 레이어가 비친다.
    let image: UIImage
    let meta: FloorPlanRenderer.PersistedMeta
    /// 자동 맞춤(ScanRegistration)용 벽 픽셀 중심 -- 이 스캔의 로컬 world (x, z), 최대
    /// `maxWallPoints`개. `load(forAlignment: true)`일 때만 채운다.
    let wallPointsXZ: [SIMD2<Float>]
    /// 정렬 화면이 역할별 틴트 이미지를 만들 때 쓴다. `load(forAlignment: true)`일 때만.
    let pixels: FloorPlanPixels?

    static let maxWallPoints = 6000

    init(id: String, label: String, image: UIImage, meta: FloorPlanRenderer.PersistedMeta,
         wallPointsXZ: [SIMD2<Float>] = [], pixels: FloorPlanPixels? = nil) {
        self.id = id
        self.label = label
        self.image = image
        self.meta = meta
        self.wallPointsXZ = wallPointsXZ
        self.pixels = pixels
    }

    var worldWidth: Float { Float(meta.widthPx) * meta.resolutionMetersPerPixel }
    var worldDepth: Float { Float(meta.heightPx) * meta.resolutionMetersPerPixel }

    /// 정렬 변환 적용 후 이미지 중심의 world (x, z) -- 회전 축으로 쓴다.
    func center(with alignment: ScanAlignment) -> (x: Float, z: Float) {
        alignment.applyXZ(x: meta.originX + worldWidth / 2, z: meta.originTopZ + worldDepth / 2)
    }

    /// 기준 좌표계의 (x, z)가 정렬 변환 적용된 이 이미지 사각형 안에 있는지.
    func contains(x: Float, z: Float, alignment: ScanAlignment) -> Bool {
        let local = alignment.inverseXZ(x: x, z: z)
        let u = local.x - meta.originX, v = local.z - meta.originTopZ
        return u >= 0 && u <= worldWidth && v >= 0 && v <= worldDepth
    }

    /// 벽을 `color`로, 바닥은 옅게, 못 본 곳은 투명하게 -- 정렬 화면용. 픽셀이 없으면
    /// (위치 확인용으로 로드) 그냥 `image`.
    func tintedImage(_ color: UIColor) -> UIImage {
        pixels?.tintedImage(color) ?? image
    }

    /// 정렬 변환 적용 후 이미지 네 모서리의 world (x, z) -- TL, TR, BR, BL 순서.
    func corners(with alignment: ScanAlignment) -> [(x: Float, z: Float)] {
        let x0 = meta.originX, z0 = meta.originTopZ
        let x1 = x0 + worldWidth, z1 = z0 + worldDepth
        return [(x0, z0), (x1, z0), (x1, z1), (x0, z1)].map { alignment.applyXZ(x: $0.0, z: $0.1) }
    }

    /// floorplan.png/floorplan.json이 둘 다 있어야 만들어진다(없는 스캔은 화면에
    /// 보여줄 게 없음). 파일 I/O + 픽셀 처리라 호출부가 백그라운드에서 부르는 게 좋다.
    /// `forAlignment`면 벽 점과 픽셀 버퍼(틴트용)까지 들고 있는다 -- 위치 확인 화면은
    /// 그게 필요 없어 메모리를 아낀다.
    static func load(scanID: String, label: String, folderURL: URL, forAlignment: Bool = false) -> FloorPlanLayer? {
        guard let meta = FloorPlanRenderer.PersistedMeta.load(from: folderURL),
              let raw = UIImage(contentsOfFile: folderURL.appendingPathComponent("floorplan.png").path)
        else { return nil }
        let pixels = FloorPlanPixels(image: raw)
        return FloorPlanLayer(
            id: scanID, label: label,
            image: pixels?.overlayImage() ?? raw, meta: meta,
            wallPointsXZ: forAlignment ? (pixels?.wallPointsXZ(meta: meta, maxPoints: maxWallPoints) ?? []) : [],
            pixels: forAlignment ? pixels : nil
        )
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

/// world (x, z) <-> 화면 좌표. 종횡비를 유지하고 가운데 정렬, 화면 위 = -z.
struct TopDownMapping {
    let scale: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
    let minX: Float
    let minZ: Float

    init(scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat, minX: Float, minZ: Float) {
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.minX = minX
        self.minZ = minZ
    }

    init(bounds: TopDownBounds, size: CGSize, fill: CGFloat = 0.9) {
        let b = bounds.isEmpty ? TopDownBounds(minX: -2, maxX: 2, minZ: -2, maxZ: 2) : bounds
        let spanX = max(b.maxX - b.minX, 0.5)
        let spanZ = max(b.maxZ - b.minZ, 0.5)
        scale = min(size.width / CGFloat(spanX), size.height / CGFloat(spanZ)) * fill
        offsetX = (size.width - CGFloat(spanX) * scale) / 2
        offsetY = (size.height - CGFloat(spanZ) * scale) / 2
        minX = b.minX
        minZ = b.minZ
    }

    func point(x: Float, z: Float) -> CGPoint {
        CGPoint(x: offsetX + CGFloat(x - minX) * scale, y: offsetY + CGFloat(z - minZ) * scale)
    }

    /// `point(x:z:)`의 역 -- 화면 좌표(터치 위치)를 world (x, z)로.
    func world(at point: CGPoint) -> (x: Float, z: Float) {
        (minX + Float((point.x - offsetX) / scale), minZ + Float((point.y - offsetY) / scale))
    }

    /// world 방향 벡터(x, z)를 화면 방향으로(정규화 안 함). 화면 y는 아래로 증가하고
    /// 화면 위 = -z라 z가 그대로 화면 y다.
    func direction(x: Float, z: Float) -> CGVector {
        CGVector(dx: CGFloat(x), dy: CGFloat(z))
    }

    /// 핀치 줌/팬을 얹은 매핑: screen = pan + zoom * (이 매핑의 screen).
    func zoomed(by zoom: CGFloat, pan: CGSize) -> TopDownMapping {
        TopDownMapping(
            scale: scale * zoom,
            offsetX: pan.width + zoom * offsetX,
            offsetY: pan.height + zoom * offsetY,
            minX: minX, minZ: minZ
        )
    }
}

extension GraphicsContext {
    /// 이미지 왼쪽 위 모서리(row 0, col 0)의 world 위치를 정렬 변환한 자리에 원점을 놓고
    /// yaw만큼 돌린 뒤 이미지를 그린다. `ScanAlignment`의 yaw는 +y축 기준 회전이라
    /// 위에서 내려다보면(화면 위 = -z, 오른쪽 = +x) 반시계 방향인데, 화면 좌표(y 아래)의
    /// rotate(by:)는 양수가 시계 방향이라 부호를 뒤집는다 -- 부호가 틀리면 정렬 화면과
    /// 합치기 결과가 어긋난다.
    ///
    /// `image`를 주면 레이어의 기본 이미지 대신 그걸 그린다(정렬 화면의 역할별 틴트 이미지
    /// -- 같은 픽셀 격자여야 한다).
    func drawFloorPlanLayer(
        _ layer: FloorPlanLayer, alignment: ScanAlignment, mapping: TopDownMapping, opacity: Double,
        image: UIImage? = nil
    ) {
        let topLeft = alignment.applyXZ(x: layer.meta.originX, z: layer.meta.originTopZ)
        let origin = mapping.point(x: topLeft.x, z: topLeft.z)
        let size = CGSize(
            width: CGFloat(layer.worldWidth) * mapping.scale,
            height: CGFloat(layer.worldDepth) * mapping.scale
        )
        drawLayer { inner in
            inner.translateBy(x: origin.x, y: origin.y)
            inner.rotate(by: Angle(radians: -Double(alignment.yawRadians)))
            inner.opacity = opacity
            inner.draw(Image(uiImage: image ?? layer.image), in: CGRect(origin: .zero, size: size))
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

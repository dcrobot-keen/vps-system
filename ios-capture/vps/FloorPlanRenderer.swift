import ARKit
import CoreGraphics
import UIKit

/// 스캔이 끝난 시점의 LiDAR mesh(ARMeshAnchor, 가능하면 classification 포함)에서
/// 바닥을 위에서 내려다본 2D 이미지를 뽑고, 그 위에 이번 세션에서 실제로 이동한
/// 카메라 경로(poses)를 겹쳐 그린다.
///
/// 색 관례는 scan-to-map-studio/studio/rasterize.py(OccupancyGrid, ROS map_server
/// 계열)와 일부러 맞췄다 -- free(바닥)=흰색, occupied(벽)=검정, unknown(못 본 곳)=회색,
/// resolution 단위는 m/px. 경로/마커 색은 scan-to-map-studio/studio/viewer_html.py의
/// 웹 뷰어와 같은 값(#3ba0ff/#ff3b3b)을 재사용한다 -- 다른 저장소의 뷰어와 나란히
/// 놓아도 같은 스캔으로 알아볼 수 있게.
///
/// VPS 길찾기 경로(pathfinder route) 오버레이는 vectorize된 그래프가 있어야 하는데
/// 그건 scan-to-map-studio 파이프라인 산출물이라 이 온디바이스 버전만으로는 못 만든다
/// -- PRODUCT-PLAN.md에 Phase 2(서버 왕복)로 분리해뒀다. 이번엔 poses.jsonl 기반
/// 실제 스캔 경로만 겹친다.
enum FloorPlanRenderer {
    struct Result {
        let image: UIImage
        let resolutionMetersPerPixel: Float
        /// 이미지 col 0(왼쪽 끝)에 대응하는 world-space X.
        let originX: Float
        /// 이미지 row 0(위쪽 끝)에 대응하는 world-space Z. row가 커질수록(아래로
        /// 갈수록) Z는 작아진다 -- `pixel(forWorldX:z:)` 참고.
        let originTopZ: Float
        let widthPx: Int
        let heightPx: Int

        /// world-space (x, z)를 이 이미지의 픽셀 좌표로 변환한다. Phase 2(VPS 경로
        /// 오버레이)가 같은 매핑으로 이 위에 더 그릴 수 있도록 공개해둔다.
        func pixel(forWorldX x: Float, z: Float) -> CGPoint {
            CGPoint(
                x: CGFloat((x - originX) / resolutionMetersPerPixel),
                y: CGFloat((originTopZ - z) / resolutionMetersPerPixel)
            )
        }
    }

    struct Triangle {
        let a: SIMD2<Float>
        let b: SIMD2<Float>
        let c: SIMD2<Float>
    }

    private static let resolution: Float = 0.05 // scan-to-map-studio rasterize.py 기본값과 동일
    private static let paddingMeters: Float = 0.5
    private static let maxDimensionPx = 4096
    // classification 미지원 기기용 폴백: 세션 전체 mesh vertex의 최저 높이(minY)로부터
    // 이 두께(m) 안의 삼각형만 바닥으로 본다. 그 외는 전부 벽 취급(가구/천장까지
    // 섞이는 대략치임을 감안한 타협).
    private static let heightFallbackBandMeters: Float = 0.15

    private static let freeColor = UIColor.white
    private static let occupiedColor = UIColor.black
    private static let unknownColor = UIColor(red: 205 / 255, green: 205 / 255, blue: 205 / 255, alpha: 1)
    private static let pathColor = UIColor(red: 0x3b / 255, green: 0xa0 / 255, blue: 0xff / 255, alpha: 1)
    private static let startMarkerColor = UIColor(red: 0x3b / 255, green: 0xd6 / 255, blue: 0x6b / 255, alpha: 1)
    private static let endMarkerColor = UIColor(red: 0xff / 255, green: 0x3b / 255, blue: 0x3b / 255, alpha: 1)

    // MARK: - ARKit 연동부 (테스트 불가 -- ARMeshAnchor는 XCTest에서 못 만듦)

    static func render(meshAnchors: [ARMeshAnchor], scanPathXZ: [SIMD2<Float>]) -> Result? {
        let hasClassification = meshAnchors.contains { $0.geometry.classification != nil }

        var minY = Float.greatestFiniteMagnitude
        if !hasClassification {
            for anchor in meshAnchors {
                for v in worldVertices(for: anchor) {
                    if v.y.isFinite { minY = min(minY, v.y) }
                }
            }
        }

        var floorTriangles: [Triangle] = []
        var wallTriangles: [Triangle] = []

        for anchor in meshAnchors {
            let worldVerts = worldVertices(for: anchor)
            let indices = faceIndices(for: anchor)
            guard !worldVerts.isEmpty, !indices.isEmpty else { continue }
            let classification = anchor.geometry.classification
            let triangleCount = indices.count / 3

            for t in 0..<triangleCount {
                let i0 = Int(indices[t * 3]), i1 = Int(indices[t * 3 + 1]), i2 = Int(indices[t * 3 + 2])
                guard i0 < worldVerts.count, i1 < worldVerts.count, i2 < worldVerts.count else { continue }
                let v0 = worldVerts[i0], v1 = worldVerts[i1], v2 = worldVerts[i2]

                let a = SIMD2<Float>(v0.x, v0.z), b = SIMD2<Float>(v1.x, v1.z), c = SIMD2<Float>(v2.x, v2.z)
                // ARKit mesh 경계/미완성 영역엔 NaN vertex가 섞여 나올 수 있다
                // (MeshExporter가 export 단계에서 이미 겪은 문제와 같은 종류) --
                // bounding box/rasterize 계산이 NaN에 오염되지 않도록 여기서 거른다.
                guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite, c.x.isFinite, c.y.isFinite else {
                    continue
                }

                let isFloor: Bool
                let isWall: Bool
                if hasClassification, let classification {
                    let value = ARMeshClassification(rawValue: classificationRawValue(classification, faceIndex: t))
                    isFloor = value == .floor
                    isWall = value == .wall
                } else {
                    let avgY = (v0.y + v1.y + v2.y) / 3
                    isFloor = avgY <= minY + heightFallbackBandMeters
                    isWall = !isFloor
                }

                guard isFloor || isWall else { continue }
                if isFloor {
                    floorTriangles.append(Triangle(a: a, b: b, c: c))
                } else {
                    wallTriangles.append(Triangle(a: a, b: b, c: c))
                }
            }
        }

        return rasterize(floorTriangles: floorTriangles, wallTriangles: wallTriangles, scanPathXZ: scanPathXZ)
    }

    /// ARMeshAnchor의 vertex를 world 좌표로 변환한다. MeshExporter.scnGeometry와 같은
    /// 안전한 바이트 단위 읽기 패턴(SIMD3<Float>가 메모리에서 16바이트로 정렬되는
    /// 반면 ARKit 버퍼는 12바이트 촘촘 포장이라, 곧바로 assumingMemoryBound(to:
    /// SIMD3<Float>.self)로 읽으면 마지막 원소에서 버퍼 밖을 읽을 위험이 있다).
    private static func worldVertices(for anchor: ARMeshAnchor) -> [SIMD3<Float>] {
        let vertexSource = anchor.geometry.vertices
        guard vertexSource.format == .float3, vertexSource.count > 0 else { return [] }

        var out = [SIMD3<Float>](repeating: .zero, count: vertexSource.count)
        let buffer = vertexSource.buffer.contents()
        for i in 0..<vertexSource.count {
            let base = buffer.advanced(by: vertexSource.offset + vertexSource.stride * i)
            let vx = base.load(fromByteOffset: 0, as: Float.self)
            let vy = base.load(fromByteOffset: 4, as: Float.self)
            let vz = base.load(fromByteOffset: 8, as: Float.self)
            let world = anchor.transform * SIMD4<Float>(vx, vy, vz, 1.0)
            out[i] = SIMD3<Float>(world.x, world.y, world.z)
        }
        return out
    }

    private static func faceIndices(for anchor: ARMeshAnchor) -> [UInt32] {
        let faceElement = anchor.geometry.faces
        guard faceElement.primitiveType == .triangle,
              faceElement.bytesPerIndex == MemoryLayout<UInt32>.size
        else { return [] }

        let indexCount = faceElement.count * 3
        guard indexCount > 0 else { return [] }
        var indices = [UInt32](repeating: 0, count: indexCount)
        let indexBuffer = faceElement.buffer.contents()
        for i in 0..<indexCount {
            let offset = faceElement.bytesPerIndex * i
            indices[i] = indexBuffer.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee
        }
        return indices
    }

    /// classification 소스에서 face index의 raw 분류값을 읽는다. format은 항상
    /// MTLVertexFormat.uchar(face당 1바이트) -- Apple의 ARKit 스캐닝 샘플 코드와
    /// 같은 읽기 방식(WebSearch로 확인, 2026-09-04).
    private static func classificationRawValue(_ source: ARGeometrySource, faceIndex: Int) -> Int {
        let address = source.buffer.contents().advanced(by: source.offset + source.stride * faceIndex)
        return Int(address.assumingMemoryBound(to: UInt8.self).pointee)
    }

    // MARK: - 순수 래스터화(ARKit 의존 없음 -- XCTest로 직접 검증 가능)

    /// world-space(x, z) 삼각형 목록(바닥/벽)과 스캔 경로를 받아 실제 이미지를 그린다.
    /// `render(meshAnchors:scanPathXZ:)`가 ARMeshAnchor에서 이 입력을 뽑아 호출한다.
    static func rasterize(
        floorTriangles: [Triangle], wallTriangles: [Triangle], scanPathXZ: [SIMD2<Float>]
    ) -> Result? {
        guard !floorTriangles.isEmpty || !wallTriangles.isEmpty else { return nil }

        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude
        for tri in floorTriangles + wallTriangles {
            for p in [tri.a, tri.b, tri.c] {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minZ = min(minZ, p.y); maxZ = max(maxZ, p.y)
            }
        }
        // 스캔 경로도 이미지 범위에 포함시킨다 -- 시작/끝 지점이 잘리면 오버레이
        // 의미가 없어진다(mesh 밖으로 나가는 경로는 드물지만 방어적으로).
        for p in scanPathXZ {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minZ = min(minZ, p.y); maxZ = max(maxZ, p.y)
        }

        minX -= paddingMeters; maxX += paddingMeters
        minZ -= paddingMeters; maxZ += paddingMeters

        var effectiveResolution = resolution
        var widthPx = max(Int(((maxX - minX) / effectiveResolution).rounded(.up)), 1)
        var heightPx = max(Int(((maxZ - minZ) / effectiveResolution).rounded(.up)), 1)
        if widthPx > maxDimensionPx || heightPx > maxDimensionPx {
            // 아주 넓은 공간(여러 방을 이어 찍은 경우)을 4096px 안에 담기 위해
            // 해상도(m/px)를 필요한 만큼만 낮춘다 -- 화질보다 "일단 하나의 이미지로
            // 나온다"가 우선.
            let scaleUp = Float(max(widthPx, heightPx)) / Float(maxDimensionPx)
            effectiveResolution *= scaleUp
            widthPx = max(Int(((maxX - minX) / effectiveResolution).rounded(.up)), 1)
            heightPx = max(Int(((maxZ - minZ) / effectiveResolution).rounded(.up)), 1)
        }

        // 이미지 좌표계: col = (x - minX)/res, row = (maxZ - z)/res (이미지 위쪽 =
        // -Z 방향). 나침반 기준 방향은 아니지만 렌더링 내내 이 한 매핑만 쓰므로
        // 바닥/벽/경로가 항상 같은 자리에 겹친다.
        func pixel(_ world: SIMD2<Float>) -> CGPoint {
            CGPoint(
                x: CGFloat((world.x - minX) / effectiveResolution),
                y: CGFloat((maxZ - world.y) / effectiveResolution)
            )
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let imageSize = CGSize(width: CGFloat(widthPx), height: CGFloat(heightPx))
        let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)

        let image = renderer.image { rendererContext in
            let cg = rendererContext.cgContext

            unknownColor.setFill()
            cg.fill(CGRect(origin: .zero, size: imageSize))

            freeColor.setFill()
            for tri in floorTriangles { fillTriangle(tri, in: cg, pixel: pixel) }

            occupiedColor.setFill()
            occupiedColor.setStroke()
            cg.setLineWidth(2)
            cg.setLineJoin(.round)
            cg.setLineCap(.round)
            for tri in wallTriangles {
                // 벽 mesh 삼각형은 거의 수직이라 위에서 보면 폭이 거의 0인 선에
                // 가깝다 -- fill만으로는 면적이 0에 가까워 안 보일 수 있어 테두리도
                // 같이 그어 항상 보이게 한다.
                fillTriangle(tri, in: cg, pixel: pixel)
                strokeTriangleEdges(tri, in: cg, pixel: pixel)
            }

            if scanPathXZ.count >= 2 {
                pathColor.setStroke()
                cg.setLineWidth(3)
                cg.setLineJoin(.round)
                cg.setLineCap(.round)
                let path = CGMutablePath()
                path.move(to: pixel(scanPathXZ[0]))
                for p in scanPathXZ.dropFirst() { path.addLine(to: pixel(p)) }
                cg.addPath(path)
                cg.strokePath()
            }
            if let last = scanPathXZ.last, scanPathXZ.count >= 2 {
                drawMarker(at: pixel(last), color: endMarkerColor, in: cg)
            }
            if let first = scanPathXZ.first {
                drawMarker(at: pixel(first), color: startMarkerColor, in: cg)
            }
        }

        return Result(
            image: image,
            resolutionMetersPerPixel: effectiveResolution,
            originX: minX,
            originTopZ: maxZ,
            widthPx: widthPx,
            heightPx: heightPx
        )
    }

    private static func fillTriangle(_ tri: Triangle, in ctx: CGContext, pixel: (SIMD2<Float>) -> CGPoint) {
        let path = CGMutablePath()
        path.move(to: pixel(tri.a))
        path.addLine(to: pixel(tri.b))
        path.addLine(to: pixel(tri.c))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
    }

    private static func strokeTriangleEdges(_ tri: Triangle, in ctx: CGContext, pixel: (SIMD2<Float>) -> CGPoint) {
        let path = CGMutablePath()
        path.move(to: pixel(tri.a))
        path.addLine(to: pixel(tri.b))
        path.addLine(to: pixel(tri.c))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.strokePath()
    }

    private static func drawMarker(at point: CGPoint, color: UIColor, in ctx: CGContext) {
        let radius: CGFloat = 6
        color.setFill()
        ctx.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }
}

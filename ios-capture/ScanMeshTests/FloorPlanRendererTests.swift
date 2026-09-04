import CoreGraphics
import UIKit
import XCTest
@testable import vps

/// FloorPlanRenderer.rasterize()만 검증한다 -- render(meshAnchors:scanPathXZ:)는
/// ARMeshAnchor에 의존해서 XCTest에서 만들 수 없다(ScanRecordBuilder를 ARFrame에서
/// 분리한 것과 같은 이유). world-space (x, z) 삼각형 + 경로 좌표만 받는 순수
/// 래스터화 함수 쪽에서 색 관례(바닥=흰색, 벽=검정, 미확인=회색, 경로=파랑,
/// 시작/끝 마커)와 좌표 매핑, 큰 스캔에서의 해상도 자동 하향까지 확인한다.
final class FloorPlanRendererTests: XCTestCase {
    /// image pixel (x, y)의 색을 UIKit 좌표계(top-left origin, y down -- rasterize()의
    /// pixel() 매핑과 동일)로 정확히 읽는다. UIImage.draw(at:)로 그 픽셀 하나를
    /// 1x1 렌더러 좌상단에 오도록 옮겨 그린 뒤, 알려진 RGBA8888 레이아웃의
    /// CGContext로 다시 그려서 원본 CGImage의 실제 비트맵 포맷(플랫폼/버전마다
    /// 다를 수 있음)에 관계없이 항상 같은 바이트 순서로 읽는다.
    private func pixelColor(in image: UIImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let cropped = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in
            image.draw(at: CGPoint(x: -CGFloat(x), y: -CGFloat(y)))
        }
        guard let cgImage = cropped.cgImage else {
            XCTFail("cropped image has no cgImage")
            return (0, 0, 0)
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("failed to create sampling context")
            return (0, 0, 0)
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixel[0], pixel[1], pixel[2])
    }

    func testFloorTriangleRendersWhiteAndBackgroundStaysGray() throws {
        // (0,0)-(2,0)-(0,2) 직각삼각형. padding 0.5m + resolution 0.05m/px 기준으로
        // bbox는 [-0.5, 2.5] x [-0.5, 2.5] -> 60x60px.
        let floor = FloorPlanRenderer.Triangle(
            a: SIMD2(0, 0), b: SIMD2(2, 0), c: SIMD2(0, 2)
        )
        let result = try XCTUnwrap(
            FloorPlanRenderer.rasterize(floorTriangles: [floor], wallTriangles: [], scanPathXZ: [])
        )
        XCTAssertEqual(result.widthPx, 60)
        XCTAssertEqual(result.heightPx, 60)

        // (0.3, 0.3)는 삼각형 내부 깊숙히(가장자리에서 6px 이상 떨어짐) -> 흰색.
        let inside = pixelColor(in: result.image, x: 16, y: 44)
        XCTAssertGreaterThan(inside.r, 240)
        XCTAssertGreaterThan(inside.g, 240)
        XCTAssertGreaterThan(inside.b, 240)

        // (-0.4, 2.4)는 padding 영역(삼각형 밖) -> 미확인(회색 205).
        let background = pixelColor(in: result.image, x: 2, y: 2)
        XCTAssertTrue((195...215).contains(Int(background.r)))
        XCTAssertEqual(background.r, background.g)
        XCTAssertEqual(background.g, background.b)
    }

    func testWallTriangleRendersBlack() throws {
        let wall = FloorPlanRenderer.Triangle(
            a: SIMD2(3, 3), b: SIMD2(3.2, 3), c: SIMD2(3, 3.2)
        )
        let result = try XCTUnwrap(
            FloorPlanRenderer.rasterize(floorTriangles: [], wallTriangles: [wall], scanPathXZ: [])
        )
        // (3.05, 3.05)는 이 작은 삼각형 내부.
        let inside = pixelColor(in: result.image, x: 11, y: 13)
        XCTAssertLessThan(inside.r, 60)
        XCTAssertLessThan(inside.g, 60)
        XCTAssertLessThan(inside.b, 60)
    }

    func testScanPathOverlayIsBlueWithStartAndEndMarkers() throws {
        // 바닥 하나(0,0)-(10,0)-(0,10) 위에 (1,1)->(5,5) 대각선 경로를 겹친다.
        let floor = FloorPlanRenderer.Triangle(
            a: SIMD2(0, 0), b: SIMD2(10, 0), c: SIMD2(0, 10)
        )
        let path: [SIMD2<Float>] = [SIMD2(1, 1), SIMD2(5, 5)]
        let result = try XCTUnwrap(
            FloorPlanRenderer.rasterize(floorTriangles: [floor], wallTriangles: [], scanPathXZ: path)
        )

        // 경로의 중점(3,3)은 (1,1)-(5,5) 직선 위 -> 파란 스트로크가 지나가야 한다.
        let midPoint = result.pixel(forWorldX: 3, z: 3)
        let onPath = pixelColor(in: result.image, x: Int(midPoint.x), y: Int(midPoint.y))
        XCTAssertGreaterThan(Int(onPath.b), Int(onPath.r) + 50, "경로 색은 파랑이 빨강보다 뚜렷이 커야 함")

        // 시작점(1,1)은 초록 마커.
        let startPoint = result.pixel(forWorldX: 1, z: 1)
        let start = pixelColor(in: result.image, x: Int(startPoint.x), y: Int(startPoint.y))
        XCTAssertGreaterThan(Int(start.g), Int(start.r) + 50, "시작 마커는 초록이 빨강보다 뚜렷이 커야 함")

        // 끝점(5,5)은 빨강 마커.
        let endPoint = result.pixel(forWorldX: 5, z: 5)
        let end = pixelColor(in: result.image, x: Int(endPoint.x), y: Int(endPoint.y))
        XCTAssertGreaterThan(Int(end.r), Int(end.g) + 50, "끝 마커는 빨강이 초록보다 뚜렷이 커야 함")
    }

    func testHugeExtentDownscalesToStayWithinMaxDimension() throws {
        let floor = FloorPlanRenderer.Triangle(
            a: SIMD2(0, 0), b: SIMD2(1000, 0), c: SIMD2(0, 1000)
        )
        let result = try XCTUnwrap(
            FloorPlanRenderer.rasterize(floorTriangles: [floor], wallTriangles: [], scanPathXZ: [])
        )
        XCTAssertLessThanOrEqual(result.widthPx, 4096)
        XCTAssertLessThanOrEqual(result.heightPx, 4096)
        XCTAssertGreaterThan(result.resolutionMetersPerPixel, 0.05, "다운스케일됐으면 실제 해상도(m/px)는 기본값보다 커야 함")
    }

    func testFloorPatchesFiltersOnlyFacesWithinHeightBand() throws {
        // face 0: 세 정점 모두 y=0.05 (바닥 높이 대역 [-0.03, 0.13] 안). face 1:
        // y=1.0 (분명히 밖) -- 텍스처 베이킹은 classification 없이 재로드한 mesh를
        // 쓰므로, 높이만으로 "이건 바닥이었을 face"를 다시 골라내야 한다.
        let positions: [SIMD3<Float>] = [
            SIMD3(0, 0.05, 0), SIMD3(1, 0.05, 0), SIMD3(0, 0.05, 1),
            SIMD3(5, 1.0, 5), SIMD3(6, 1.0, 5), SIMD3(5, 1.0, 6),
        ]
        let indices: [UInt32] = [0, 1, 2, 3, 4, 5]
        let faceColors: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0)]

        let patches = FloorPlanRenderer.floorPatches(
            positions: positions, indices: indices, faceColors: faceColors,
            floorHeightMin: 0.0, floorHeightMax: 0.1
        )

        XCTAssertEqual(patches.count, 1)
        let patch = try XCTUnwrap(patches.first)
        XCTAssertEqual(patch.triangle.a, SIMD2(0, 0))
        XCTAssertEqual(patch.triangle.b, SIMD2(1, 0))
        XCTAssertEqual(patch.triangle.c, SIMD2(0, 1))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        patch.color.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(Double(r), 1, accuracy: 0.01)
        XCTAssertEqual(Double(g), 0, accuracy: 0.01)
        XCTAssertEqual(Double(b), 0, accuracy: 0.01)
    }

    func testRecolorFloorPaintsPatchWithoutDisturbingWallOrBackground() throws {
        let floor = FloorPlanRenderer.Triangle(a: SIMD2(0, 0), b: SIMD2(2, 0), c: SIMD2(0, 2))
        let base = try XCTUnwrap(
            FloorPlanRenderer.rasterize(floorTriangles: [floor], wallTriangles: [], scanPathXZ: [])
        )

        // 바닥 삼각형의 왼쪽 아래 구석만 덮는 작은 패치를 빨강으로 칠한다.
        let patch = FloorPlanRenderer.Triangle(a: SIMD2(0.1, 0.1), b: SIMD2(0.9, 0.1), c: SIMD2(0.1, 0.9))
        let recolored = FloorPlanRenderer.recolorFloor(
            baseImage: base.image,
            floorPatches: [(patch, .red)],
            resolutionMetersPerPixel: base.resolutionMetersPerPixel,
            originX: base.originX, originTopZ: base.originTopZ,
            scanPathXZ: []
        )

        // (0.3, 0.3)는 패치 안 -> 빨강.
        let insidePatch = pixelColor(in: recolored, x: 16, y: 44)
        XCTAssertGreaterThan(Int(insidePatch.r), Int(insidePatch.g) + 100)

        // (1.5, 0.3)은 원래 바닥(흰색)이지만 패치 밖 -> 그대로 흰색.
        let outsidePatch = pixelColor(in: recolored, x: 40, y: 44)
        XCTAssertGreaterThan(outsidePatch.r, 240)
        XCTAssertGreaterThan(outsidePatch.g, 240)
        XCTAssertGreaterThan(outsidePatch.b, 240)

        // (-0.4, 2.4)는 배경(회색) -> 그대로 회색.
        let background = pixelColor(in: recolored, x: 2, y: 2)
        XCTAssertTrue((195...215).contains(Int(background.r)))
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(FloorPlanRenderer.rasterize(floorTriangles: [], wallTriangles: [], scanPathXZ: []))
        // 경로만 있고 바닥/벽이 하나도 없으면 "겹쳐 그릴 바닥 자체가 없다"는 뜻이라
        // 역시 nil -- 의도된 동작임을 테스트로 고정해둔다.
        XCTAssertNil(
            FloorPlanRenderer.rasterize(
                floorTriangles: [], wallTriangles: [], scanPathXZ: [SIMD2(0, 0), SIMD2(1, 1)]
            )
        )
    }
}

import UIKit
import XCTest
@testable import vps

/// FloorPlanPixels -- floorplan.png 픽셀 분류(벽/미확인/기타), 벽 점 추출, 투명/틴트 이미지.
/// 입력은 FloorPlanRenderer.rasterize()로 직접 만든 이미지라 색 관례가 렌더러와 어긋나면
/// 여기서 잡힌다.
final class FloorPlanPixelsTests: XCTestCase {
    /// 바닥 (0,0)-(2,0)-(0,2) + 작은 벽 (1.5,1.5)-(1.7,1.5)-(1.5,1.7). bbox [-0.5, 2.5]^2 -> 60x60px.
    private func makeSample() throws -> (FloorPlanRenderer.Result, FloorPlanPixels) {
        let floor = FloorPlanRenderer.Triangle(a: SIMD2(0, 0), b: SIMD2(2, 0), c: SIMD2(0, 2))
        let wall = FloorPlanRenderer.Triangle(a: SIMD2(1.5, 1.5), b: SIMD2(1.7, 1.5), c: SIMD2(1.5, 1.7))
        let result = try XCTUnwrap(
            FloorPlanRenderer.rasterize(floorTriangles: [floor], wallTriangles: [wall], scanPathXZ: [])
        )
        let pixels = try XCTUnwrap(FloorPlanPixels(image: result.image))
        return (result, pixels)
    }

    private func meta(for result: FloorPlanRenderer.Result) -> FloorPlanRenderer.PersistedMeta {
        FloorPlanRenderer.PersistedMeta(
            resolutionMetersPerPixel: result.resolutionMetersPerPixel,
            originX: result.originX, originTopZ: result.originTopZ,
            widthPx: result.widthPx, heightPx: result.heightPx,
            floorHeightMin: nil, floorHeightMax: nil
        )
    }

    func testClassifiesWallFloorAndUnknown() throws {
        let (result, pixels) = try makeSample()
        XCTAssertEqual(pixels.width, result.widthPx)
        XCTAssertEqual(pixels.height, result.heightPx)

        let wall = result.pixel(forWorldX: 1.55, z: 1.55)
        XCTAssertEqual(pixels.kind(col: Int(wall.x), row: Int(wall.y)), .wall)

        let floor = result.pixel(forWorldX: 0.3, z: 0.3)
        XCTAssertEqual(pixels.kind(col: Int(floor.x), row: Int(floor.y)), .other)

        let outside = result.pixel(forWorldX: -0.4, z: 2.4)
        XCTAssertEqual(pixels.kind(col: Int(outside.x), row: Int(outside.y)), .unknown)

        XCTAssertEqual(pixels.kind(col: -1, row: 0), .unknown, "범위 밖은 미확인")
    }

    func testWallPointsLieOnTheWallInWorldCoordinates() throws {
        let (result, pixels) = try makeSample()
        let points = pixels.wallPointsXZ(meta: meta(for: result), maxPoints: 10_000)
        XCTAssertFalse(points.isEmpty)
        for p in points {
            // 벽 삼각형(테두리 2px 스트로크 포함) 근처여야 한다.
            XCTAssertGreaterThan(p.x, 1.3)
            XCTAssertLessThan(p.x, 1.9)
            XCTAssertGreaterThan(p.y, 1.3)
            XCTAssertLessThan(p.y, 1.9)
        }

        let capped = pixels.wallPointsXZ(meta: meta(for: result), maxPoints: 5)
        XCTAssertLessThanOrEqual(capped.count, 5)
        XCTAssertGreaterThan(capped.count, 0)
    }

    func testOverlayAndTintedImagesKeepPixelGrid() throws {
        let (result, pixels) = try makeSample()
        let overlay = try XCTUnwrap(pixels.overlayImage())
        XCTAssertEqual(Int(overlay.size.width * overlay.scale), result.widthPx)
        XCTAssertEqual(Int(overlay.size.height * overlay.scale), result.heightPx)

        let tinted = try XCTUnwrap(pixels.tintedImage(UIColor(red: 1, green: 0.62, blue: 0.15, alpha: 1)))
        XCTAssertEqual(Int(tinted.size.width * tinted.scale), result.widthPx)

        // 틴트 이미지의 벽 픽셀은 틴트 색(주황: 빨강 >> 파랑), 미확인 픽셀은 투명.
        let wall = result.pixel(forWorldX: 1.55, z: 1.55)
        let wallColor = rgba(in: tinted, x: Int(wall.x), y: Int(wall.y))
        XCTAssertGreaterThan(Int(wallColor.r), Int(wallColor.b) + 100)
        XCTAssertEqual(wallColor.a, 255)

        let outside = result.pixel(forWorldX: -0.4, z: 2.4)
        XCTAssertEqual(rgba(in: tinted, x: Int(outside.x), y: Int(outside.y)).a, 0)
        XCTAssertEqual(rgba(in: overlay, x: Int(outside.x), y: Int(outside.y)).a, 0)

        // 바닥은 옅은 틴트(alpha 70).
        let floor = result.pixel(forWorldX: 0.3, z: 0.3)
        let floorColor = rgba(in: tinted, x: Int(floor.x), y: Int(floor.y))
        XCTAssertGreaterThan(floorColor.a, 40)
        XCTAssertLessThan(floorColor.a, 120)
    }

    /// 픽셀 하나를 premultipliedLast RGBA로 읽는다(FloorPlanRendererTests.pixelColor와
    /// 같은 방식이되 alpha까지 -- 투명 검사용이라 배경을 안 깔고 직접 CGImage를 그린다).
    private func rgba(in image: UIImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard let cg = image.cgImage else {
            XCTFail("no cgImage")
            return (0, 0, 0, 0)
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("no context")
            return (0, 0, 0, 0)
        }
        // 1x1 컨텍스트에 이미지를 (-x, -(h-1-y)) 만큼 밀어 그리면 원하는 픽셀이 (0,0)에 온다
        // (CG 좌표는 아래가 원점).
        ctx.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }
}

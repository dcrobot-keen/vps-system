import CoreGraphics
import UIKit
import XCTest
@testable import vps

/// 정렬 화면과 위치 확인 화면이 같이 쓰는 위에서 내려다본 2D 매핑(FloorPlanLayer.swift)의
/// 방향 관례를 고정한다: 화면 위 = -z, 오른쪽 = +x. 위 = +z로 두면 거울상이라 실제로
/// 왼쪽으로 돌 때 화살표가 오른쪽으로 돌았다(2026-09-04 실기 보고).
final class TopDownMappingTests: XCTestCase {
    private func makeMapping() -> TopDownMapping {
        var bounds = TopDownBounds()
        bounds.include(x: 0, z: 0)
        bounds.include(x: 4, z: 4)
        return TopDownMapping(bounds: bounds, size: CGSize(width: 100, height: 100), fill: 1)
    }

    func testPlusXIsScreenRightAndPlusZIsScreenDown() {
        let mapping = makeMapping()
        let origin = mapping.point(x: 0, z: 0)
        XCTAssertGreaterThan(mapping.point(x: 1, z: 0).x, origin.x)
        XCTAssertEqual(mapping.point(x: 1, z: 0).y, origin.y, accuracy: 1e-6)
        XCTAssertGreaterThan(mapping.point(x: 0, z: 1).y, origin.y)
        XCTAssertEqual(mapping.point(x: 0, z: 1).x, origin.x, accuracy: 1e-6)
    }

    func testCameraStartHeadingPointsUp() {
        // ARKit 카메라는 처음에 -z를 본다 -> 화면 위.
        let d = makeMapping().direction(x: 0, z: -1)
        XCTAssertEqual(d.dx, 0, accuracy: 1e-6)
        XCTAssertLessThan(d.dy, 0)
    }

    func testTurningLeftMovesArrowLeft() {
        // +y축 기준 +yaw 회전은 위에서 봤을 때 반시계 = 왼쪽으로 돌기. 시작 전방
        // (0, -1)을 ScanAlignment와 같은 공식으로 돌리면 (-sin, -cos).
        let yaw: Float = 0.3
        let forward = ScanAlignment(offsetX: 0, offsetZ: 0, yawRadians: yaw).rotateXZ(x: 0, z: -1)
        let d = makeMapping().direction(x: forward.x, z: forward.z)
        XCTAssertLessThan(d.dx, 0, "왼쪽으로 돌면 화살표도 화면 왼쪽으로")
        XCTAssertLessThan(d.dy, 0, "아직 대체로 위를 향함")
    }

    func testWorldAtInvertsPointAndSurvivesZoom() {
        let mapping = makeMapping().zoomed(by: 2.5, pan: CGSize(width: 30, height: -12))
        let p = mapping.point(x: 1.25, z: 3.5)
        let back = mapping.world(at: p)
        XCTAssertEqual(back.x, 1.25, accuracy: 1e-4)
        XCTAssertEqual(back.z, 3.5, accuracy: 1e-4)

        // zoomed(): screen = pan + zoom * base
        let base = makeMapping().point(x: 1.25, z: 3.5)
        XCTAssertEqual(p.x, 30 + 2.5 * base.x, accuracy: 1e-4)
        XCTAssertEqual(p.y, -12 + 2.5 * base.y, accuracy: 1e-4)
    }

    func testLayerContainsUsesAlignedRectangle() {
        let meta = FloorPlanRenderer.PersistedMeta(
            resolutionMetersPerPixel: 0.5, originX: 0, originTopZ: 0,
            widthPx: 4, heightPx: 2, floorHeightMin: nil, floorHeightMax: nil
        )
        let layer = FloorPlanLayer(id: "s", label: "s", image: UIImage(), meta: meta)
        XCTAssertTrue(layer.contains(x: 1, z: 0.5, alignment: .identity))
        XCTAssertFalse(layer.contains(x: 1, z: 1.5, alignment: .identity))
        let shifted = ScanAlignment(offsetX: 10, offsetZ: 10, yawRadians: 0)
        XCTAssertFalse(layer.contains(x: 1, z: 0.5, alignment: shifted))
        XCTAssertTrue(layer.contains(x: 11, z: 10.5, alignment: shifted))
        let center = layer.center(with: shifted)
        XCTAssertEqual(center.x, 11, accuracy: 1e-5)
        XCTAssertEqual(center.z, 10.5, accuracy: 1e-5)
    }

    func testLayerCornersRunTopLeftToBottomRightOnScreen() {
        // floorplan.png row 0 = 최소 z(이미지 위). 정렬 없이 모서리를 화면에 놓으면
        // TL이 왼쪽 위, BR이 오른쪽 아래여야 이미지를 뒤집지 않고 그대로 그릴 수 있다.
        let meta = FloorPlanRenderer.PersistedMeta(
            resolutionMetersPerPixel: 0.5, originX: 0, originTopZ: 0,
            widthPx: 4, heightPx: 2, floorHeightMin: nil, floorHeightMax: nil
        )
        let layer = FloorPlanLayer(id: "s", label: "s", image: UIImage(), meta: meta)
        let corners = layer.corners(with: .identity)
        XCTAssertEqual(corners.count, 4)
        XCTAssertEqual(corners[0].z, 0, accuracy: 1e-6)
        XCTAssertEqual(corners[2].x, 2, accuracy: 1e-6)
        XCTAssertEqual(corners[2].z, 1, accuracy: 1e-6, "아래 모서리가 더 큰 z")

        let mapping = makeMapping()
        let tl = mapping.point(x: corners[0].x, z: corners[0].z)
        let br = mapping.point(x: corners[2].x, z: corners[2].z)
        XCTAssertLessThan(tl.x, br.x)
        XCTAssertLessThan(tl.y, br.y)
    }
}

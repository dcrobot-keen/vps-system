import XCTest
@testable import vps

/// TexturedGroupMerger -- 스캔별 textured.glb를 정렬 변환/바닥 높이 적용해 GLB 하나로.
/// TextureBaker(Metal)는 테스트에서 못 돌리므로 textured.glb는 GLBWriter로 직접 만들고
/// `bakeMissing: false`로 합친다.
final class TexturedGroupMergerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 삼각형 하나짜리 textured.glb + floor_height_min을 가진 floorplan.json이 있는 스캔 폴더.
    private func makeScanFolder(named name: String, floorY: Float, textured: Bool = true) throws -> URL {
        let folder = root.appendingPathComponent("scan_\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meta: [String: Any] = [
            "format_version": FloorPlanRenderer.formatVersion,
            "resolution_meters_per_pixel": 0.05, "origin_x": 0.0, "origin_top_z": 0.0,
            "width_px": 4, "height_px": 4, "floor_height_min": Double(floorY), "floor_height_max": Double(floorY) + 0.1,
        ]
        try JSONSerialization.data(withJSONObject: meta).write(to: folder.appendingPathComponent("floorplan.json"))
        if textured {
            let png = try XCTUnwrap(GLBWriter.encodePNG(rgba: [10, 20, 30, 255], width: 1, height: 1))
            try GLBWriter.write(
                primitives: [GLBWriter.Primitive(
                    positions: [0, 0, 0, 1, 0, 0, 0, 0, 1], normals: [0, 1, 0, 0, 1, 0, 0, 1, 0],
                    uvs: [0, 0, 1, 0, 0, 1], indices: nil, imageData: png, imageMimeType: "image/png"
                )],
                to: folder.appendingPathComponent("textured.glb")
            )
        }
        return folder
    }

    func testMergeAppliesAlignmentAndFloorOffsetAndKeepsTextures() throws {
        let reference = try makeScanFolder(named: "a", floorY: -1.0)
        let second = try makeScanFolder(named: "b", floorY: -1.5)
        let alignment = ScanAlignment(offsetX: 10, offsetZ: -2, yawRadians: .pi / 2)
        let output = root.appendingPathComponent("merged.glb")

        let summary = try TexturedGroupMerger.merge(
            scans: [
                ScanGroupMerger.ScanInput(folderURL: reference, alignment: .identity),
                ScanGroupMerger.ScanInput(folderURL: second, alignment: alignment),
            ],
            to: output, bakeMissing: false
        )
        XCTAssertEqual(summary.texturedScanCount, 2)
        XCTAssertEqual(summary.skippedScanCount, 0)

        let raws = try GLBLoader.loadPrimitives(at: output)
        XCTAssertEqual(raws.count, 2)
        // 기준 스캔은 그대로.
        XCTAssertEqual(raws[0].positions[1], SIMD3(1, 0, 0))
        // 두 번째: (1,0,0) -> yaw 90도 회전 (0,0,-1) + offset (10, -2) = (10, 0, -3), 바닥 높이 차 +0.5.
        let moved = raws[1].positions[1]
        XCTAssertEqual(moved.x, 10, accuracy: 1e-4)
        XCTAssertEqual(moved.y, 0.5, accuracy: 1e-4)
        XCTAssertEqual(moved.z, -3, accuracy: 1e-4)
        // normal은 회전만(y 그대로).
        XCTAssertEqual(try XCTUnwrap(raws[1].normals)[0], SIMD3(0, 1, 0))
        XCTAssertNotNil(raws[1].imageData)
        XCTAssertNil(raws[1].indices)
    }

    func testScansWithoutTexturedGLBAreSkippedWhenNotBaking() throws {
        let reference = try makeScanFolder(named: "a", floorY: -1.0)
        let bare = try makeScanFolder(named: "c", floorY: -1.0, textured: false)
        let output = root.appendingPathComponent("merged.glb")
        let summary = try TexturedGroupMerger.merge(
            scans: [
                ScanGroupMerger.ScanInput(folderURL: reference, alignment: .identity),
                ScanGroupMerger.ScanInput(folderURL: bare, alignment: .identity),
            ],
            to: output, bakeMissing: false
        )
        XCTAssertEqual(summary.texturedScanCount, 1)
        XCTAssertEqual(summary.skippedScanCount, 1)
        XCTAssertEqual(try GLBLoader.loadPrimitives(at: output).count, 1)
    }

    func testNoTexturedScansThrows() throws {
        let bare = try makeScanFolder(named: "c", floorY: -1.0, textured: false)
        XCTAssertThrowsError(try TexturedGroupMerger.merge(
            scans: [ScanGroupMerger.ScanInput(folderURL: bare, alignment: .identity)],
            to: root.appendingPathComponent("merged.glb"), bakeMissing: false
        ))
    }
}

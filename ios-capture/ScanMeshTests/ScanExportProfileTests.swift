import XCTest
@testable import vps

/// 지도용 export 프로파일이 정확히 지도 파이프라인이 읽는 파일만 남기고, VPS 프레임
/// (rgb/depth)과 뷰어용 대용량(textured.glb, worldmap)을 빼는지 고정한다.
final class ScanExportProfileTests: XCTestCase {
    private let sample = [
        "manifest.json", "poses/poses.jsonl", "scan.usdz", "floorplan.png", "floorplan.json",
        "rgb/frame_00001.jpg", "rgb/frame_00752.jpg",
        "depth/frame_00001.depth", "depth/frame_00001.conf",
        "textured.glb", "worldmap.arexperience",
    ]

    func testFullKeepsEverything() {
        XCTAssertTrue(sample.allSatisfy { ScanExportProfile.full.includes(relativePath: $0) })
        XCTAssertNil(ScanExportProfile.full.zipFilter)
    }

    func testMapKeepsOnlyWhatTheMapPipelineReads() throws {
        let kept = sample.filter { ScanExportProfile.map.includes(relativePath: $0) }
        XCTAssertEqual(Set(kept), ["manifest.json", "poses/poses.jsonl", "scan.usdz", "floorplan.png", "floorplan.json"])
        let filter = try XCTUnwrap(ScanExportProfile.map.zipFilter)
        XCTAssertFalse(filter("rgb/frame_00001.jpg"))
        XCTAssertFalse(filter("depth/frame_00001.conf"))
        XCTAssertFalse(filter("textured.glb"))
        XCTAssertTrue(filter("scan.usdz"))
    }

    func testLabelsAreDistinct() {
        XCTAssertNotEqual(ScanExportProfile.full.label, ScanExportProfile.map.label)
    }
}

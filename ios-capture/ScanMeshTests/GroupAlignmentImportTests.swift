import XCTest
@testable import vps

/// 데스크탑이 확정한 group_alignment.json을 앱이 되돌려 읽는 경로(GroupAlignmentImport).
/// export -> import 왕복이 값을 그대로 보존해야 하고, 다른 프로젝트의 파일은 거부해야 한다.
final class GroupAlignmentImportTests: XCTestCase {
    private func makeGroup() -> ScanGroup {
        ScanGroup(id: "G1", name: "집", scanIDs: ["scan_A", "scan_B", "scan_C"], createdAt: Date(timeIntervalSince1970: 0),
                  alignments: ["scan_B": ScanAlignment(offsetX: 1, offsetZ: -2, yawRadians: 0.3)])
    }

    func testExportThenImportRoundTripsAlignments() throws {
        let group = makeGroup()
        let data = try XCTUnwrap(GroupAlignmentExport.data(for: group))
        let r = try GroupAlignmentImport.parse(data, group: group)
        XCTAssertEqual(r.reference, "scan_A")
        XCTAssertEqual(r.alignments["scan_B"], group.alignments["scan_B"])
        XCTAssertEqual(r.alignments["scan_C"], .identity)  // exported as identity, comes back as identity
        XCTAssertEqual(r.skipped, [])
        XCTAssertEqual(r.methods["scan_B"], "app")
    }

    func testDesktopFileWithMethodsMetricsAndApproval() throws {
        let json = """
        {"format":"scan-group-alignment-v1","group":"집","reference":"scan_A","up_axis_convention":"top = -z",
         "alignments":{"scan_B":{"offsetX":0.096,"offsetZ":-0.296,"yawRadians":0.7974,"method":"icp",
                                  "metrics":{"overlap_m":17.0,"inlier":0.81,"conflict":0.01},"approved":true,"approved_at":"2026-09-05T11:27:00+09:00"},
                       "scan_Z":{"offsetX":9,"offsetZ":9,"yawRadians":0,"method":"manual"}}}
        """
        let r = try GroupAlignmentImport.parse(Data(json.utf8), group: makeGroup())
        XCTAssertEqual(r.alignments.count, 1)
        XCTAssertEqual(r.alignments["scan_B"]?.yawRadians ?? 0, 0.7974, accuracy: 1e-6)
        XCTAssertEqual(r.methods["scan_B"], "icp")
        XCTAssertEqual(r.skipped, ["scan_Z"])
    }

    func testRejectsOtherProjectsAndForeignFiles() {
        let other = Data("""
        {"format":"scan-group-alignment-v1","reference":"scan_X","alignments":{}}
        """.utf8)
        XCTAssertThrowsError(try GroupAlignmentImport.parse(other, group: makeGroup())) { error in
            XCTAssertEqual(error as? GroupAlignmentImport.ImportError, .referenceMismatch(file: "scan_X", group: "scan_A"))
        }
        let registration = Data("""
        {"rotation_deg": 12.5, "translation": [1, 2]}
        """.utf8)
        XCTAssertThrowsError(try GroupAlignmentImport.parse(registration, group: makeGroup())) { error in
            XCTAssertEqual(error as? GroupAlignmentImport.ImportError, .notAlignmentFile(found: nil))
        }
        XCTAssertThrowsError(try GroupAlignmentImport.parse(Data("not json".utf8), group: makeGroup()))
    }
}

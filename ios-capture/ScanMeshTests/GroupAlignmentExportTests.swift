import XCTest
@testable import vps

/// `group_alignment.json`(scan-group-alignment-v1)은 scan-to-map-studio의
/// merge_slicemaps.py가 읽는 계약이다. 필드 이름·기준 스캔 규칙·정렬 안 한 스캔의
/// 표기가 그쪽 파서(tests/test_merge_slicemaps.py)와 어긋나지 않게 여기서 고정한다.
final class GroupAlignmentExportTests: XCTestCase {
    private func makeGroup() -> ScanGroup {
        ScanGroup(
            id: "G1",
            name: "우리집 1층",
            scanIDs: ["scan_20260904_210428", "scan_20260904_210551", "scan_20260904_210652"],
            createdAt: Date(timeIntervalSince1970: 0),
            alignments: ["scan_20260904_210551": ScanAlignment(offsetX: 3.412, offsetZ: -1.087, yawRadians: -0.1047)]
        )
    }

    func testFirstScanIsTheReferenceAndIsNotListed() throws {
        let doc = try XCTUnwrap(GroupAlignmentExport.document(for: makeGroup()))
        XCTAssertEqual(doc.format, "scan-group-alignment-v1")
        XCTAssertEqual(doc.group, "우리집 1층")
        XCTAssertEqual(doc.reference, "scan_20260904_210428")
        XCTAssertEqual(doc.up_axis_convention, "top = -z")
        XCTAssertNil(doc.alignments["scan_20260904_210428"])
        XCTAssertEqual(Set(doc.alignments.keys), ["scan_20260904_210551", "scan_20260904_210652"])
    }

    func testAlignedScanCarriesItsValuesAndUnalignedScanIsIdentity() throws {
        let doc = try XCTUnwrap(GroupAlignmentExport.document(for: makeGroup()))
        let aligned = try XCTUnwrap(doc.alignments["scan_20260904_210551"])
        XCTAssertEqual(aligned.offsetX, 3.412, accuracy: 1e-6)
        XCTAssertEqual(aligned.offsetZ, -1.087, accuracy: 1e-6)
        XCTAssertEqual(aligned.yawRadians, -0.1047, accuracy: 1e-6)
        XCTAssertEqual(aligned.method, "app")

        let untouched = try XCTUnwrap(doc.alignments["scan_20260904_210652"])
        XCTAssertEqual(untouched.offsetX, 0)
        XCTAssertEqual(untouched.offsetZ, 0)
        XCTAssertEqual(untouched.yawRadians, 0)
        XCTAssertEqual(untouched.method, "identity")
    }

    func testJSONUsesTheAgreedKeysAndRoundTrips() throws {
        let data = try XCTUnwrap(GroupAlignmentExport.data(for: makeGroup()))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "scan-group-alignment-v1")
        XCTAssertEqual(object["reference"] as? String, "scan_20260904_210428")
        let alignments = try XCTUnwrap(object["alignments"] as? [String: Any])
        let entry = try XCTUnwrap(alignments["scan_20260904_210551"] as? [String: Any])
        XCTAssertEqual(Set(entry.keys), ["offsetX", "offsetZ", "yawRadians", "method"])

        let decoded = try JSONDecoder().decode(GroupAlignmentExport.Document.self, from: data)
        XCTAssertEqual(decoded, GroupAlignmentExport.document(for: makeGroup()))
    }

    func testGroupWithoutScansExportsNothing() throws {
        let empty = ScanGroup(id: "G0", name: "빈 프로젝트", scanIDs: [], createdAt: Date())
        XCTAssertNil(GroupAlignmentExport.document(for: empty))
        XCTAssertNil(try GroupAlignmentExport.data(for: empty))
    }
}

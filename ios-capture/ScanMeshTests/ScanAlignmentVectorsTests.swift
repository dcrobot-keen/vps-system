import XCTest
@testable import vps

/// `vps-system/scan-format/alignment-vectors.json`(정본; Python 구현에서 생성)과 대조한다 --
/// 같은 벡터를 scan-to-map-studio(Python)와 pathfinder(JS)도 검사하므로, 세 언어의
/// ScanAlignment 구현이 같은 숫자를 내는지가 여기서 고정된다.
final class ScanAlignmentVectorsTests: XCTestCase {
    func testAppliesTheCanonicalVectors() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scan-format/alignment-vectors.json")
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(doc["format"] as? String, "scan-alignment-vectors-v1")
        let tol = Float(doc["tolerance"] as? Double ?? 1e-5)
        let cases = try XCTUnwrap(doc["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 10)
        for c in cases {
            let al = try XCTUnwrap(c["alignment"] as? [String: Double])
            let a = ScanAlignment(offsetX: Float(al["offsetX"]!), offsetZ: Float(al["offsetZ"]!), yawRadians: Float(al["yawRadians"]!))
            let xz = try XCTUnwrap(c["arkit_xz"] as? [Double])
            let want = try XCTUnwrap(c["expected_arkit_xz"] as? [Double])
            let got = a.applyXZ(x: Float(xz[0]), z: Float(xz[1]))
            XCTAssertEqual(got.x, Float(want[0]), accuracy: tol, "applyXZ x for \(al)")
            XCTAssertEqual(got.z, Float(want[1]), accuracy: tol, "applyXZ z for \(al)")
            let back = a.inverseXZ(x: got.x, z: got.z)
            XCTAssertEqual(back.x, Float(xz[0]), accuracy: tol)
            XCTAssertEqual(back.z, Float(xz[1]), accuracy: tol)
        }
    }
}

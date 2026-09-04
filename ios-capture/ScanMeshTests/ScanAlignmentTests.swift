import XCTest
@testable import vps

/// `ScanAlignment.applyXZ`는 합치기(ScanGroupMerger, 3D)와 정렬 화면
/// (ScanAlignmentView, 2D 미리보기)이 공유하는 유일한 변환 공식이라 부호/순서를
/// 여기서 고정해둔다 -- 둘이 어긋나면 화면에서 맞춘 것과 다른 결과가 나온다.
final class ScanAlignmentTests: XCTestCase {
    func testIdentityLeavesPointsUnchanged() {
        let p = SIMD3<Float>(1.5, -2, 3)
        XCTAssertEqual(ScanAlignment.identity.apply(p), p)
    }

    func testOffsetTranslatesInXZOnly() {
        let a = ScanAlignment(offsetX: 10, offsetZ: -4, yawRadians: 0)
        let q = a.apply(SIMD3(1, 2, 3))
        XCTAssertEqual(q.x, 11, accuracy: 1e-5)
        XCTAssertEqual(q.y, 2, accuracy: 1e-5) // 수직은 안 건드림(바닥 높이로 따로 맞춤)
        XCTAssertEqual(q.z, -1, accuracy: 1e-5)
    }

    func testYaw90DegreesRotatesXTowardMinusZ() {
        // 공식: x' = x cos + z sin, z' = -x sin + z cos. 90도면 (1,0) -> (0,-1).
        let a = ScanAlignment(offsetX: 0, offsetZ: 0, yawRadians: .pi / 2)
        let (x, z) = a.applyXZ(x: 1, z: 0)
        XCTAssertEqual(x, 0, accuracy: 1e-5)
        XCTAssertEqual(z, -1, accuracy: 1e-5)
    }

    func testRotationIsAppliedBeforeOffset() {
        // 회전 후 이동이어야 한다: (1,0)을 90도 돌리면 (0,-1), 거기에 offset(5,5)를 더해 (5,4).
        let a = ScanAlignment(offsetX: 5, offsetZ: 5, yawRadians: .pi / 2)
        let (x, z) = a.applyXZ(x: 1, z: 0)
        XCTAssertEqual(x, 5, accuracy: 1e-5)
        XCTAssertEqual(z, 4, accuracy: 1e-5)
    }
}

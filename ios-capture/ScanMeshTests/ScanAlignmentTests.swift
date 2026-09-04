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

    /// GroundPose(Y = -z) 경로와 world (x, z) 경로가 같은 점을 같은 곳으로 보내야 한다 --
    /// 위치 확인(GroundPose)과 합치기/정렬 화면(x, z)이 서로 다른 변환을 쓰면 위치가
    /// 지도 위에서 어긋난다.
    func testApplyGroundPoseAgreesWithApplyXZ() {
        let a = ScanAlignment(offsetX: 1.5, offsetZ: -2, yawRadians: 0.7)
        let (x, z): (Float, Float) = (3, 4)
        let viaXZ = a.applyXZ(x: x, z: z)
        let viaGround = a.applyGroundPose(GroundPose(x: Double(x), y: Double(-z), headingRad: 0))
        XCTAssertEqual(viaGround.x, Double(viaXZ.x), accuracy: 1e-4)
        XCTAssertEqual(viaGround.y, Double(-viaXZ.z), accuracy: 1e-4)
        XCTAssertEqual(viaGround.headingRad, 0.7, accuracy: 1e-6)
    }

    func testRotateXZDoesNotTranslate() {
        let a = ScanAlignment(offsetX: 100, offsetZ: 100, yawRadians: .pi / 2)
        let (x, z) = a.rotateXZ(x: 1, z: 0)
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

    func testInverseXZUndoesApplyXZ() {
        let a = ScanAlignment(offsetX: 1.5, offsetZ: -2, yawRadians: 0.7)
        let p = a.applyXZ(x: 3, z: -4)
        let back = a.inverseXZ(x: p.x, z: p.z)
        XCTAssertEqual(back.x, 3, accuracy: 1e-5)
        XCTAssertEqual(back.z, -4, accuracy: 1e-5)
    }

    func testRotatedAboutPivotKeepsPivotFixed() {
        let a = ScanAlignment(offsetX: 1.5, offsetZ: -2, yawRadians: 0.3)
        let pivot: (x: Float, z: Float) = (4, 1)
        let local = a.inverseXZ(x: pivot.x, z: pivot.z)
        let rotated = a.rotated(by: 0.5, aboutX: pivot.x, z: pivot.z)
        XCTAssertEqual(rotated.yawRadians, 0.8, accuracy: 1e-6)
        let moved = rotated.applyXZ(x: local.x, z: local.z)
        XCTAssertEqual(moved.x, pivot.x, accuracy: 1e-4, "pivot에 있던 로컬 점은 회전 후에도 pivot에")
        XCTAssertEqual(moved.z, pivot.z, accuracy: 1e-4)
        // 다른 점은 pivot 기준으로 돌아간다 -- pivot에서의 거리는 그대로.
        let q = a.applyXZ(x: 0, z: 0)
        let q2 = rotated.applyXZ(x: 0, z: 0)
        XCTAssertEqual(hypot(q.x - pivot.x, q.z - pivot.z), hypot(q2.x - pivot.x, q2.z - pivot.z), accuracy: 1e-4)
    }
}

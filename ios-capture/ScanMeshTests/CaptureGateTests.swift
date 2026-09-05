import XCTest
import simd
@testable import vps

/// 프레임 저장 게이트(CaptureGate): 서 있으면 안 저장, 돌거나 걸으면 저장, 저장률 상한.
final class CaptureGateTests: XCTestCase {
    let gate = CaptureGate(intervalSeconds: 0.1, minDistanceMeters: 0.2, minRotationRadians: 15 * .pi / 180)

    func testFirstFrameAlwaysSaves() {
        XCTAssertTrue(gate.shouldSave(elapsed: 0, distance: nil, angle: nil))
    }

    func testStandingStillDoesNotSaveNoMatterHowLong() {
        XCTAssertFalse(gate.shouldSave(elapsed: 0.1, distance: 0.0, angle: 0.0))
        XCTAssertFalse(gate.shouldSave(elapsed: 30.0, distance: 0.01, angle: 0.01))
    }

    func testWalkingSavesOncePerMinDistance() {
        XCTAssertTrue(gate.shouldSave(elapsed: 0.1, distance: 0.2, angle: 0.0))
        XCTAssertFalse(gate.shouldSave(elapsed: 0.1, distance: 0.19, angle: 0.0))
    }

    func testTurningInPlaceSavesOncePerMinRotation() {
        XCTAssertTrue(gate.shouldSave(elapsed: 0.1, distance: 0.0, angle: 15.5 * .pi / 180))
        XCTAssertFalse(gate.shouldSave(elapsed: 0.1, distance: 0.0, angle: 10 * .pi / 180))
    }

    func testIntervalIsARateCapNotATrigger() {
        // moved plenty, but too soon after the last save -> wait
        XCTAssertFalse(gate.shouldSave(elapsed: 0.05, distance: 1.0, angle: 1.0))
        // enough time but no motion -> still no
        XCTAssertFalse(gate.shouldSave(elapsed: 5.0, distance: 0.0, angle: 0.0))
    }

    func testRotationAngleBetweenTransforms() {
        let a = matrix_identity_float4x4
        let yaw30 = simd_float4x4(simd_quatf(angle: 30 * .pi / 180, axis: simd_float3(0, 1, 0)))
        XCTAssertEqual(CaptureGate.rotationAngle(from: a, to: yaw30), 30 * .pi / 180, accuracy: 1e-4)
        XCTAssertEqual(CaptureGate.rotationAngle(from: yaw30, to: a), 30 * .pi / 180, accuracy: 1e-4)
        // translation alone is not rotation
        var moved = matrix_identity_float4x4
        moved.columns.3 = simd_float4(3, 0, -2, 1)
        XCTAssertEqual(CaptureGate.rotationAngle(from: a, to: moved), 0, accuracy: 1e-5)
        XCTAssertEqual(CaptureGate.position(of: moved), simd_float3(3, 0, -2))
    }
}

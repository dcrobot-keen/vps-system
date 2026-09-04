import XCTest
import simd
@testable import vps

/// 앱의 첫 자동 테스트. 순수 수학(좌표 변환)부터 시작한다 -- ARKit/Vision/Metal이
/// 필요 없는 부분이라 시뮬레이터에서도 돌고, pathfinder의
/// `scripts/live-pose-smoke.mjs`가 같은 수학을 검증하는 것과 짝을 이룬다(두 구현이
/// 같은 값을 내야 한다).
///
/// Xcode에서 타깃 추가: File > New > Target > Unit Testing Bundle, 이름 `vpsTests`,
/// Host Application `vps`. 이 폴더(`vpsTests/`)를 그 타깃의 폴더로 지정하면
/// 파일 시스템 동기화 그룹이라 여기 파일들이 자동으로 포함된다.
final class RegistrationTransformTests: XCTestCase {
    // MARK: - ARKit(Y-up) -> 지면 평면 (x, -z)

    func testIdentityTransformMapsToOriginFacingPlusY() {
        // 카메라가 world -Z를 바라보는 identity 자세 -> 지면 평면에서는 +y 방향(π/2).
        // pathfinder의 arkitPoseToGroundPose와 동일한 관례.
        let pose = GroundPose.fromARKitTransform(matrix_identity_float4x4)
        XCTAssertEqual(pose.x, 0, accuracy: 1e-9)
        XCTAssertEqual(pose.y, 0, accuracy: 1e-9)
        XCTAssertEqual(pose.headingRad, .pi / 2, accuracy: 1e-9)
    }

    func testHeightIsIgnoredAndZBecomesMinusY() {
        // ARKit (x=1, y=5(높이), z=-3) -> 지면 (x=1, y=3). 높이는 버려져야 한다 --
        // 이걸 잘못 써서 pathfinder 쪽에 실제 버그가 있었다(2026-08-30 수정).
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(1, 5, -3, 1)
        let pose = GroundPose.fromARKitTransform(transform)
        XCTAssertEqual(pose.x, 1, accuracy: 1e-6)
        XCTAssertEqual(pose.y, 3, accuracy: 1e-6)
    }

    func testYaw180FlipsHeadingByPi() {
        // Y축(ARKit의 up) 기준 180도 회전 -> 반대 방향을 봄 -> heading이 π만큼 바뀜.
        let rotation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        let transform = simd_float4x4(rotation)
        let pose = GroundPose.fromARKitTransform(transform)
        XCTAssertEqual(pose.headingRad, -.pi / 2, accuracy: 1e-6)
    }

    // MARK: - scan_basemap -> map (registration_transform.json)

    func testIdentityCalibrationLeavesPoseUnchanged() {
        let calibration = RegistrationTransform(rotationDeg: 0, translation: [0, 0])
        let pose = GroundPose(x: 5, y: 7, headingRad: 0.3)
        let mapped = calibration.scanBasemapToMap(pose)
        XCTAssertEqual(mapped.x, 5, accuracy: 1e-9)
        XCTAssertEqual(mapped.y, 7, accuracy: 1e-9)
        XCTAssertEqual(mapped.headingRad, 0.3, accuracy: 1e-9)
    }

    func testInverseOfForwardTransformRoundTrips() {
        // 정방향(map -> scan_basemap): p' = R(θ)p + t. 그걸 직접 적용한 뒤
        // scanBasemapToMap(역방향)을 거치면 원래 값으로 돌아와야 한다 --
        // pathfinder live-pose-smoke.mjs의 round-trip 체크와 같은 값(θ=37°, t=(12.5,-4.2)).
        let calibration = RegistrationTransform(rotationDeg: 37, translation: [12.5, -4.2])
        let original = GroundPose(x: 3.1, y: -8.4, headingRad: 1.2)

        let theta = 37.0 * .pi / 180
        let forward = GroundPose(
            x: cos(theta) * original.x - sin(theta) * original.y + 12.5,
            y: sin(theta) * original.x + cos(theta) * original.y - 4.2,
            headingRad: original.headingRad + theta
        )
        let back = calibration.scanBasemapToMap(forward)
        XCTAssertEqual(back.x, original.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, original.y, accuracy: 1e-9)
        XCTAssertEqual(back.headingRad, original.headingRad, accuracy: 1e-9)
    }

    func testLoadReturnsNilWhenFileMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(RegistrationTransform.load(from: dir))
    }

    func testLoadParsesScanToMapStudioJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // scan-to-map-studio가 실제로 내보내는 형태(추가 키는 무시돼야 함).
        let json = #"{"rotation_deg": 12.5, "translation": [1.0, -2.0], "rmse": 0.03}"#
        try json.write(to: dir.appendingPathComponent("registration_transform.json"), atomically: true, encoding: .utf8)

        let loaded = try XCTUnwrap(RegistrationTransform.load(from: dir))
        XCTAssertEqual(loaded.rotationDeg, 12.5)
        XCTAssertEqual(loaded.translation, [1.0, -2.0])
    }
}

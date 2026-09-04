import simd
import XCTest
@testable import vps

/// 2D ICP(ScanRegistration) -- scan-to-map-studio/tests/test_registration.py와 같은 취지:
/// 알려진 변환으로 옮겨둔 점집합을 초기값에서 되찾는지, 겹침이 없으면 낮은 대응 비율로
/// 실패를 알리는지.
final class ScanRegistrationTests: XCTestCase {
    /// 세 벽(ㄷ자 방)의 벽 점 -- 기준 좌표계. 5cm 간격(floorplan 해상도와 같음).
    private func roomWalls() -> [SIMD2<Float>] {
        var points: [SIMD2<Float>] = []
        var t: Float = 0
        while t <= 6 {
            points.append(SIMD2(t, 0)) // 아래쪽 벽 x 0...6
            t += 0.05
        }
        t = 0
        while t <= 4 {
            points.append(SIMD2(0, t)) // 왼쪽 벽 z 0...4
            points.append(SIMD2(6, t)) // 오른쪽 벽
            t += 0.05
        }
        return points
    }

    private func assertClose(_ a: ScanAlignment, _ b: ScanAlignment, yawDegrees: Float, meters: Float, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.offsetX, b.offsetX, accuracy: meters, "offsetX", file: file, line: line)
        XCTAssertEqual(a.offsetZ, b.offsetZ, accuracy: meters, "offsetZ", file: file, line: line)
        var dYaw = (a.yawRadians - b.yawRadians).truncatingRemainder(dividingBy: 2 * .pi)
        if dYaw > .pi { dYaw -= 2 * .pi }
        if dYaw < -.pi { dYaw += 2 * .pi }
        XCTAssertEqual(abs(dYaw) * 180 / .pi, 0, accuracy: yawDegrees, "yaw", file: file, line: line)
    }

    func testRefineRecoversKnownTransformFromPerturbedGuess() {
        let target = roomWalls()
        let truth = ScanAlignment(offsetX: 1.3, offsetZ: -0.7, yawRadians: 0.35)
        // source = 진짜 변환의 역으로 옮긴 target의 일부(x <= 4.5인 점만 -- 부분 겹침).
        let source: [SIMD2<Float>] = target.filter { $0.x <= 4.5 }.map { q in
            let p = truth.inverseXZ(x: q.x, z: q.y)
            return SIMD2(p.x, p.z)
        }
        // 손으로 놓은 초기값: 8° 돌아가고 25cm 어긋남.
        let guess = ScanAlignment(offsetX: truth.offsetX + 0.25, offsetZ: truth.offsetZ - 0.2, yawRadians: truth.yawRadians + 8 * .pi / 180)

        let result = ScanRegistration.refine(source: source, target: target, initial: guess, maxCorrespondenceDistance: 0.5)

        assertClose(result.alignment, truth, yawDegrees: 0.5, meters: 0.03)
        XCTAssertGreaterThan(result.inlierFraction, 0.9)
        XCTAssertLessThan(result.rmse, 0.03)
        XCTAssertGreaterThan(result.iterations, 1)
    }

    func testAlignMultistartHandlesLargerInitialRotationError() {
        let target = roomWalls()
        let truth = ScanAlignment(offsetX: -2.0, offsetZ: 1.5, yawRadians: -1.1)
        let source: [SIMD2<Float>] = target.filter { $0.z <= 3 }.map { q in
            let p = truth.inverseXZ(x: q.x, z: q.y)
            return SIMD2(p.x, p.z)
        }
        let guess = ScanAlignment(offsetX: truth.offsetX - 0.3, offsetZ: truth.offsetZ + 0.3, yawRadians: truth.yawRadians - 14 * .pi / 180)

        let result = ScanRegistration.align(source: source, target: target, initial: guess)

        assertClose(result.alignment, truth, yawDegrees: 0.5, meters: 0.03)
        XCTAssertGreaterThanOrEqual(result.inlierFraction, ScanRegistration.minimumInlierFraction)
        XCTAssertLessThan(result.rmse, 0.03)
    }

    func testNoOverlapReportsLowInlierFraction() {
        let target = roomWalls()
        // source를 20m 밖에 두면 대응이 하나도 없어야 한다.
        let source: [SIMD2<Float>] = target.map { SIMD2($0.x + 20, $0.y + 20) }
        let result = ScanRegistration.align(source: source, target: target, initial: .identity)
        XCTAssertLessThan(result.inlierFraction, ScanRegistration.minimumInlierFraction)
        XCTAssertFalse(result.rmse.isFinite)
    }

    func testEmptyInputsReturnInitialUnchanged() {
        let initial = ScanAlignment(offsetX: 1, offsetZ: 2, yawRadians: 0.3)
        let result = ScanRegistration.align(source: [], target: roomWalls(), initial: initial)
        XCTAssertEqual(result.alignment, initial)
        XCTAssertEqual(result.inlierFraction, 0)
    }

    func testPointGridFindsNearestWithinRadiusOnly() {
        let grid = ScanRegistration.PointGrid(points: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0.2, 0.1)], cellSize: 0.5)
        let hit = grid.nearest(to: SIMD2(0.25, 0.1), within: 0.5)
        XCTAssertEqual(hit, SIMD2(0.2, 0.1))
        XCTAssertNil(grid.nearest(to: SIMD2(5, 5), within: 0.5))
        // 셀 경계를 넘어도(0.49 -> 이웃 셀의 0.2) 반경 안이면 찾는다.
        XCTAssertEqual(grid.nearest(to: SIMD2(0.49, 0.49), within: 0.5), SIMD2(0.2, 0.1))
    }
}

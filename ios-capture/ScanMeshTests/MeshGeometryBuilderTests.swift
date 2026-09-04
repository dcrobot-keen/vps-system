import XCTest
@testable import vps

final class MeshGeometryBuilderTests: XCTestCase {
    func testFanTriangulateSplitsQuadIntoTwoTriangles() {
        let quad: [UInt32] = [0, 1, 2, 3]
        XCTAssertEqual(MeshGeometryBuilder.fanTriangulate(quad), [0, 1, 2, 0, 2, 3])
    }

    func testFanTriangulateLeavesTriangleUnchanged() {
        let triangle: [UInt32] = [5, 6, 7]
        XCTAssertEqual(MeshGeometryBuilder.fanTriangulate(triangle), [5, 6, 7])
    }

    func testFanTriangulateReturnsEmptyForDegenerateFace() {
        XCTAssertEqual(MeshGeometryBuilder.fanTriangulate([0, 1]), [])
        XCTAssertEqual(MeshGeometryBuilder.fanTriangulate([]), [])
    }

    func testComputeFaceNormalsPointsAwayFromXYPlaneForCCWTriangle() {
        // (0,0,0)-(1,0,0)-(0,1,0), CCW일 때 cross(b-a, c-a) = cross((1,0,0),(0,1,0)) = (0,0,1).
        let positions: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        let indices: [UInt32] = [0, 1, 2]
        let normals = MeshGeometryBuilder.computeFaceNormals(positions: positions, indices: indices)
        XCTAssertEqual(normals.count, 3)
        for normal in normals {
            XCTAssertEqual(normal.x, 0, accuracy: 1e-5)
            XCTAssertEqual(normal.y, 0, accuracy: 1e-5)
            XCTAssertEqual(normal.z, 1, accuracy: 1e-5)
        }
    }

    func testComputeFaceNormalsFallsBackToUpForUnusedVertex() {
        // vertex 2는 어떤 face에도 안 쓰임 -- normal이 0벡터로 남으면 SceneKit이
        // 렌더링에서 이상하게 구는 걸 막기 위해 (0,1,0)으로 대체돼야 한다.
        let positions: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(9, 9, 9)]
        let indices: [UInt32] = [0, 1, 0] // 퇴화 face(면적 0)라 vertex 2는 아예 등장하지 않음
        let normals = MeshGeometryBuilder.computeFaceNormals(positions: positions, indices: indices)
        XCTAssertEqual(normals[2], SIMD3<Float>(0, 1, 0))
    }
}

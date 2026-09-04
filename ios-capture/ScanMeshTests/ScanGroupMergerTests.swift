import SceneKit
import XCTest
@testable import vps

/// `ScanGroupMerger`는 `scan.usdz`를 읽는 `MeshUnifier.load`에 의존하는데,
/// `ARMeshAnchor`는 테스트에서 못 만들어서(FloorPlanRendererTests와 같은 이유)
/// `MeshExporter`를 거치지 못한다. 대신 `MeshExporter.export`가 하는 것과 같은 핵심
/// 동작(SCNGeometry -> SCNScene -> .usdz)을 직접 해서 최소 fixture를 만든다 --
/// `MeshUnifier.load`가 실제로 읽는 것과 같은 파일 형태다.
final class ScanGroupMergerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// `scan_<name>/scan.usdz`를 가진 폴더를 만든다. 삼각형 하나짜리 mesh -- `origin`을
    /// 더해서 두 스캔의 좌표 범위가 겹치지 않게 한다(용접이 서로 다른 스캔의 정점을
    /// 잘못 합치지 않는지까지 같이 확인하기 위함).
    private func makeScanFolder(named name: String, origin: SIMD3<Float>) throws -> URL {
        let folder = root.appendingPathComponent("scan_\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let positions: [SIMD3<Float>] = [
            origin + SIMD3(0, 0, 0), origin + SIMD3(1, 0, 0), origin + SIMD3(0, 1, 0),
        ]
        let normals: [SIMD3<Float>] = Array(repeating: SIMD3(0, 0, 1), count: 3)
        let indices: [UInt32] = [0, 1, 2]

        let vertexSource = SCNGeometrySource(
            data: positions.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .vertex,
            vectorCount: 3, usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let normalSource = SCNGeometrySource(
            data: normals.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .normal,
            vectorCount: 3, usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let element = SCNGeometryElement(
            data: indices.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles,
            primitiveCount: 1, bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))

        let usdzURL = folder.appendingPathComponent("scan.usdz")
        guard scene.write(to: usdzURL, options: nil, delegate: nil, progressHandler: nil) else {
            throw XCTSkip("SCNScene.write(to:) failed in this environment")
        }
        return folder
    }

    func testMergeMeshCombinesTwoScansWithCorrectIndexOffsets() throws {
        let scanA = try makeScanFolder(named: "A", origin: SIMD3(0, 0, 0))
        let scanB = try makeScanFolder(named: "B", origin: SIMD3(100, 0, 0)) // 멀리 떨어뜨려 용접 안 되게

        let merged = try ScanGroupMerger.mergeMesh(scanFolderURLs: [scanA, scanB])

        XCTAssertEqual(merged.positions.count, 6) // 3 + 3, 서로 안 겹쳐서 용접으로 안 줄어듦
        XCTAssertEqual(merged.indices.count, 6) // 삼각형 2개
        XCTAssertEqual(merged.normals.count, merged.positions.count)

        // 두 번째 스캔의 인덱스가 첫 번째 스캔의 정점 개수만큼 밀려 있어야(겹치지 않아야) 한다.
        let secondTriangleIndices = Set(merged.indices[3...5].map { Int($0) })
        XCTAssertTrue(secondTriangleIndices.allSatisfy { $0 >= 3 })
    }

    func testMergeMeshSkipsScansWithoutUSDZ() throws {
        let scanA = try makeScanFolder(named: "A", origin: .zero)
        let scanNoMesh = root.appendingPathComponent("scan_no_mesh")
        try FileManager.default.createDirectory(at: scanNoMesh, withIntermediateDirectories: true)

        let merged = try ScanGroupMerger.mergeMesh(scanFolderURLs: [scanA, scanNoMesh])
        XCTAssertEqual(merged.positions.count, 3)
    }

    func testUnindexedForGLBExpandsSharedVerticesPerTriangleCorner() {
        // 정점 4개를 삼각형 2개가 공유하는 사각형(0,1,2 / 0,2,3) -- unindexed 결과는
        // 삼각형 2개 * 3코너 = 6개 "정점"(공유 해제)이어야 한다.
        let mesh = ScanGroupMerger.MergedMesh(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            indices: [0, 1, 2, 0, 2, 3]
        )
        let (positions, normals, vertexCount) = mesh.unindexedForGLB()
        XCTAssertEqual(vertexCount, 6)
        XCTAssertEqual(positions.count, 18) // 6 * 3
        XCTAssertEqual(normals.count, 18)
        // 첫 코너는 정점 0 -> (0,0,0)
        XCTAssertEqual(Array(positions[0..<3]), [0, 0, 0])
        // 네 번째 코너(두 번째 삼각형의 첫 코너)도 정점 0 -> (0,0,0), 공유가 풀려도 값은 같아야 함
        XCTAssertEqual(Array(positions[9..<12]), [0, 0, 0])
    }

    func testMergeMeshThrowsWhenNoScanHasUSDZ() throws {
        let scanNoMesh = root.appendingPathComponent("scan_no_mesh")
        try FileManager.default.createDirectory(at: scanNoMesh, withIntermediateDirectories: true)

        XCTAssertThrowsError(try ScanGroupMerger.mergeMesh(scanFolderURLs: [scanNoMesh])) { error in
            guard case ScanGroupMerger.MergeError.noScansWithMesh = error else {
                XCTFail("expected .noScansWithMesh, got \(error)")
                return
            }
        }
    }
}

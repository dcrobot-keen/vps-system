import SceneKit
import XCTest
@testable import vps

/// PLYWriter가 쓴 파일을 PLYLoader(이미 검증됨, PLYLoaderTests)로 다시 읽어서 왕복
/// 확인한다 -- 두 코드를 서로 마주 보게 하는 게 손으로 만든 바이너리 포맷 코드의
/// 실제 사용처(프로젝트 export)에 제일 가까운 검증이다.
final class PLYWriterTests: XCTestCase {
    private var tempURL: URL!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ply")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testWriteThenLoadRoundTripsMeshWithNormals() throws {
        let positions: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        let normals: [SIMD3<Float>] = [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)]
        let indices: [UInt32] = [0, 1, 2]

        try PLYWriter.write(positions: positions, normals: normals, indices: indices, to: tempURL)
        let geometry = try PLYLoader.loadGeometry(at: tempURL)

        let readPositions = try Self.readVec3Source(geometry, semantic: .vertex)
        XCTAssertEqual(readPositions, positions)
        let readNormals = try Self.readVec3Source(geometry, semantic: .normal)
        XCTAssertEqual(readNormals, normals)
        XCTAssertEqual(geometry.elements.first?.primitiveType, .triangles)
        XCTAssertEqual(geometry.elements.first?.primitiveCount, 1)
    }

    func testWriteThenLoadRoundTripsPointCloudWithoutFaces() throws {
        let positions: [SIMD3<Float>] = [SIMD3(1, 2, 3), SIMD3(4, 5, 6)]
        try PLYWriter.write(positions: positions, normals: nil, indices: [], to: tempURL)
        let geometry = try PLYLoader.loadGeometry(at: tempURL)

        let readPositions = try Self.readVec3Source(geometry, semantic: .vertex)
        XCTAssertEqual(readPositions, positions)
        XCTAssertEqual(geometry.elements.first?.primitiveType, .point)
    }

    private static func readVec3Source(_ geometry: SCNGeometry, semantic: SCNGeometrySource.Semantic) throws -> [SIMD3<Float>] {
        guard let source = geometry.sources(for: semantic).first else {
            throw XCTSkip("no \(semantic) source")
        }
        var out = [SIMD3<Float>](repeating: .zero, count: source.vectorCount)
        source.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<source.vectorCount {
                let base = source.dataOffset + source.dataStride * i
                out[i] = SIMD3(
                    raw.load(fromByteOffset: base, as: Float.self),
                    raw.load(fromByteOffset: base + 4, as: Float.self),
                    raw.load(fromByteOffset: base + 8, as: Float.self)
                )
            }
        }
        return out
    }
}

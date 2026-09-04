import SceneKit
import XCTest
@testable import vps

/// PCDWriter가 쓴 파일을 PCDLoader(이미 검증됨, PCDLoaderTests)로 다시 읽어서 왕복
/// 확인한다.
final class PCDWriterTests: XCTestCase {
    private var tempURL: URL!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pcd")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testWriteThenLoadRoundTripsPoints() throws {
        let positions: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1.5, -2, 3), SIMD3(-4, 5.25, -6)]
        try PCDWriter.write(positions: positions, to: tempURL)

        let geometry = try PCDLoader.loadGeometry(at: tempURL)
        guard let source = geometry.sources(for: .vertex).first else {
            return XCTFail("no vertex source")
        }
        var readPositions = [SIMD3<Float>](repeating: .zero, count: source.vectorCount)
        source.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<source.vectorCount {
                let base = source.dataOffset + source.dataStride * i
                readPositions[i] = SIMD3(
                    raw.load(fromByteOffset: base, as: Float.self),
                    raw.load(fromByteOffset: base + 4, as: Float.self),
                    raw.load(fromByteOffset: base + 8, as: Float.self)
                )
            }
        }
        XCTAssertEqual(readPositions, positions)
        XCTAssertEqual(geometry.elements.first?.primitiveType, .point)
        XCTAssertEqual(geometry.elements.first?.primitiveCount, positions.count)
    }
}

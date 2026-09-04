import SceneKit
import XCTest
@testable import vps

/// PCD도 PLY와 같은 이유로 손으로 짠 파서(PCDLoader.swift)라 ascii/binary 왕복을
/// 직접 인코딩해서 검증한다. binary_compressed(LZF)는 PCDLoader 자체가 범위 밖으로
/// 두고 명확한 에러를 내므로 그것도 같이 확인한다.
final class PCDLoaderTests: XCTestCase {
    private var tempURL: URL!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pcd")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL)
    }

    private static func header(fields: String, size: String, type: String, count: String, points: Int, data: String) -> String {
        """
        # .PCD v0.7
        VERSION 0.7
        FIELDS \(fields)
        SIZE \(size)
        TYPE \(type)
        COUNT \(count)
        WIDTH \(points)
        HEIGHT 1
        POINTS \(points)
        DATA \(data)

        """
    }

    func testLoadsAsciiPointsWithPackedRGBColor() throws {
        // PCL 관례: rgb 필드는 float 하나에 0x00RRGGBB 비트를 그대로 박아넣는다 --
        // 순빨강은 0x00FF0000, float 비트패턴으로 그 값을 그대로 쓴다.
        let redPacked = Float(bitPattern: 0x00FF_0000)
        let header = Self.header(fields: "x y z rgb", size: "4 4 4 4", type: "F F F F", count: "1 1 1 1", points: 2, data: "ascii")
        let body = "0 0 0 \(redPacked)\n1 2 3 0\n"
        try Data((header + body).utf8).write(to: tempURL)

        let geometry = try PCDLoader.loadGeometry(at: tempURL)
        let (positions, colors) = try Self.readVertexData(geometry)

        XCTAssertEqual(positions.count, 2)
        XCTAssertEqual(positions[0], SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(positions[1], SIMD3<Float>(1, 2, 3))

        let colors2 = try XCTUnwrap(colors)
        XCTAssertEqual(colors2[0].x, 1.0, accuracy: 0.01) // red
        XCTAssertEqual(colors2[0].y, 0.0, accuracy: 0.01)

        // point cloud(면 없음)라 .point primitive로 그려져야 한다.
        XCTAssertEqual(geometry.elements[0].primitiveType, .point)
        XCTAssertEqual(geometry.elements[0].primitiveCount, 2)
    }

    func testLoadsBinaryPointsWithoutColor() throws {
        let header = Self.header(fields: "x y z", size: "4 4 4", type: "F F F", count: "1 1 1", points: 2, data: "binary")
        var fileData = Data(header.utf8)
        func appendFloatLE(_ value: Float) {
            var v = value
            withUnsafeBytes(of: &v) { fileData.append(contentsOf: $0) }
        }
        for p: (Float, Float, Float) in [(0, 0, 0), (1.5, -2, 3)] {
            appendFloatLE(p.0); appendFloatLE(p.1); appendFloatLE(p.2)
        }
        try fileData.write(to: tempURL)

        let geometry = try PCDLoader.loadGeometry(at: tempURL)
        let (positions, colors) = try Self.readVertexData(geometry)
        XCTAssertEqual(positions.count, 2)
        XCTAssertEqual(positions[1], SIMD3<Float>(1.5, -2, 3))
        XCTAssertNil(colors)
    }

    func testBinaryCompressedThrowsUnsupportedCompression() throws {
        let header = Self.header(fields: "x y z", size: "4 4 4", type: "F F F", count: "1 1 1", points: 1, data: "binary_compressed")
        try Data(header.utf8).write(to: tempURL)

        XCTAssertThrowsError(try PCDLoader.loadGeometry(at: tempURL)) { error in
            guard case PCDLoader.LoadError.unsupportedCompression = error else {
                XCTFail("expected .unsupportedCompression, got \(error)")
                return
            }
        }
    }

    private static func readVertexData(_ geometry: SCNGeometry) throws -> ([SIMD3<Float>], [SIMD4<Float>]?) {
        guard let vertexSource = geometry.sources(for: .vertex).first else {
            throw XCTSkip("no vertex source")
        }
        let count = vertexSource.vectorCount
        var positions = [SIMD3<Float>](repeating: .zero, count: count)
        vertexSource.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<count {
                let base = vertexSource.dataOffset + vertexSource.dataStride * i
                positions[i] = SIMD3(
                    raw.load(fromByteOffset: base, as: Float.self),
                    raw.load(fromByteOffset: base + 4, as: Float.self),
                    raw.load(fromByteOffset: base + 8, as: Float.self)
                )
            }
        }
        guard let colorSource = geometry.sources(for: .color).first else { return (positions, nil) }
        var colors = [SIMD4<Float>](repeating: .zero, count: colorSource.vectorCount)
        colorSource.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<colorSource.vectorCount {
                let base = colorSource.dataOffset + colorSource.dataStride * i
                colors[i] = SIMD4(
                    raw.load(fromByteOffset: base, as: Float.self),
                    raw.load(fromByteOffset: base + 4, as: Float.self),
                    raw.load(fromByteOffset: base + 8, as: Float.self),
                    raw.load(fromByteOffset: base + 12, as: Float.self)
                )
            }
        }
        return (positions, colors)
    }
}

import SceneKit
import XCTest
@testable import vps

/// PLY는 SceneKit/ModelIO가 iOS에서 못 읽어 손으로 짠 파서(PLYLoader.swift)라,
/// ascii/binary_little_endian 두 포맷 다 같은 삼각형(색 있음, normal 없음 -- face
/// normal 계산 경로까지 같이 검증)을 직접 인코딩해서 왕복 확인한다.
final class PLYLoaderTests: XCTestCase {
    private var tempURL: URL!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ply")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL)
    }

    private static let header = """
    ply
    format ascii 1.0
    element vertex 3
    property float x
    property float y
    property float z
    property uchar red
    property uchar green
    property uchar blue
    element face 1
    property list uchar int vertex_indices
    end_header

    """

    func testLoadsAsciiTriangleWithColorAndComputedNormal() throws {
        let body = """
        0 0 0 255 0 0
        1 0 0 0 255 0
        0 1 0 0 0 255
        3 0 1 2

        """
        try Data((Self.header + body).utf8).write(to: tempURL)

        let geometry = try PLYLoader.loadGeometry(at: tempURL)
        let (positions, colors) = try Self.readVertexData(geometry)

        XCTAssertEqual(positions.count, 3)
        XCTAssertEqual(positions[0], SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(positions[1], SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(positions[2], SIMD3<Float>(0, 1, 0))

        let colors2 = try XCTUnwrap(colors)
        // color source는 RGBA float 4개짜리로 저장됨(MeshGeometryBuilder) -- 첫 정점은
        // 빨강(255,0,0)이어야 한다.
        XCTAssertEqual(colors2[0].x, 1.0, accuracy: 0.01)
        XCTAssertEqual(colors2[0].y, 0.0, accuracy: 0.01)
        XCTAssertEqual(colors2[0].z, 0.0, accuracy: 0.01)

        XCTAssertEqual(geometry.elements.count, 1)
        XCTAssertEqual(geometry.elements[0].primitiveType, .triangles)
        XCTAssertEqual(geometry.elements[0].primitiveCount, 1)
    }

    func testLoadsBinaryLittleEndianTriangle() throws {
        let header = Self.header.replacingOccurrences(of: "format ascii 1.0", with: "format binary_little_endian 1.0")
        var fileData = Data(header.utf8)

        func appendFloatLE(_ value: Float, to data: inout Data) {
            var v = value
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        func appendInt32LE(_ value: Int32, to data: inout Data) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        let verts: [(Float, Float, Float, UInt8, UInt8, UInt8)] = [
            (0, 0, 0, 255, 0, 0),
            (1, 0, 0, 0, 255, 0),
            (0, 1, 0, 0, 0, 255),
        ]
        for v in verts {
            appendFloatLE(v.0, to: &fileData)
            appendFloatLE(v.1, to: &fileData)
            appendFloatLE(v.2, to: &fileData)
            fileData.append(v.3)
            fileData.append(v.4)
            fileData.append(v.5)
        }
        fileData.append(3) // face vertex count (uchar)
        appendInt32LE(0, to: &fileData)
        appendInt32LE(1, to: &fileData)
        appendInt32LE(2, to: &fileData)

        try fileData.write(to: tempURL)

        let geometry = try PLYLoader.loadGeometry(at: tempURL)
        let (positions, _) = try Self.readVertexData(geometry)
        XCTAssertEqual(positions.count, 3)
        XCTAssertEqual(positions[1], SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(geometry.elements[0].primitiveCount, 1)
    }

    /// SCNGeometrySource(.vertex)/(.color)를 다시 SIMD 배열로 풀어낸다 -- vertex는
    /// tightly-packed float3(stride 12), color는 float4(stride 16)로 저장돼 있다
    /// (MeshGeometryBuilder.build 참고).
    private static func readVertexData(_ geometry: SCNGeometry) throws -> ([SIMD3<Float>], [SIMD4<Float>]?) {
        guard let vertexSource = geometry.sources(for: .vertex).first else {
            throw XCTSkip("no vertex source")
        }
        let count = vertexSource.vectorCount
        var positions = [SIMD3<Float>](repeating: .zero, count: count)
        vertexSource.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<count {
                let base = vertexSource.dataOffset + vertexSource.dataStride * i
                let x = raw.load(fromByteOffset: base, as: Float.self)
                let y = raw.load(fromByteOffset: base + 4, as: Float.self)
                let z = raw.load(fromByteOffset: base + 8, as: Float.self)
                positions[i] = SIMD3(x, y, z)
            }
        }

        guard let colorSource = geometry.sources(for: .color).first else {
            return (positions, nil)
        }
        var colors = [SIMD4<Float>](repeating: .zero, count: colorSource.vectorCount)
        colorSource.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<colorSource.vectorCount {
                let base = colorSource.dataOffset + colorSource.dataStride * i
                let r = raw.load(fromByteOffset: base, as: Float.self)
                let g = raw.load(fromByteOffset: base + 4, as: Float.self)
                let b = raw.load(fromByteOffset: base + 8, as: Float.self)
                let a = raw.load(fromByteOffset: base + 12, as: Float.self)
                colors[i] = SIMD4(r, g, b, a)
            }
        }
        return (positions, colors)
    }
}

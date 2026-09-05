import SceneKit
import UIKit
import XCTest
@testable import vps

/// GLBWriter(TextureBaker가 쓰는 쪽)와 GLBLoader(뷰어가 쓰는 쪽)는 서로 대칭이 되도록
/// 필드를 맞춰뒀다고 문서화돼 있다(GLBWriter.swift 상단 주석) -- 그 주장을 실제
/// 왕복으로 검증한다. 이 앱엔 glTF를 만드는 산출물이 하나뿐이라(TextureBaker의
/// textured.glb), write -> load 왕복이 곧 그 유일한 실사용 경로다.
final class GLBLoaderTests: XCTestCase {
    private var tempURL: URL!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".glb")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testWriteThenLoadRoundTripsTriangleAndTexture() throws {
        let positions: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        let normals: [Float] = [0, 0, 1, 0, 0, 1, 0, 0, 1]
        let uvs: [Float] = [0, 0, 1, 0, 0, 1]
        // 2x2 순빨강 텍스처(RGBA8).
        let textureRGBA: [UInt8] = (0..<4).flatMap { _ in [255, 0, 0, 255] }

        try GLBWriter.write(
            positions: positions, normals: normals, uvs: uvs,
            textureRGBA: textureRGBA, textureWidth: 2, textureHeight: 2,
            to: tempURL
        )

        let scene = try GLBLoader.loadScene(at: tempURL)
        XCTAssertEqual(scene.rootNode.childNodes.count, 1)
        let geometry = try XCTUnwrap(scene.rootNode.childNodes.first?.geometry)

        let readPositions = try Self.readVec3Source(geometry, semantic: .vertex)
        XCTAssertEqual(readPositions.count, 3)
        XCTAssertEqual(readPositions[0], SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(readPositions[1], SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(readPositions[2], SIMD3<Float>(0, 1, 0))

        let readNormals = try Self.readVec3Source(geometry, semantic: .normal)
        XCTAssertEqual(readNormals[0], SIMD3<Float>(0, 0, 1))

        XCTAssertEqual(geometry.elements.count, 1)
        XCTAssertEqual(geometry.elements[0].primitiveType, .triangles)
        XCTAssertEqual(geometry.elements[0].primitiveCount, 1)

        let material = try XCTUnwrap(geometry.materials.first)
        let image = try XCTUnwrap(material.diffuse.contents as? UIImage)
        XCTAssertEqual(image.size.width, 2)
        XCTAssertEqual(image.size.height, 2)
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

    /// primitive 여러 개(각자 텍스처)를 쓰고 raw로 다시 읽으면 정점/인덱스/텍스처 바이트가
    /// primitive별로 그대로 돌아와야 한다 -- TexturedGroupMerger가 스캔별 textured.glb를
    /// 합칠 때 의존하는 왕복.
    func testMultiPrimitiveRoundTripKeepsGeometryAndTexturePerPrimitive() throws {
        let red = try XCTUnwrap(GLBWriter.encodePNG(rgba: [255, 0, 0, 255], width: 1, height: 1))
        let blue = try XCTUnwrap(GLBWriter.encodePNG(rgba: [0, 0, 255, 255], width: 1, height: 1))
        let first = GLBWriter.Primitive(
            positions: [0, 0, 0, 1, 0, 0, 0, 1, 0], normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
            uvs: [0, 0, 1, 0, 0, 1], indices: nil, imageData: red, imageMimeType: "image/png"
        )
        let second = GLBWriter.Primitive(
            positions: [5, 0, 0, 6, 0, 0, 5, 1, 0, 6, 1, 0], normals: [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
            uvs: [0, 0, 1, 0, 0, 1, 1, 1], indices: [0, 1, 2, 2, 1, 3], imageData: blue, imageMimeType: "image/png"
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("multi-\(UUID().uuidString).glb")
        defer { try? FileManager.default.removeItem(at: url) }
        try GLBWriter.write(primitives: [first, second], to: url)

        let raws = try GLBLoader.loadPrimitives(at: url)
        XCTAssertEqual(raws.count, 2)
        XCTAssertEqual(raws[0].positions.count, 3)
        XCTAssertNil(raws[0].indices, "non-indexed는 nil로 돌아와야 정점 순서 삼각형으로 다시 쓸 수 있다")
        XCTAssertEqual(raws[0].imageData, red)
        XCTAssertEqual(raws[0].imageMimeType, "image/png")
        XCTAssertTrue(raws[0].hasMaterial)

        XCTAssertEqual(raws[1].positions.count, 4)
        XCTAssertEqual(raws[1].positions[3], SIMD3(6, 1, 0))
        XCTAssertEqual(raws[1].indices, [0, 1, 2, 2, 1, 3])
        XCTAssertEqual(raws[1].uvs?.count, 4)
        XCTAssertEqual(raws[1].imageData, blue)

        let scene = try GLBLoader.loadScene(at: url)
        XCTAssertEqual(scene.rootNode.childNodes.count, 2)
    }
}

import Foundation
import SceneKit
import UIKit

/// GLB(바이너리 glTF 2.0) 파서. SceneKit/ModelIO는 iOS에서 glTF를 아예 못 읽어서
/// 직접 구현한다. 범위를 의도적으로 좁혔다 — scan-to-map-studio의 `overlay.glb`
/// 같은 "정적 mesh + 색/텍스처" 정도만 지원하고, 스키닝/애니메이션/카메라/조명/
/// 여러 node의 변환 계층 같은 건 다루지 않는다(모든 mesh를 원점 기준으로 평평하게
/// 합친다). embedded 텍스처(bufferView 참조)만 지원하고 외부 uri 텍스처는 건너뛴다.
enum GLBLoader {
    enum LoadError: Error {
        case invalidContainer
        case invalidJSON
        case noMesh
    }

    /// primitive 하나를 SceneKit 없이 그대로 꺼낸 것 -- TexturedGroupMerger가 스캔별
    /// textured.glb를 변환해 다시 GLB로 쓸 때 쓴다(GLBWriter.Primitive와 대칭).
    struct RawPrimitive {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]?
        var uvs: [SIMD2<Float>]?
        /// nil이면 non-indexed(정점 순서대로 삼각형).
        var indices: [UInt32]?
        var baseColorFactor: [Double]?
        /// embedded 텍스처 바이트(png/jpeg)와 mimeType. 없으면 nil.
        var imageData: Data?
        var imageMimeType: String?
        /// glTF material이 하나라도 붙어 있었는지(없으면 SceneKit 기본 재질을 그대로 둔다).
        var hasMaterial: Bool

        var triangleIndices: [UInt32] {
            indices ?? (0..<UInt32(positions.count)).map { $0 }
        }
    }

    static func loadScene(at url: URL) throws -> SCNScene {
        let primitives = try loadPrimitives(at: url)
        let scene = SCNScene()
        for raw in primitives {
            guard let geometry = makeGeometry(raw) else { continue }
            if raw.hasMaterial {
                geometry.materials = [makeMaterial(raw)]
            }
            scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        }
        guard !scene.rootNode.childNodes.isEmpty else { throw LoadError.noMesh }
        return scene
    }

    static func loadPrimitives(at url: URL) throws -> [RawPrimitive] {
        let data = try Data(contentsOf: url)
        let (json, binaryChunk) = try parseContainer(data)

        guard let meshes = json["meshes"] as? [[String: Any]] else { throw LoadError.noMesh }
        let accessors = json["accessors"] as? [[String: Any]] ?? []
        let bufferViews = json["bufferViews"] as? [[String: Any]] ?? []
        let materials = json["materials"] as? [[String: Any]] ?? []
        let textures = json["textures"] as? [[String: Any]] ?? []
        let images = json["images"] as? [[String: Any]] ?? []

        var result: [RawPrimitive] = []
        for mesh in meshes {
            guard let primitives = mesh["primitives"] as? [[String: Any]] else { continue }
            for primitive in primitives {
                guard var raw = readPrimitive(
                    primitive, accessors: accessors, bufferViews: bufferViews, binary: binaryChunk
                ) else { continue }
                if let materialIndex = primitive["material"] as? Int, materialIndex < materials.count {
                    raw.hasMaterial = true
                    readMaterial(
                        materials[materialIndex], into: &raw, textures: textures, images: images,
                        bufferViews: bufferViews, binary: binaryChunk
                    )
                }
                result.append(raw)
            }
        }
        guard !result.isEmpty else { throw LoadError.noMesh }
        return result
    }

    // MARK: - GLB 컨테이너 (헤더 12바이트 + JSON 청크 + 옵션 BIN 청크)

    private static func parseContainer(_ data: Data) throws -> ([String: Any], Data?) {
        guard data.count >= 12 else { throw LoadError.invalidContainer }
        let magic = data.subdata(in: 0..<4)
        guard magic == Data("glTF".utf8) else { throw LoadError.invalidContainer }

        var offset = 12
        var jsonData: Data?
        var binaryData: Data?

        while offset + 8 <= data.count {
            let chunkLength = Int(readUInt32LE(data, at: offset))
            let chunkType = data.subdata(in: (offset + 4)..<(offset + 8))
            let chunkStart = offset + 8
            guard chunkStart + chunkLength <= data.count else { break }
            let chunkData = data.subdata(in: chunkStart..<(chunkStart + chunkLength))

            if chunkType == Data("JSON".utf8) {
                jsonData = chunkData
            } else if chunkType == Data([0x42, 0x49, 0x4E, 0x00]) { // "BIN\0"
                binaryData = chunkData
            }
            offset = chunkStart + chunkLength
        }

        guard let jsonData, let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw LoadError.invalidJSON
        }
        return (json, binaryData)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let bytes = data[offset..<(offset + 4)]
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    // MARK: - geometry

    private static func readPrimitive(
        _ primitive: [String: Any], accessors: [[String: Any]], bufferViews: [[String: Any]], binary: Data?
    ) -> RawPrimitive? {
        guard let attributes = primitive["attributes"] as? [String: Int],
              let positionAccessorIndex = attributes["POSITION"],
              let binary
        else { return nil }

        guard let positionsFlat = readAccessor(
            positionAccessorIndex, componentsPerElement: 3, accessors: accessors, bufferViews: bufferViews, binary: binary
        ) else { return nil }
        var raw = RawPrimitive(positions: toVec3(positionsFlat), hasMaterial: false)

        if let normalIndex = attributes["NORMAL"],
           let flat = readAccessor(normalIndex, componentsPerElement: 3, accessors: accessors, bufferViews: bufferViews, binary: binary) {
            raw.normals = toVec3(flat)
        }
        if let uvIndex = attributes["TEXCOORD_0"],
           let flat = readAccessor(uvIndex, componentsPerElement: 2, accessors: accessors, bufferViews: bufferViews, binary: binary) {
            raw.uvs = toVec2(flat)
        }
        if let indicesAccessorIndex = primitive["indices"] as? Int {
            raw.indices = readIndexAccessor(indicesAccessorIndex, accessors: accessors, bufferViews: bufferViews, binary: binary) ?? []
        }
        return raw
    }

    private static func makeGeometry(_ raw: RawPrimitive) -> SCNGeometry? {
        let positions = raw.positions
        let normals = raw.normals
        let uvs = raw.uvs
        let indices = raw.triangleIndices // non-indexed: 정점 순서 그대로 삼각형
        guard !indices.isEmpty else { return nil }

        let vertexStride = MemoryLayout<SIMD3<Float>>.stride
        let vertexData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        var sources = [SCNGeometrySource(
            data: vertexData, semantic: .vertex, vectorCount: positions.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: vertexStride
        )]

        let resolvedNormals = normals ?? MeshGeometryBuilder.computeFaceNormals(positions: positions, indices: indices)
        if resolvedNormals.count == positions.count {
            let normalData = resolvedNormals.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(
                data: normalData, semantic: .normal, vectorCount: resolvedNormals.count,
                usesFloatComponents: true, componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: vertexStride
            ))
        }

        if let uvs, uvs.count == positions.count {
            let uvData = uvs.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(
                data: uvData, semantic: .texcoord, vectorCount: uvs.count,
                usesFloatComponents: true, componentsPerVector: 2,
                bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<SIMD2<Float>>.stride
            ))
        }

        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .triangles,
            primitiveCount: indices.count / 3, bytesPerIndex: MemoryLayout<UInt32>.size
        )
        return SCNGeometry(sources: sources, elements: [element])
    }

    // MARK: - accessor/bufferView 읽기

    private static let componentByteSize: [Int: Int] = [
        5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4,
    ]
    private static let typeComponentCount: [String: Int] = [
        "SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16,
    ]

    /// float 계열 attribute(POSITION/NORMAL/TEXCOORD_0)를 읽어서 평탄화된 Float 배열로
    /// 반환한다. componentType이 5126(FLOAT)이 아니면(정규화된 정수 등) 범위 밖으로 두고
    /// nil을 반환한다 — 우리가 만드는 파이프라인 결과물은 항상 float이라 실용적으로 충분하다.
    private static func readAccessor(
        _ accessorIndex: Int, componentsPerElement: Int,
        accessors: [[String: Any]], bufferViews: [[String: Any]], binary: Data
    ) -> [Float]? {
        guard accessorIndex < accessors.count else { return nil }
        let accessor = accessors[accessorIndex]
        guard let bufferViewIndex = accessor["bufferView"] as? Int, bufferViewIndex < bufferViews.count,
              let componentType = accessor["componentType"] as? Int, componentType == 5126,
              let count = accessor["count"] as? Int,
              let type = accessor["type"] as? String, typeComponentCount[type] == componentsPerElement
        else { return nil }

        let bufferView = bufferViews[bufferViewIndex]
        let viewOffset = bufferView["byteOffset"] as? Int ?? 0
        let byteStride = bufferView["byteStride"] as? Int ?? (componentsPerElement * 4)
        let accessorOffset = accessor["byteOffset"] as? Int ?? 0
        let start = viewOffset + accessorOffset

        var result = [Float](repeating: 0, count: count * componentsPerElement)
        for i in 0..<count {
            let elementStart = start + i * byteStride
            for c in 0..<componentsPerElement {
                let byteOffset = elementStart + c * 4
                guard byteOffset + 4 <= binary.count else { continue }
                result[i * componentsPerElement + c] = binary[byteOffset..<(byteOffset + 4)]
                    .withUnsafeBytes { Float(bitPattern: $0.loadUnaligned(as: UInt32.self)) }
            }
        }
        return result
    }

    /// index accessor(SCALAR, UNSIGNED_BYTE/SHORT/INT)를 UInt32로 통일해서 읽는다.
    private static func readIndexAccessor(
        _ accessorIndex: Int, accessors: [[String: Any]], bufferViews: [[String: Any]], binary: Data
    ) -> [UInt32]? {
        guard accessorIndex < accessors.count else { return nil }
        let accessor = accessors[accessorIndex]
        guard let bufferViewIndex = accessor["bufferView"] as? Int, bufferViewIndex < bufferViews.count,
              let componentType = accessor["componentType"] as? Int,
              let componentSize = componentByteSize[componentType],
              let count = accessor["count"] as? Int
        else { return nil }

        let bufferView = bufferViews[bufferViewIndex]
        let viewOffset = bufferView["byteOffset"] as? Int ?? 0
        let byteStride = bufferView["byteStride"] as? Int ?? componentSize
        let accessorOffset = accessor["byteOffset"] as? Int ?? 0
        let start = viewOffset + accessorOffset

        var result = [UInt32](repeating: 0, count: count)
        for i in 0..<count {
            let byteOffset = start + i * byteStride
            guard byteOffset + componentSize <= binary.count else { continue }
            let bytes = binary[byteOffset..<(byteOffset + componentSize)]
            switch componentType {
            case 5121: result[i] = UInt32(bytes.first ?? 0) // UNSIGNED_BYTE
            case 5123: result[i] = UInt32(bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }) // UNSIGNED_SHORT
            case 5125: result[i] = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } // UNSIGNED_INT
            default: break
            }
        }
        return result
    }

    private static func toVec3(_ flat: [Float]) -> [SIMD3<Float>] {
        stride(from: 0, to: flat.count, by: 3).map { SIMD3(flat[$0], flat[$0 + 1], flat[$0 + 2]) }
    }

    private static func toVec2(_ flat: [Float]) -> [SIMD2<Float>] {
        stride(from: 0, to: flat.count, by: 2).map { SIMD2(flat[$0], flat[$0 + 1]) }
    }

    // MARK: - material/texture (embedded 이미지만 지원, 외부 uri는 건너뜀)

    private static func readMaterial(
        _ material: [String: Any], into raw: inout RawPrimitive,
        textures: [[String: Any]], images: [[String: Any]], bufferViews: [[String: Any]], binary: Data?
    ) {
        guard let pbr = material["pbrMetallicRoughness"] as? [String: Any] else { return }
        if let factor = pbr["baseColorFactor"] as? [Double], factor.count >= 3 {
            raw.baseColorFactor = factor
        }
        if let textureRef = pbr["baseColorTexture"] as? [String: Any],
           let textureIndex = textureRef["index"] as? Int, textureIndex < textures.count,
           let sourceIndex = textures[textureIndex]["source"] as? Int, sourceIndex < images.count,
           let binary,
           let bytes = embeddedImageBytes(images[sourceIndex], bufferViews: bufferViews, binary: binary) {
            raw.imageData = bytes
            raw.imageMimeType = images[sourceIndex]["mimeType"] as? String ?? "image/png"
        }
    }

    private static func makeMaterial(_ raw: RawPrimitive) -> SCNMaterial {
        let scnMaterial = SCNMaterial()
        scnMaterial.lightingModel = .physicallyBased
        if let factor = raw.baseColorFactor, factor.count >= 3 {
            scnMaterial.diffuse.contents = UIColor(
                red: factor[0], green: factor[1], blue: factor[2], alpha: factor.count > 3 ? factor[3] : 1
            )
        }
        if let imageData = raw.imageData, let image = UIImage(data: imageData) {
            scnMaterial.diffuse.contents = image
        }
        return scnMaterial
    }

    private static func embeddedImageBytes(
        _ image: [String: Any], bufferViews: [[String: Any]], binary: Data
    ) -> Data? {
        guard let bufferViewIndex = image["bufferView"] as? Int, bufferViewIndex < bufferViews.count else { return nil }
        let bufferView = bufferViews[bufferViewIndex]
        let offset = bufferView["byteOffset"] as? Int ?? 0
        guard let length = bufferView["byteLength"] as? Int, offset + length <= binary.count else { return nil }
        return binary.subdata(in: offset..<(offset + length))
    }
}

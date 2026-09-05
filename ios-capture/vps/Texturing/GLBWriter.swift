import CoreGraphics
import Foundation
import UIKit

/// 최소 기능의 binary glTF(GLB) writer — mesh 하나에 primitive 여러 개, primitive마다 PBR
/// 머티리얼 하나(baseColorTexture), skinning/애니메이션/복수 노드 없음. `GLBLoader.swift`
/// (읽기 쪽, 이 앱에 이미 있음)가 파싱할 수 있는 정확히 그 부분집합만 만든다 — 서로
/// 대칭이 되도록 필드를 맞춰뒀다(GLBLoaderTests가 왕복으로 확인).
enum GLBWriter {
    enum WriteError: Error {
        case pngEncodingFailed
        case fileWriteFailed
        case noPrimitives
    }

    /// primitive 하나 = 정점 배열 + 텍스처 하나. `positions`/`normals`: vertexCount*3(xyz
    /// 연속, 인터리브 아님), `uvs`: vertexCount*2. `indices`가 nil이면 정점 순서대로
    /// 삼각형(TextureBaker의 다이아몬드 아틀라스는 face-corner마다 독립된 UV 정사각형을
    /// 써서 정점 공유가 없다). `imageData`는 이미 인코딩된 png/jpeg 바이트 -- 스캔별
    /// textured.glb의 텍스처를 다시 디코딩하지 않고 그대로 옮겨 담는다(TexturedGroupMerger).
    struct Primitive {
        var positions: [Float]
        var normals: [Float]
        var uvs: [Float]
        var indices: [UInt32]?
        var imageData: Data
        var imageMimeType: String
    }

    /// TextureBaker용 -- mesh 하나 + RGBA 텍스처 하나.
    static func write(
        positions: [Float], normals: [Float], uvs: [Float],
        textureRGBA: [UInt8], textureWidth: Int, textureHeight: Int,
        to url: URL
    ) throws {
        guard let pngData = encodePNG(rgba: textureRGBA, width: textureWidth, height: textureHeight) else {
            throw WriteError.pngEncodingFailed
        }
        try write(
            primitives: [Primitive(positions: positions, normals: normals, uvs: uvs, indices: nil, imageData: pngData, imageMimeType: "image/png")],
            to: url
        )
    }

    static func write(primitives: [Primitive], to url: URL) throws {
        guard !primitives.isEmpty else { throw WriteError.noPrimitives }

        var binary = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var images: [[String: Any]] = []
        var textures: [[String: Any]] = []
        var materials: [[String: Any]] = []
        var primitiveJSON: [[String: Any]] = []

        func addBufferView(_ data: Data, target: Int?) -> Int {
            let offset = binary.count
            binary.append(data)
            let padding = (4 - binary.count % 4) % 4
            binary.append(Data(repeating: 0, count: padding))
            var view: [String: Any] = ["buffer": 0, "byteOffset": offset, "byteLength": data.count]
            if let target { view["target"] = target }
            bufferViews.append(view)
            return bufferViews.count - 1
        }
        func addAccessor(_ accessor: [String: Any]) -> Int {
            accessors.append(accessor)
            return accessors.count - 1
        }

        for primitive in primitives {
            let vertexCount = primitive.positions.count / 3
            var minPos: [Float] = [.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude]
            var maxPos: [Float] = [-.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude]
            for i in 0..<vertexCount {
                for c in 0..<3 {
                    let v = primitive.positions[i * 3 + c]
                    minPos[c] = min(minPos[c], v)
                    maxPos[c] = max(maxPos[c], v)
                }
            }

            let positionView = addBufferView(bytes(primitive.positions), target: 34962)
            let normalView = addBufferView(bytes(primitive.normals), target: 34962)
            let uvView = addBufferView(bytes(primitive.uvs), target: 34962)
            let positionAccessor = addAccessor([
                "bufferView": positionView, "componentType": 5126, "count": vertexCount, "type": "VEC3",
                "min": minPos, "max": maxPos,
            ])
            let normalAccessor = addAccessor(["bufferView": normalView, "componentType": 5126, "count": vertexCount, "type": "VEC3"])
            let uvAccessor = addAccessor(["bufferView": uvView, "componentType": 5126, "count": vertexCount, "type": "VEC2"])

            var json: [String: Any] = [
                "attributes": ["POSITION": positionAccessor, "NORMAL": normalAccessor, "TEXCOORD_0": uvAccessor],
            ]
            if let indices = primitive.indices {
                let indexView = addBufferView(bytes(indices), target: 34963)
                json["indices"] = addAccessor(["bufferView": indexView, "componentType": 5125, "count": indices.count, "type": "SCALAR"])
            }

            let imageView = addBufferView(primitive.imageData, target: nil)
            images.append(["bufferView": imageView, "mimeType": primitive.imageMimeType])
            textures.append(["source": images.count - 1])
            materials.append([
                "pbrMetallicRoughness": [
                    "baseColorTexture": ["index": textures.count - 1],
                    "metallicFactor": 0.0,
                    "roughnessFactor": 1.0,
                ] as [String: Any],
            ])
            json["material"] = materials.count - 1
            primitiveJSON.append(json)
        }

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "dc-vps ios-capture"],
            "buffers": [["byteLength": binary.count]],
            "bufferViews": bufferViews,
            "accessors": accessors,
            "images": images,
            "textures": textures,
            "materials": materials,
            "meshes": [["primitives": primitiveJSON]],
            "nodes": [["mesh": 0]],
            "scenes": [["nodes": [0]]],
            "scene": 0,
        ]

        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [])
        let jsonPadding = (4 - jsonData.count % 4) % 4
        jsonData.append(Data(repeating: 0x20, count: jsonPadding)) // glTF 스펙: JSON 청크는 공백으로 패딩

        var container = Data()
        container.append(littleEndianBytes(UInt32(0x46546C67))) // "glTF"
        container.append(littleEndianBytes(UInt32(2))) // version
        let totalLength = 12 + 8 + jsonData.count + 8 + binary.count
        container.append(littleEndianBytes(UInt32(totalLength)))

        container.append(littleEndianBytes(UInt32(jsonData.count)))
        container.append(littleEndianBytes(UInt32(0x4E4F534A))) // "JSON"
        container.append(jsonData)

        container.append(littleEndianBytes(UInt32(binary.count)))
        container.append(littleEndianBytes(UInt32(0x004E4942))) // "BIN\0"
        container.append(binary)

        do {
            try container.write(to: url, options: .atomic)
        } catch {
            throw WriteError.fileWriteFailed
        }
    }

    private static func bytes<T>(_ values: [T]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func littleEndianBytes(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// RGBA8(비투명) 픽셀을 PNG 바이트로. TextureBaker 결과와 TexturedGroupMerger의
    /// 대체 텍스처(1x1 흰색)가 쓴다.
    static func encodePNG(rgba: [UInt8], width: Int, height: Int) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                  shouldInterpolate: false, intent: .defaultIntent
              )
        else { return nil }
        return UIImage(cgImage: cgImage).pngData()
    }
}

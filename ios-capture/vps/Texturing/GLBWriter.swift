import CoreGraphics
import Foundation
import UIKit

/// 최소 기능의 binary glTF(GLB) writer — mesh 하나, PBR 머티리얼 하나(baseColorTexture),
/// skinning/애니메이션/복수 노드 없음. `GLBLoader.swift`(읽기 전용, 이 앱에 이미 있음)가
/// 파싱할 수 있는 정확히 그 부분집합만 만든다 — 서로 대칭이 되도록 필드를 맞춰뒀다.
enum GLBWriter {
    enum WriteError: Error {
        case pngEncodingFailed
        case fileWriteFailed
    }

    /// `positions`/`normals`: length == vertexCount*3(xyz 연속, 인터리브 아님).
    /// `uvs`: length == vertexCount*2. 정점은 인덱스 공유 없이 순서대로 그대로 그린다 —
    /// 다이아몬드 아틀라스가 face-corner마다 독립된 UV 정사각형을 쓰기 때문에 정점을
    /// 공유할 수 없다(`TextureBaker`의 atlas-bake 패스용 버퍼를 그대로 재사용).
    static func write(
        positions: [Float], normals: [Float], uvs: [Float],
        textureRGBA: [UInt8], textureWidth: Int, textureHeight: Int,
        to url: URL
    ) throws {
        let vertexCount = positions.count / 3
        guard let pngData = encodePNG(rgba: textureRGBA, width: textureWidth, height: textureHeight) else {
            throw WriteError.pngEncodingFailed
        }

        var binary = Data()
        func appendPadded(_ data: Data) -> (offset: Int, length: Int) {
            let offset = binary.count
            binary.append(data)
            let padding = (4 - binary.count % 4) % 4
            binary.append(Data(repeating: 0, count: padding))
            return (offset, data.count)
        }

        let positionsData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let normalsData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
        let uvsData = uvs.withUnsafeBufferPointer { Data(buffer: $0) }

        let (posOffset, posLength) = appendPadded(positionsData)
        let (normOffset, normLength) = appendPadded(normalsData)
        let (uvOffset, uvLength) = appendPadded(uvsData)
        let (imgOffset, imgLength) = appendPadded(pngData)

        var minPos: [Float] = [.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude]
        var maxPos: [Float] = [-.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude]
        for i in 0..<vertexCount {
            for c in 0..<3 {
                let v = positions[i * 3 + c]
                minPos[c] = min(minPos[c], v)
                maxPos[c] = max(maxPos[c], v)
            }
        }

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "dc-vps ios-capture TextureBaker"],
            "buffers": [["byteLength": binary.count]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": posOffset, "byteLength": posLength, "target": 34962],
                ["buffer": 0, "byteOffset": normOffset, "byteLength": normLength, "target": 34962],
                ["buffer": 0, "byteOffset": uvOffset, "byteLength": uvLength, "target": 34962],
                ["buffer": 0, "byteOffset": imgOffset, "byteLength": imgLength],
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": vertexCount, "type": "VEC3", "min": minPos, "max": maxPos],
                ["bufferView": 1, "componentType": 5126, "count": vertexCount, "type": "VEC3"],
                ["bufferView": 2, "componentType": 5126, "count": vertexCount, "type": "VEC2"],
            ],
            "images": [["bufferView": 3, "mimeType": "image/png"]],
            "textures": [["source": 0]],
            "materials": [[
                "pbrMetallicRoughness": [
                    "baseColorTexture": ["index": 0],
                    "metallicFactor": 0.0,
                    "roughnessFactor": 1.0,
                ] as [String: Any],
            ]],
            "meshes": [[
                "primitives": [[
                    "attributes": ["POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2],
                    "material": 0,
                ]],
            ]],
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

    private static func littleEndianBytes(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func encodePNG(rgba: [UInt8], width: Int, height: Int) -> Data? {
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

import Foundation
import SceneKit

/// PCD(Point Cloud Data, PCL 포맷) 파서. `x y z`는 필수로 읽고, `rgb`/`rgba`
/// 필드가 있으면 색도 읽는다(PCL 관례대로 float 하나에 0x00RRGGBB를 비트
/// 그대로 박아넣은 것과, TYPE이 U일 때 packed uint32인 것 둘 다 지원).
/// `DATA ascii`/`DATA binary`만 지원한다 — `binary_compressed`는 LZF 압축 해제가
/// 필요해서 범위 밖으로 두고 명확한 에러를 낸다.
enum PCDLoader {
    enum LoadError: Error {
        case invalidHeader
        case missingXYZ
        case unsupportedCompression
    }

    private struct Field {
        let name: String
        let size: Int
        let type: Character // F(float) / U(unsigned) / I(signed)
        let count: Int
    }

    static func loadGeometry(at url: URL) throws -> SCNGeometry {
        let data = try Data(contentsOf: url)
        let (fields, pointCount, dataMode, headerEnd) = try parseHeader(data)

        guard let xField = fields.firstIndex(where: { $0.name == "x" }),
              let yField = fields.firstIndex(where: { $0.name == "y" }),
              let zField = fields.firstIndex(where: { $0.name == "z" })
        else { throw LoadError.missingXYZ }
        let colorField = fields.firstIndex { $0.name == "rgb" || $0.name == "rgba" }

        var positions = [SIMD3<Float>](repeating: .zero, count: pointCount)
        var colors: [SIMD3<UInt8>]? = colorField != nil ? [SIMD3<UInt8>](repeating: .zero, count: pointCount) : nil

        switch dataMode {
        case "ascii":
            let body = String(decoding: data[headerEnd...], as: UTF8.self)
            var index = 0
            for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
                guard index < pointCount else { break }
                let tokens = line.split(separator: " ")
                guard tokens.count >= fields.count,
                      let x = Float(tokens[xField]), let y = Float(tokens[yField]), let z = Float(tokens[zField])
                else { index += 1; continue }
                positions[index] = SIMD3(x, y, z)
                if let colorField, let raw = Float(tokens[colorField]) {
                    colors?[index] = unpackColor(bitPattern: raw.bitPattern)
                }
                index += 1
            }
        case "binary":
            var offset = headerEnd
            let pointStride = fields.reduce(0) { $0 + $1.size * $1.count }
            for index in 0..<pointCount {
                guard offset + pointStride <= data.count else { break }
                let pointStart = offset
                positions[index] = SIMD3(
                    readFloat(data, at: pointStart + fieldByteOffset(fields, upTo: xField)),
                    readFloat(data, at: pointStart + fieldByteOffset(fields, upTo: yField)),
                    readFloat(data, at: pointStart + fieldByteOffset(fields, upTo: zField))
                )
                if let colorField {
                    let bits = readUInt32(data, at: pointStart + fieldByteOffset(fields, upTo: colorField))
                    colors?[index] = unpackColor(bitPattern: bits)
                }
                offset += pointStride
            }
        default:
            throw LoadError.unsupportedCompression
        }

        return MeshGeometryBuilder.build(positions: positions, normals: nil, colors: colors, triangleIndices: [])
    }

    // MARK: - 헤더

    private static func parseHeader(_ data: Data) throws -> ([Field], Int, String, Int) {
        var fields: [Field] = []
        var sizes: [Int] = []
        var types: [Character] = []
        var counts: [Int] = []
        var pointCount = 0
        var dataMode = "ascii"

        var searchStart = data.startIndex
        while searchStart < data.endIndex {
            guard let newlineRange = data.range(of: Data([0x0A]), in: searchStart..<data.endIndex) else { break }
            let line = String(decoding: data[searchStart..<newlineRange.lowerBound], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            searchStart = newlineRange.upperBound

            let tokens = line.split(separator: " ").map(String.init)
            guard let keyword = tokens.first else { continue }

            switch keyword {
            case "FIELDS": fields = tokens.dropFirst().map { Field(name: $0, size: 4, type: "F", count: 1) }
            case "SIZE": sizes = tokens.dropFirst().compactMap { Int($0) }
            case "TYPE": types = tokens.dropFirst().compactMap { $0.first }
            case "COUNT": counts = tokens.dropFirst().compactMap { Int($0) }
            case "POINTS": pointCount = Int(tokens[safe: 1] ?? "") ?? 0
            case "DATA":
                dataMode = tokens[safe: 1] ?? "ascii"
                let merged = zip3(fields, sizes, types, counts)
                return (merged, pointCount, dataMode, searchStart)
            default: break
            }
        }
        throw LoadError.invalidHeader
    }

    private static func zip3(
        _ fields: [Field], _ sizes: [Int], _ types: [Character], _ counts: [Int]
    ) -> [Field] {
        fields.enumerated().map { i, field in
            Field(
                name: field.name,
                size: sizes[safe: i] ?? 4,
                type: types[safe: i] ?? "F",
                count: counts[safe: i] ?? 1
            )
        }
    }

    private static func fieldByteOffset(_ fields: [Field], upTo index: Int) -> Int {
        fields[..<index].reduce(0) { $0 + $1.size * $1.count }
    }

    // MARK: - 바이너리 읽기

    private static func readFloat(_ data: Data, at offset: Int) -> Float {
        guard offset + 4 <= data.count else { return 0 }
        return Float(bitPattern: readUInt32(data, at: offset))
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let bytes = data[offset..<(offset + 4)]
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    /// PCL 관례: rgb 필드는 float 하나에 0x00RRGGBB 비트를 그대로 박아넣는다.
    private static func unpackColor(bitPattern: UInt32) -> SIMD3<UInt8> {
        let r = UInt8((bitPattern >> 16) & 0xFF)
        let g = UInt8((bitPattern >> 8) & 0xFF)
        let b = UInt8(bitPattern & 0xFF)
        return SIMD3(r, g, b)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

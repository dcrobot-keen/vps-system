import Foundation
import SceneKit

/// PLY(Stanford Triangle Format) 파서 — SceneKit/ModelIO가 iOS에서 PLY를 못
/// 읽어서(usdz export 때 ModelIO 브릿지 API들이 이 SDK에 아예 없었던 전례가
/// 있어 미리 확인함) 직접 구현한다. ascii/binary_little_endian/
/// binary_big_endian 세 포맷 다 지원한다. vertex의 x/y/z(필수), nx/ny/nz(있으면
/// normal), red/green/blue(있으면 vertex color)만 읽는다 — 그 외 커스텀
/// property는 건너뛴다.
enum PLYLoader {
    enum LoadError: Error {
        case invalidHeader
        case unsupportedFormat
    }

    private struct Property {
        let name: String
        let type: ScalarType
        let isListCount: Bool // "property list <countType> <type> vertex_indices"의 count 타입
    }

    private enum ScalarType {
        case float, double, uchar, char, ushort, short, uint, int

        var byteCount: Int {
            switch self {
            case .float, .uint, .int: return 4
            case .double: return 8
            case .uchar, .char: return 1
            case .ushort, .short: return 2
            }
        }

        init?(_ token: String) {
            switch token {
            case "float", "float32": self = .float
            case "double", "float64": self = .double
            case "uchar", "uint8": self = .uchar
            case "char", "int8": self = .char
            case "ushort", "uint16": self = .ushort
            case "short", "int16": self = .short
            case "uint", "uint32": self = .uint
            case "int", "int32": self = .int
            default: return nil
            }
        }
    }

    private enum DataFormat {
        case ascii, binaryLittleEndian, binaryBigEndian
    }

    static func loadGeometry(at url: URL) throws -> SCNGeometry {
        let data = try Data(contentsOf: url)
        let (format, vertexCount, vertexProps, faceCountProp, faceIndexType, headerEnd) = try parseHeader(data)

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>]?
        var colors: [SIMD3<UInt8>]?
        var indices: [UInt32] = []

        switch format {
        case .ascii:
            let body = String(decoding: data[headerEnd...], as: UTF8.self)
            var lines = body.split(separator: "\n", omittingEmptySubsequences: true).makeIterator()
            (positions, normals, colors) = try parseAsciiVertices(&lines, count: vertexCount, props: vertexProps)
            indices = try parseAsciiFaces(&lines, count: faceCountProp)
        case .binaryLittleEndian, .binaryBigEndian:
            let bigEndian = (format == .binaryBigEndian)
            var offset = headerEnd
            (positions, normals, colors) = try parseBinaryVertices(
                data, offset: &offset, count: vertexCount, props: vertexProps, bigEndian: bigEndian
            )
            indices = try parseBinaryFaces(
                data, offset: &offset, count: faceCountProp, indexType: faceIndexType, bigEndian: bigEndian
            )
        }

        guard !positions.isEmpty else { throw LoadError.invalidHeader }
        return MeshGeometryBuilder.build(
            positions: positions, normals: normals, colors: colors, triangleIndices: indices
        )
    }

    // MARK: - 헤더 파싱

    private static func parseHeader(
        _ data: Data
    ) throws -> (DataFormat, Int, [Property], Int, ScalarType, Int) {
        guard let headerRange = data.range(of: Data("end_header\n".utf8)) else {
            throw LoadError.invalidHeader
        }
        let headerText = String(decoding: data[..<headerRange.lowerBound], as: UTF8.self)
        let lines = headerText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        var format: DataFormat = .ascii
        var vertexCount = 0
        var faceCount = 0
        var vertexProps: [Property] = []
        var faceIndexType: ScalarType = .int
        var inVertexElement = false
        var inFaceElement = false

        for line in lines {
            let tokens = line.split(separator: " ").map(String.init)
            guard let keyword = tokens.first else { continue }

            switch keyword {
            case "format":
                switch tokens[safe: 1] {
                case "ascii": format = .ascii
                case "binary_little_endian": format = .binaryLittleEndian
                case "binary_big_endian": format = .binaryBigEndian
                default: throw LoadError.unsupportedFormat
                }
            case "element":
                if tokens[safe: 1] == "vertex" {
                    vertexCount = Int(tokens[safe: 2] ?? "") ?? 0
                    inVertexElement = true; inFaceElement = false
                } else if tokens[safe: 1] == "face" {
                    faceCount = Int(tokens[safe: 2] ?? "") ?? 0
                    inVertexElement = false; inFaceElement = true
                } else {
                    inVertexElement = false; inFaceElement = false
                }
            case "property":
                if inVertexElement, tokens.count >= 3, let type = ScalarType(tokens[1]) {
                    vertexProps.append(Property(name: tokens[2], type: type, isListCount: false))
                } else if inFaceElement, tokens[safe: 1] == "list", tokens.count >= 5 {
                    faceIndexType = ScalarType(tokens[3]) ?? .int
                }
            default:
                break
            }
        }

        let headerEnd = headerRange.upperBound
        return (format, vertexCount, vertexProps, faceCount, faceIndexType, headerEnd)
    }

    // MARK: - ASCII 파싱

    private static func parseAsciiVertices(
        _ lines: inout IndexingIterator<[Substring]>, count: Int, props: [Property]
    ) throws -> ([SIMD3<Float>], [SIMD3<Float>]?, [SIMD3<UInt8>]?) {
        let xIdx = props.firstIndex { $0.name == "x" }
        let yIdx = props.firstIndex { $0.name == "y" }
        let zIdx = props.firstIndex { $0.name == "z" }
        let nxIdx = props.firstIndex { $0.name == "nx" }
        let nyIdx = props.firstIndex { $0.name == "ny" }
        let nzIdx = props.firstIndex { $0.name == "nz" }
        let rIdx = props.firstIndex { $0.name == "red" }
        let gIdx = props.firstIndex { $0.name == "green" }
        let bIdx = props.firstIndex { $0.name == "blue" }
        guard let xIdx, let yIdx, let zIdx else { throw LoadError.invalidHeader }

        var positions = [SIMD3<Float>](repeating: .zero, count: count)
        var normals = (nxIdx != nil && nyIdx != nil && nzIdx != nil)
            ? [SIMD3<Float>](repeating: .zero, count: count) : nil
        var colors = (rIdx != nil && gIdx != nil && bIdx != nil)
            ? [SIMD3<UInt8>](repeating: .zero, count: count) : nil

        for i in 0..<count {
            guard let line = lines.next() else { throw LoadError.invalidHeader }
            let values = line.split(separator: " ").compactMap { Float($0) }
            guard values.count >= props.count else { continue }
            positions[i] = SIMD3(values[xIdx], values[yIdx], values[zIdx])
            if let nxIdx, let nyIdx, let nzIdx {
                normals?[i] = SIMD3(values[nxIdx], values[nyIdx], values[nzIdx])
            }
            if let rIdx, let gIdx, let bIdx {
                colors?[i] = SIMD3(UInt8(values[rIdx]), UInt8(values[gIdx]), UInt8(values[bIdx]))
            }
        }
        return (positions, normals, colors)
    }

    private static func parseAsciiFaces(
        _ lines: inout IndexingIterator<[Substring]>, count: Int
    ) throws -> [UInt32] {
        var indices: [UInt32] = []
        for _ in 0..<count {
            guard let line = lines.next() else { break }
            let values = line.split(separator: " ").compactMap { Int($0) }
            guard let n = values.first, values.count >= n + 1 else { continue }
            let face = values[1...n].map { UInt32($0) }
            indices.append(contentsOf: MeshGeometryBuilder.fanTriangulate(face))
        }
        return indices
    }

    // MARK: - 바이너리 파싱

    private static func parseBinaryVertices(
        _ data: Data, offset: inout Int, count: Int, props: [Property], bigEndian: Bool
    ) throws -> ([SIMD3<Float>], [SIMD3<Float>]?, [SIMD3<UInt8>]?) {
        let xIdx = props.firstIndex { $0.name == "x" }
        let yIdx = props.firstIndex { $0.name == "y" }
        let zIdx = props.firstIndex { $0.name == "z" }
        let nxIdx = props.firstIndex { $0.name == "nx" }
        let nyIdx = props.firstIndex { $0.name == "ny" }
        let nzIdx = props.firstIndex { $0.name == "nz" }
        let rIdx = props.firstIndex { $0.name == "red" }
        let gIdx = props.firstIndex { $0.name == "green" }
        let bIdx = props.firstIndex { $0.name == "blue" }
        guard let xIdx, let yIdx, let zIdx else { throw LoadError.invalidHeader }
        let hasNormal = nxIdx != nil && nyIdx != nil && nzIdx != nil
        let hasColor = rIdx != nil && gIdx != nil && bIdx != nil

        var positions = [SIMD3<Float>](repeating: .zero, count: count)
        var normals = hasNormal ? [SIMD3<Float>](repeating: .zero, count: count) : nil
        var colors = hasColor ? [SIMD3<UInt8>](repeating: .zero, count: count) : nil

        for i in 0..<count {
            var values = [Float](repeating: 0, count: props.count)
            for (j, prop) in props.enumerated() {
                values[j] = readScalar(data, offset: &offset, type: prop.type, bigEndian: bigEndian)
            }
            positions[i] = SIMD3(values[xIdx], values[yIdx], values[zIdx])
            if hasNormal, let nxIdx, let nyIdx, let nzIdx {
                normals?[i] = SIMD3(values[nxIdx], values[nyIdx], values[nzIdx])
            }
            if hasColor, let rIdx, let gIdx, let bIdx {
                colors?[i] = SIMD3(UInt8(values[rIdx]), UInt8(values[gIdx]), UInt8(values[bIdx]))
            }
        }
        return (positions, normals, colors)
    }

    private static func parseBinaryFaces(
        _ data: Data, offset: inout Int, count: Int, indexType: ScalarType, bigEndian: Bool
    ) throws -> [UInt32] {
        var indices: [UInt32] = []
        for _ in 0..<count {
            guard offset < data.count else { break }
            let n = Int(readScalar(data, offset: &offset, type: .uchar, bigEndian: bigEndian))
            var face: [UInt32] = []
            for _ in 0..<n {
                face.append(UInt32(readScalar(data, offset: &offset, type: indexType, bigEndian: bigEndian)))
            }
            indices.append(contentsOf: MeshGeometryBuilder.fanTriangulate(face))
        }
        return indices
    }

    /// 어떤 스칼라 타입이든 Float로 통일해서 읽는다(색/인덱스는 호출부에서 반올림/캐스팅).
    private static func readScalar(_ data: Data, offset: inout Int, type: ScalarType, bigEndian: Bool) -> Float {
        let size = type.byteCount
        guard offset + size <= data.count else { offset += size; return 0 }
        var bytes = [UInt8](data[offset..<(offset + size)])
        if bigEndian { bytes.reverse() }
        offset += size

        switch type {
        case .float:
            let bits = bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
            return Float(bitPattern: bits)
        case .double:
            let bits = bytes.withUnsafeBytes { $0.load(as: UInt64.self) }
            return Float(Double(bitPattern: bits))
        case .uchar: return Float(bytes[0])
        case .char: return Float(Int8(bitPattern: bytes[0]))
        case .ushort:
            let v = bytes.withUnsafeBytes { $0.load(as: UInt16.self) }
            return Float(v)
        case .short:
            let v = bytes.withUnsafeBytes { $0.load(as: Int16.self) }
            return Float(v)
        case .uint:
            let v = bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
            return Float(v)
        case .int:
            let v = bytes.withUnsafeBytes { $0.load(as: Int32.self) }
            return Float(v)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

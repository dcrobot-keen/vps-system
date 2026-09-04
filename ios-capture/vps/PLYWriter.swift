import Foundation
import simd

/// PLY(Stanford Triangle Format) writer — binary_little_endian만 만든다(ASCII float
/// 왕복/정밀도 걱정이 없고 더 간결함). `PLYLoader.swift`(읽기)가 파싱할 수 있는
/// 정확히 그 부분집합만 쓴다 -- vertex(x,y,z, 있으면 nx,ny,nz), face(list uchar int
/// vertex_indices)만. 색은 안 넣는다(이 앱의 무채색 mesh export 방침, MeshExporter
/// 참고) -- 프로젝트 합치기 export용으로 처음 만드는 것이라 우선 제일 단순한 형태로.
enum PLYWriter {
    enum WriteError: Error {
        case fileWriteFailed
    }

    /// `indices`가 비어있으면(포인트 클라우드) face element를 아예 안 쓴다.
    static func write(positions: [SIMD3<Float>], normals: [SIMD3<Float>]?, indices: [UInt32], to url: URL) throws {
        let hasNormals = normals != nil && normals?.count == positions.count
        let faceCount = indices.count / 3

        var header = "ply\nformat binary_little_endian 1.0\n"
        header += "element vertex \(positions.count)\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        if hasNormals {
            header += "property float nx\nproperty float ny\nproperty float nz\n"
        }
        if faceCount > 0 {
            header += "element face \(faceCount)\n"
            header += "property list uchar int vertex_indices\n"
        }
        header += "end_header\n"

        var data = Data(header.utf8)
        data.reserveCapacity(data.count + positions.count * (hasNormals ? 24 : 12) + faceCount * 13)

        for i in 0..<positions.count {
            appendFloatLE(positions[i].x, to: &data)
            appendFloatLE(positions[i].y, to: &data)
            appendFloatLE(positions[i].z, to: &data)
            if hasNormals, let normals {
                appendFloatLE(normals[i].x, to: &data)
                appendFloatLE(normals[i].y, to: &data)
                appendFloatLE(normals[i].z, to: &data)
            }
        }

        var f = 0
        while f + 2 < indices.count {
            data.append(3) // vertex_indices list count (uchar) -- 항상 삼각형
            appendInt32LE(Int32(bitPattern: indices[f]), to: &data)
            appendInt32LE(Int32(bitPattern: indices[f + 1]), to: &data)
            appendInt32LE(Int32(bitPattern: indices[f + 2]), to: &data)
            f += 3
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw WriteError.fileWriteFailed
        }
    }

    private static func appendFloatLE(_ value: Float, to data: inout Data) {
        var v = value
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendInt32LE(_ value: Int32, to data: inout Data) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}

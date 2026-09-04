import Foundation
import simd

/// PCD(Point Cloud Data, PCL 포맷) writer — `DATA binary`만 만든다. `PCDLoader.swift`
/// (읽기)가 파싱하는 x/y/z 3개 float 필드만 쓴다 -- PCD는 원래 포인트 전용 포맷이라
/// mesh 위상(face)은 담지 않는다(그게 필요하면 PLY/GLB export를 쓰면 됨).
enum PCDWriter {
    enum WriteError: Error {
        case fileWriteFailed
    }

    static func write(positions: [SIMD3<Float>], to url: URL) throws {
        var header = "# .PCD v0.7 - Point Cloud Data\n"
        header += "VERSION 0.7\n"
        header += "FIELDS x y z\n"
        header += "SIZE 4 4 4\n"
        header += "TYPE F F F\n"
        header += "COUNT 1 1 1\n"
        header += "WIDTH \(positions.count)\n"
        header += "HEIGHT 1\n"
        header += "VIEWPOINT 0 0 0 1 0 0 0\n"
        header += "POINTS \(positions.count)\n"
        header += "DATA binary\n"

        var data = Data(header.utf8)
        data.reserveCapacity(data.count + positions.count * 12)
        for p in positions {
            appendFloatLE(p.x, to: &data)
            appendFloatLE(p.y, to: &data)
            appendFloatLE(p.z, to: &data)
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
}

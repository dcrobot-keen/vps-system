import CoreVideo
import Foundation

/// `scan_<name>/depth/*.depth`, `*.conf`의 v2 인코딩(vps-system/scan-format/SCAN_FORMAT.md).
///
/// - `.depth`: uint16 little-endian 밀리미터, `0` = 미측정. LiDAR 정밀도가 cm급이라 mm
///   양자화는 손실이 아니고, 범위는 65.5 m.
/// - `.conf`: uint8 0/1/2 -- ARKit `confidenceMap`(OneComponent8) 원본 그대로.
///
/// v1(둘 다 float32)은 프레임당 393 KB, v2는 147 KB. 방 하나(750프레임)에 약 180 MB가
/// 줄어든다. 읽는 쪽(`pipeline/scan_loader.py`, `dc-vps-digital-twin/convert_to_colmap.py`)은
/// 파일 크기와 manifest의 `depth_encoding`으로 두 버전을 구분한다. 순수 함수는
/// `DepthEncodingTests`가, CVPixelBuffer 래퍼는 `ScanSessionManager.saveDepth`가 쓴다.
enum DepthEncoding {
    static let formatVersion = 2
    static let depthName = "uint16_mm"
    static let confidenceName = "uint8"

    /// 미터 -> 밀리미터 uint16. NaN/무한/0 이하는 미측정(0), 65.535 m 초과는 클램프.
    static func millimetres(_ metres: Float) -> UInt16 {
        guard metres.isFinite, metres > 0 else { return 0 }
        return UInt16(min(metres * 1000, 65535).rounded())
    }

    /// float32 미터 배열 -> little-endian uint16 mm 바이트.
    static func encodeDepth(_ metres: [Float]) -> Data {
        var values = [UInt16](repeating: 0, count: metres.count)
        for (i, m) in metres.enumerated() { values[i] = millimetres(m).littleEndian }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// manifest.json의 `depth_encoding` 항목.
    static func manifestEntry(width: Int, height: Int) -> [String: Any] {
        [
            "format_version": formatVersion,
            "width": width,
            "height": height,
            "depth": depthName,
            "confidence": confidenceName,
        ]
    }

    /// Float32 CVPixelBuffer(행 패딩 있을 수 있음) -> 빈틈없는 uint16 mm Data. 잠금은 호출자가.
    static func encodeDepth(lockedPixelBuffer pb: CVPixelBuffer) -> Data? {
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        var values = [UInt16](repeating: 0, count: width * height)
        for row in 0..<height {
            let rowPtr = (base + row * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for col in 0..<width { values[row * width + col] = millimetres(rowPtr[col]).littleEndian }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// OneComponent8 CVPixelBuffer -> 빈틈없는 uint8 Data. 잠금은 호출자가.
    static func encodeConfidence(lockedPixelBuffer pb: CVPixelBuffer) -> Data? {
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        var data = Data(capacity: width * height)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height { data.append(ptr + row * bytesPerRow, count: width) }
        return data
    }
}

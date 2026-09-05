import XCTest
@testable import vps

/// depth/*.depth, *.conf v2 인코딩(scan-format/SCAN_FORMAT.md)의 순수 부분을 고정한다 --
/// 읽는 쪽(pipeline/scan_loader.py)이 "uint16 little-endian mm, 0 = 미측정"과
/// manifest의 depth_encoding 키 이름을 그대로 가정하므로 여기서 어긋나면 DB 빌드가
/// 조용히 틀어진다.
final class DepthEncodingTests: XCTestCase {
    func testMillimetresRoundsClampsAndMarksInvalidAsZero() {
        XCTAssertEqual(DepthEncoding.millimetres(1.2345), 1235)   // 반올림
        XCTAssertEqual(DepthEncoding.millimetres(0.0004), 0)      // 0.4 mm -> 0 (미측정과 구분 안 함, 범위 밖)
        XCTAssertEqual(DepthEncoding.millimetres(0), 0)
        XCTAssertEqual(DepthEncoding.millimetres(-1), 0)
        XCTAssertEqual(DepthEncoding.millimetres(.nan), 0)
        XCTAssertEqual(DepthEncoding.millimetres(.infinity), 0)
        XCTAssertEqual(DepthEncoding.millimetres(70), 65535)      // 클램프
    }

    func testEncodeDepthIsLittleEndianUInt16PerSample() {
        let data = DepthEncoding.encodeDepth([0.001, 1.0, 65.535, .nan])
        XCTAssertEqual(data.count, 8)
        XCTAssertEqual([UInt8](data), [0x01, 0x00, 0xE8, 0x03, 0xFF, 0xFF, 0x00, 0x00])
    }

    func testManifestEntryMatchesTheSchemaKeys() {
        let e = DepthEncoding.manifestEntry(width: 256, height: 192)
        XCTAssertEqual(e["format_version"] as? Int, 2)
        XCTAssertEqual(e["width"] as? Int, 256)
        XCTAssertEqual(e["height"] as? Int, 192)
        XCTAssertEqual(e["depth"] as? String, "uint16_mm")
        XCTAssertEqual(e["confidence"] as? String, "uint8")
        XCTAssertEqual(Set(e.keys), ["format_version", "width", "height", "depth", "confidence"])
    }

    func testManifestCarriesDepthEncodingOnlyWhenGiven() {
        let with = ScanRecordBuilder.buildManifest(
            sessionName: "s", deviceModel: "d", systemVersion: "v", startTime: 0, endTime: 1, frameCount: 1,
            captureIntervalSeconds: 0.1, captureMinDistanceMeters: 0.2,
            depthEncoding: DepthEncoding.manifestEntry(width: 256, height: 192)
        )
        XCTAssertNotNil(with["depth_encoding"])
        let without = ScanRecordBuilder.buildManifest(
            sessionName: "s", deviceModel: "d", systemVersion: "v", startTime: 0, endTime: 1, frameCount: 0,
            captureIntervalSeconds: 0.1, captureMinDistanceMeters: 0.2
        )
        XCTAssertNil(without["depth_encoding"])
    }

    func testEncodesAPaddedFloat32PixelBuffer() throws {
        var pb: CVPixelBuffer?
        // 폭 3, 높이 2, Float32 -- CoreVideo가 행을 패딩할 수 있어 bytesPerRow > 12
        XCTAssertEqual(CVPixelBufferCreate(nil, 3, 2, kCVPixelFormatType_DepthFloat32, nil, &pb), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let values: [Float32] = [0.5, 1.0, 1.5, 2.0, 2.5, .nan]
        for row in 0..<2 {
            let rowPtr = (base + row * bpr).assumingMemoryBound(to: Float32.self)
            for col in 0..<3 { rowPtr[col] = values[row * 3 + col] }
        }
        let encoded = DepthEncoding.encodeDepth(lockedPixelBuffer: buffer)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let data = try XCTUnwrap(encoded)
        XCTAssertEqual(data.count, 12)
        let mm = data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)).map { UInt16(littleEndian: $0) } }
        XCTAssertEqual(mm, [500, 1000, 1500, 2000, 2500, 0])
    }
}

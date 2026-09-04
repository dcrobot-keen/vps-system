import XCTest
@testable import vps

/// `ZipArchiver`는 압축 없이 저장(store)만 하는 최소 zip writer라, 그 반대쪽(reader)도
/// 여기서 직접 최소하게 구현해서 왕복 검증한다 -- 외부 압축 라이브러리 없이 만든
/// 코드이므로 시스템 unzip 대신 같은 포맷 정의를 그대로 마주 보고 검증하는 게 맞다.
final class ZipArchiverTests: XCTestCase {
    private var sourceDir: URL!
    private var zipURL: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        sourceDir = root.appendingPathComponent("scan_test")
        zipURL = root.appendingPathComponent("out.zip")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sourceDir.deletingLastPathComponent())
    }

    func testZipRoundTripsFileNamesAndContentExactly() throws {
        let manifestData = Data("{\"frame_count\": 3}".utf8)
        try manifestData.write(to: sourceDir.appendingPathComponent("manifest.json"))

        let rgbDir = sourceDir.appendingPathComponent("rgb")
        try FileManager.default.createDirectory(at: rgbDir, withIntermediateDirectories: true)
        let frameData = Data((0..<5000).map { UInt8($0 % 256) }) // 압축 없이도 큰 편인 바이너리 데이터
        try frameData.write(to: rgbDir.appendingPathComponent("frame_00001.jpg"))

        try ZipArchiver.zip(directory: sourceDir, to: zipURL)

        let zipData = try Data(contentsOf: zipURL)
        let entries = try MinimalZipReader.readEntries(from: zipData)

        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        XCTAssertEqual(entries.count, 2)

        let manifestEntry = try XCTUnwrap(byName["manifest.json"])
        XCTAssertEqual(manifestEntry.data, manifestData)
        XCTAssertEqual(manifestEntry.crc32, MinimalZipReader.crc32(manifestData))

        let frameEntry = try XCTUnwrap(byName["rgb/frame_00001.jpg"])
        XCTAssertEqual(frameEntry.data, frameData)
        XCTAssertEqual(frameEntry.crc32, MinimalZipReader.crc32(frameData))
    }

    func testZipOfEmptyDirectoryProducesZeroEntries() throws {
        try ZipArchiver.zip(directory: sourceDir, to: zipURL)
        let zipData = try Data(contentsOf: zipURL)
        let entries = try MinimalZipReader.readEntries(from: zipData)
        XCTAssertTrue(entries.isEmpty)
    }
}

/// `ZipArchiver`가 쓰는 것과 정확히 같은 최소 포맷(로컬 헤더 연속, store 방식, 압축
/// 없음)만 읽을 수 있는 대응 리더. 이 테스트 파일 밖에서는 안 쓴다.
private enum MinimalZipReader {
    struct Entry {
        let name: String
        let data: Data
        let crc32: UInt32
    }

    enum ReadError: Error {
        case truncated
        case badSignature
    }

    static func readEntries(from zipData: Data) throws -> [Entry] {
        var entries: [Entry] = []
        var offset = 0
        while offset + 4 <= zipData.count {
            let signature = zipData.readUInt32LE(at: offset)
            if signature == 0x0201_4b50 || signature == 0x0605_4b50 {
                break // 중앙 디렉터리/끝 레코드에 도달 -- 로컬 엔트리는 다 읽음
            }
            guard signature == 0x0403_4b50 else { throw ReadError.badSignature }
            guard offset + 30 <= zipData.count else { throw ReadError.truncated }

            let crc = zipData.readUInt32LE(at: offset + 14)
            let compressedSize = Int(zipData.readUInt32LE(at: offset + 18))
            let nameLength = Int(zipData.readUInt16LE(at: offset + 26))
            let extraLength = Int(zipData.readUInt16LE(at: offset + 28))

            let nameStart = offset + 30
            let nameEnd = nameStart + nameLength
            guard nameEnd <= zipData.count else { throw ReadError.truncated }
            let name = String(decoding: zipData[nameStart..<nameEnd], as: UTF8.self)

            let dataStart = nameEnd + extraLength
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= zipData.count else { throw ReadError.truncated }
            let content = zipData.subdata(in: dataStart..<dataEnd)

            entries.append(Entry(name: name, data: content, crc32: crc))
            offset = dataEnd
        }
        return entries
    }

    private static let table: [UInt32] = (0...255).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    /// `ZipArchiver`의 private CRC32와 별개로 독립 구현 -- 같은 버그를 그대로
    /// 복붙해서 "검증"하는 꼴을 피한다(알고리즘 자체는 표준 CRC-32/ISO-HDLC라 같을
    /// 수밖에 없지만, 최소한 다른 코드 경로로 계산한다).
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(readUInt16LE(at: offset)) | (UInt32(readUInt16LE(at: offset + 2)) << 16)
    }
}

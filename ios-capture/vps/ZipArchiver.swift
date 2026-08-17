import Foundation

/// scan_<name>/ 폴더를 외부 라이브러리 없이 zip으로 묶기 위한 최소 구현.
/// 모든 엔트리는 무압축(store)으로 저장한다 — JPEG/raw float 데이터는 deflate로도
/// 별 이득이 없고, 구현/검증 비용 대비 안정성을 우선했다.
enum ZipArchiver {
    enum ZipError: Error {
        case enumerationFailed
    }

    static func zip(directory: URL, to destinationURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        fm.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]
        ) else {
            throw ZipError.enumerationFailed
        }

        var centralDirectory = Data()
        var offset: UInt32 = 0
        var entryCount: UInt16 = 0
        // iOS의 Documents 경로는 /var/... 로 시작하지만 /var는 /private/var의 심볼릭
        // 링크다. enumerator가 반환하는 fileURL은 이미 심볼릭 링크가 풀린 형태라서,
        // 풀리지 않은 directory.path를 기준으로 문자열 접두사를 제거하면 "/private"만
        // 남아 "privaterrgb" 같은 이름이 만들어진다. 두 URL을 모두 resolvingSymlinksInPath()로
        // 정규화한 뒤 path component 개수로 상대경로를 계산해 이 불일치를 피한다.
        let baseComponents = directory.resolvingSymlinksInPath().pathComponents

        for case let fileURL as URL in enumerator {
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
            if isDirectory.boolValue { continue }

            let resolvedComponents = fileURL.resolvingSymlinksInPath().pathComponents
            let relativePath = resolvedComponents.dropFirst(baseComponents.count).joined(separator: "/")
            let fileData = try Data(contentsOf: fileURL)
            let crc = CRC32.checksum(fileData)
            let nameBytes = Array(relativePath.utf8)
            let (dosTime, dosDate) = dosDateTime(for: fileURL)

            var localHeader = Data()
            localHeader.append(uint32: 0x0403_4b50)
            localHeader.append(uint16: 20) // version needed to extract
            localHeader.append(uint16: 0) // flags
            localHeader.append(uint16: 0) // method: store
            localHeader.append(uint16: dosTime)
            localHeader.append(uint16: dosDate)
            localHeader.append(uint32: crc)
            localHeader.append(uint32: UInt32(fileData.count))
            localHeader.append(uint32: UInt32(fileData.count))
            localHeader.append(uint16: UInt16(nameBytes.count))
            localHeader.append(uint16: 0) // extra field length
            localHeader.append(contentsOf: nameBytes)

            handle.write(localHeader)
            handle.write(fileData)

            var centralEntry = Data()
            centralEntry.append(uint32: 0x0201_4b50)
            centralEntry.append(uint16: 20) // version made by
            centralEntry.append(uint16: 20) // version needed to extract
            centralEntry.append(uint16: 0) // flags
            centralEntry.append(uint16: 0) // method
            centralEntry.append(uint16: dosTime)
            centralEntry.append(uint16: dosDate)
            centralEntry.append(uint32: crc)
            centralEntry.append(uint32: UInt32(fileData.count))
            centralEntry.append(uint32: UInt32(fileData.count))
            centralEntry.append(uint16: UInt16(nameBytes.count))
            centralEntry.append(uint16: 0) // extra field length
            centralEntry.append(uint16: 0) // comment length
            centralEntry.append(uint16: 0) // disk number start
            centralEntry.append(uint16: 0) // internal attrs
            centralEntry.append(uint32: 0) // external attrs
            centralEntry.append(uint32: offset)
            centralEntry.append(contentsOf: nameBytes)

            centralDirectory.append(centralEntry)

            offset += UInt32(localHeader.count + fileData.count)
            entryCount += 1
        }

        let centralDirectoryOffset = offset
        handle.write(centralDirectory)

        var endRecord = Data()
        endRecord.append(uint32: 0x0605_4b50)
        endRecord.append(uint16: 0) // disk number
        endRecord.append(uint16: 0) // disk with central dir start
        endRecord.append(uint16: entryCount)
        endRecord.append(uint16: entryCount)
        endRecord.append(uint32: UInt32(centralDirectory.count))
        endRecord.append(uint32: centralDirectoryOffset)
        endRecord.append(uint16: 0) // comment length

        handle.write(endRecord)
    }

    private static func dosDateTime(for url: URL) -> (UInt16, UInt16) {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        let year = max((comps.year ?? 1980) - 1980, 0)
        let dosDate = UInt16((year << 9) | ((comps.month ?? 1) << 5) | (comps.day ?? 1))
        let dosTime = UInt16(((comps.hour ?? 0) << 11) | ((comps.minute ?? 0) << 5) | ((comps.second ?? 0) / 2))
        return (dosTime, dosDate)
    }
}

private enum CRC32 {
    static let table: [UInt32] = (0...255).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(uint32 value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

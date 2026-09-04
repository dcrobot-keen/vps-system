import XCTest
@testable import vps

/// `availableBytes()`는 실제 볼륨 상태에 의존해서 의미 있게 테스트할 수 없다 --
/// `directorySizeBytes(at:)`만 검증한다(순수 파일시스템 I/O, 임시 폴더로 재현 가능).
final class DeviceStorageTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDirectorySizeBytesSumsAllFilesRecursively() throws {
        try Data(repeating: 0, count: 100).write(to: tempDir.appendingPathComponent("a.bin"))
        let subdir = tempDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 250).write(to: subdir.appendingPathComponent("b.bin"))

        let size = DeviceStorage.directorySizeBytes(at: tempDir)
        // totalFileAllocatedSize는 파일시스템 블록 단위로 올림되므로 정확히 350은
        // 아닐 수 있다(그래서 project.pbxproj가 아니라 여기서만 씀) -- 최소 350바이트
        // 이상이어야 하고, 100배 넘게 부풀지는 않아야 한다는 정도로 검증한다.
        XCTAssertGreaterThanOrEqual(size, 350)
        XCTAssertLessThan(size, 350 * 100)
    }

    func testDirectorySizeBytesIsZeroForEmptyDirectory() {
        XCTAssertEqual(DeviceStorage.directorySizeBytes(at: tempDir), 0)
    }

    func testDirectorySizeBytesIsZeroForMissingDirectory() {
        let missing = tempDir.appendingPathComponent("does-not-exist")
        XCTAssertEqual(DeviceStorage.directorySizeBytes(at: missing), 0)
    }
}

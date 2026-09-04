import XCTest
@testable import vps

@MainActor
final class ScanGroupStoreTests: XCTestCase {
    private var indexURL: URL!

    override func setUpWithError() throws {
        indexURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: indexURL)
    }

    func testCreateGroupPersistsAndReloadsAcrossInstances() {
        let store = ScanGroupStore(indexURL: indexURL)
        store.refresh() // 파일이 아직 없음 -- 빈 목록으로 시작해야 함
        XCTAssertTrue(store.groups.isEmpty)

        let created = store.createGroup(name: "우리집 1층")
        XCTAssertEqual(store.groups.count, 1)

        // 새 인스턴스(같은 indexURL)로 다시 읽어도 그대로 남아있어야 한다.
        let reloaded = ScanGroupStore(indexURL: indexURL)
        reloaded.refresh()
        XCTAssertEqual(reloaded.groups.count, 1)
        XCTAssertEqual(reloaded.groups.first?.id, created.id)
        XCTAssertEqual(reloaded.groups.first?.name, "우리집 1층")
        XCTAssertEqual(reloaded.groups.first?.scanIDs, [])
    }

    func testAddScanAppendsInOrderAndTracksLatest() {
        let store = ScanGroupStore(indexURL: indexURL)
        let group = store.createGroup(name: "테스트")

        store.addScan(scanID: "scan_A", to: group.id)
        store.addScan(scanID: "scan_B", to: group.id)

        let updated = store.groups.first { $0.id == group.id }
        XCTAssertEqual(updated?.scanIDs, ["scan_A", "scan_B"])
        XCTAssertEqual(updated?.latestScanID, "scan_B")
    }

    func testAddScanIsIdempotentForTheSameScanID() {
        let store = ScanGroupStore(indexURL: indexURL)
        let group = store.createGroup(name: "테스트")
        store.addScan(scanID: "scan_A", to: group.id)
        store.addScan(scanID: "scan_A", to: group.id)
        XCTAssertEqual(store.groups.first?.scanIDs, ["scan_A"])
    }

    func testGroupExistsNamedMatchesCurrentGroups() {
        let store = ScanGroupStore(indexURL: indexURL)
        store.createGroup(name: "거실")
        XCTAssertTrue(store.groupExists(named: "거실"))
        XCTAssertFalse(store.groupExists(named: "안방"))
    }

    func testDeleteGroupRemovesItFromPersistedIndex() {
        let store = ScanGroupStore(indexURL: indexURL)
        let group = store.createGroup(name: "삭제될 것")
        store.deleteGroup(group)
        XCTAssertTrue(store.groups.isEmpty)

        let reloaded = ScanGroupStore(indexURL: indexURL)
        reloaded.refresh()
        XCTAssertTrue(reloaded.groups.isEmpty)
    }
}

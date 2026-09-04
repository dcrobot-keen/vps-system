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

    func testSetAlignmentsPersistsAndRemoveScanDropsIts() {
        let store = ScanGroupStore(indexURL: indexURL)
        let group = store.createGroup(name: "정렬")
        store.addScan(scanID: "scan_A", to: group.id)
        store.addScan(scanID: "scan_B", to: group.id)
        store.setAlignments(["scan_B": ScanAlignment(offsetX: 1, offsetZ: 2, yawRadians: 0.5)], for: group.id)

        let reloaded = ScanGroupStore(indexURL: indexURL)
        reloaded.refresh()
        let g = reloaded.groups.first { $0.id == group.id }
        XCTAssertEqual(g?.alignment(for: "scan_B"), ScanAlignment(offsetX: 1, offsetZ: 2, yawRadians: 0.5))
        XCTAssertEqual(g?.alignment(for: "scan_A"), .identity) // 없으면 identity

        reloaded.removeScan(scanID: "scan_B", from: group.id)
        let after = reloaded.groups.first { $0.id == group.id }
        XCTAssertEqual(after?.scanIDs, ["scan_A"])
        XCTAssertEqual(after?.alignment(for: "scan_B"), .identity)
    }

    /// alignments는 나중에 추가된 필드 -- 그 전에 저장된 파일(키 없음)도 읽혀야 한다.
    func testSetAlignmentUpdatesOnlyThatScanAndPersists() {
        let store = ScanGroupStore(indexURL: indexURL)
        let group = store.createGroup(name: "집")
        store.addScan(scanID: "scan_a", to: group.id)
        store.addScan(scanID: "scan_b", to: group.id)
        let a = ScanAlignment(offsetX: 1, offsetZ: 2, yawRadians: 0.3)
        store.setAlignments(["scan_a": a], for: group.id)

        let b = ScanAlignment(offsetX: -4, offsetZ: 0.5, yawRadians: -1.2)
        store.setAlignment(b, for: "scan_b", in: group.id)

        let reloaded = ScanGroupStore(indexURL: indexURL)
        reloaded.refresh()
        XCTAssertEqual(reloaded.groups.first?.alignment(for: "scan_a"), a)
        XCTAssertEqual(reloaded.groups.first?.alignment(for: "scan_b"), b)
    }

    func testDecodesLegacyIndexWithoutAlignmentsKey() throws {
        let legacy = """
        [{"id":"g1","name":"옛 프로젝트","scanIDs":["scan_A"],"createdAt":"2026-09-04T00:00:00Z"}]
        """
        try Data(legacy.utf8).write(to: indexURL)
        let store = ScanGroupStore(indexURL: indexURL)
        store.refresh()
        XCTAssertEqual(store.groups.count, 1)
        XCTAssertEqual(store.groups.first?.scanIDs, ["scan_A"])
        XCTAssertEqual(store.groups.first?.alignments, [:])
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

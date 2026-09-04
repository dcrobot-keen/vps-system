import XCTest
@testable import vps

/// 백그라운드 업로드 자체(진짜 네트워크 + OS 백그라운드 세션 재연결)는 이 환경에서
/// 검증할 수 없다 -- `upload_status.json` 영속화/로드 왕복만 확인한다. `persistUploadOutcome`은
/// `fileprivate`라 여기서 직접 못 부르니, 실제로 그게 쓰는 것과 같은 형식(status/error
/// 키)의 파일을 직접 만들어서 `loadPersistedUploadOutcome`/`clearPersistedUploadOutcome`
/// 쪽만 검증한다.
final class VPSUploadClientTests: XCTestCase {
    private var projectURL: URL!

    override func setUpWithError() throws {
        projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func writeOutcomeFile(_ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        try data.write(to: projectURL.appendingPathComponent("upload_status.json"))
    }

    func testLoadsAcceptedOutcome() throws {
        try writeOutcomeFile(["status": "accepted"])
        let outcome = try XCTUnwrap(VPSUploadClient.loadPersistedUploadOutcome(projectURL: projectURL))
        XCTAssertEqual(outcome.status, "accepted")
        XCTAssertNil(outcome.errorMessage)
    }

    func testLoadsFailedOutcomeWithErrorMessage() throws {
        try writeOutcomeFile(["status": "failed", "error": "네트워크 오류"])
        let outcome = try XCTUnwrap(VPSUploadClient.loadPersistedUploadOutcome(projectURL: projectURL))
        XCTAssertEqual(outcome.status, "failed")
        XCTAssertEqual(outcome.errorMessage, "네트워크 오류")
    }

    func testReturnsNilWhenNoOutcomeFileExists() {
        XCTAssertNil(VPSUploadClient.loadPersistedUploadOutcome(projectURL: projectURL))
    }

    func testClearRemovesTheFileSoItIsNotReadTwice() throws {
        try writeOutcomeFile(["status": "accepted"])
        VPSUploadClient.clearPersistedUploadOutcome(projectURL: projectURL)
        XCTAssertNil(VPSUploadClient.loadPersistedUploadOutcome(projectURL: projectURL))
    }
}

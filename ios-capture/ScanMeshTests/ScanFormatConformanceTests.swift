import XCTest
@testable import vps

/// 스캔 포맷 회귀 게이트 -- PRODUCT-PLAN.md의 필수 항목. 이 앱은 vps-system/
/// dc-vps-digital-twin/pathfinder/ros-chromium까지 이어지는 파이프라인 전체의
/// 유일한 캡처 헤드라, `manifest.json`/`poses.jsonl`의 키 하나가 조용히
/// 빠지거나 이름이 바뀌면 하류 전부가 깨진다. 정본은 `vps-system/scan-format/
/// *.schema.json`(item ④)이고, 그 정본을 직접 읽어 `ScanRecordBuilder`(실제
/// 프로덕션 코드, ScanSessionManager가 그대로 씀)의 출력과 대조한다 -- 스키마
/// 쪽만 갱신되고 앱이 안 따라가거나, 그 반대인 경우 둘 다 여기서 잡힌다.
///
/// CI에서는 이 테스트가 만드는 fixture 스캔 폴더에 `scan-format/
/// conformance_check.py`를 추가로 돌려 Python 소비자 쪽에서도 이중 확인한다
/// (PRODUCT-PLAN.md "CI" 항목 참고, 아직 미배선).
final class ScanFormatConformanceTests: XCTestCase {
    private func loadSchema(_ name: String) throws -> [String: Any] {
        // #filePath: 이 테스트 파일의 컴파일 시점 소스 경로
        // (.../vps-system/ios-capture/vpsTests/ScanFormatConformanceTests.swift).
        // deletingLastPathComponent()를 세 번(파일명 제거 -> vpsTests 제거 ->
        // ios-capture 제거) 적용하면 vps-system/에 도착하고, 그 아래 scan-format/이
        // 정본이다 -- pathfinder의 JS 스모크 테스트가 형제 저장소를 상대경로로
        // 참조하는 것과 같은 패턴.
        let vpsSystemDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // 파일명 제거 -> vpsTests/
            .deletingLastPathComponent() // vpsTests 제거 -> ios-capture/
            .deletingLastPathComponent() // ios-capture 제거 -> vps-system/
        let scanFormatDir = vpsSystemDir.appendingPathComponent("scan-format")
        let data = try Data(contentsOf: scanFormatDir.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func roundTripped(_ json: [String: Any]) throws -> [String: Any] {
        // JSONSerialization을 왕복시켜서 실제 저장 경로(디스크에 쓰고 서버/파이프라인이
        // 다시 읽는 것)와 같은 값 표현(Int vs Double 등)으로 검증한다.
        let data = try JSONSerialization.data(withJSONObject: json)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testManifestMatchesSchema() throws {
        let manifest = ScanRecordBuilder.buildManifest(
            sessionName: "scan_test",
            deviceModel: "iPhone15,3",
            systemVersion: "18.0",
            startTime: 1_725_000_000,
            endTime: 1_725_000_060,
            frameCount: 42,
            captureIntervalSeconds: 0.1,
            captureMinDistanceMeters: 0.2
        )
        let schema = try loadSchema("manifest.schema.json")
        let violations = MiniSchemaValidator.violations(of: try roundTripped(manifest), against: schema)
        XCTAssertTrue(violations.isEmpty, violations.joined(separator: "; "))
    }

    func testPoseRecordMatchesSchema() throws {
        let record = ScanRecordBuilder.buildPoseRecord(
            frameId: 1,
            timestamp: 12.34,
            rgbPath: "rgb/frame_00001.jpg",
            depthPath: "depth/frame_00001.depth",
            cameraTransform: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]],
            intrinsics: (fx: 1450, fy: 1450, cx: 960, cy: 540, width: 1920, height: 1440),
            trackingState: "normal"
        )
        let schema = try loadSchema("pose-record.schema.json")
        let violations = MiniSchemaValidator.violations(of: try roundTripped(record), against: schema)
        XCTAssertTrue(violations.isEmpty, violations.joined(separator: "; "))
    }

    func testTrackingStateValuesMatchSchemaEnum() throws {
        // ScanSessionManager.trackingStateString()이 실제로 만들 수 있는 값 전부
        // (normal/notAvailable/limited)가 스키마의 enum과 정확히 일치해야 한다 --
        // 한쪽만 갱신되는 드리프트를 잡는다.
        let schema = try loadSchema("pose-record.schema.json")
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let trackingStateSchema = try XCTUnwrap(properties["tracking_state"] as? [String: Any])
        let allowed = try XCTUnwrap(trackingStateSchema["enum"] as? [String])
        XCTAssertEqual(Set(allowed), ["normal", "notAvailable", "limited"])
    }
}

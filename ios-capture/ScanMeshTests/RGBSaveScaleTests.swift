import XCTest
@testable import vps

/// 저장 RGB 해상도(긴 변 1600)와 intrinsics 배율이 같은 값에서 나오는지 고정한다 --
/// 어긋나면 파이프라인의 keypoint -> depth 정합이 조용히 틀어진다.
final class RGBSaveScaleTests: XCTestCase {
    func testIPhoneCaptureIsScaledToSixteenHundredWide() {
        let f = RGBSaveScale.factor(for: CGSize(width: 1920, height: 1440))
        XCTAssertEqual(f, 1600.0 / 1920.0, accuracy: 1e-9)
        let size = RGBSaveScale.savedSize(for: CGSize(width: 1920, height: 1440))
        XCTAssertEqual(size.width, 1600)
        XCTAssertEqual(size.height, 1200)
    }

    func testSmallerCapturesAreNotUpscaled() {
        XCTAssertEqual(RGBSaveScale.factor(for: CGSize(width: 1280, height: 960)), 1)
        let size = RGBSaveScale.savedSize(for: CGSize(width: 1280, height: 960))
        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 960)
    }

    func testIntrinsicsScaleWithTheImage() {
        let f = RGBSaveScale.factor(for: CGSize(width: 1920, height: 1440))
        let k = RGBSaveScale.scaledIntrinsics(fx: 1440.25, fy: 1440.25, cx: 965.578, cy: 719.765, factor: f)
        XCTAssertEqual(k.fx, 1440.25 * 1600 / 1920, accuracy: 1e-3)
        XCTAssertEqual(k.cx, 965.578 * 1600 / 1920, accuracy: 1e-3)
        XCTAssertEqual(k.cy, 719.765 * 1600 / 1920, accuracy: 1e-3)
        // the principal point stays at the same relative position in the frame
        XCTAssertEqual(Double(k.cx) / 1600, 965.578 / 1920, accuracy: 1e-6)
    }
}

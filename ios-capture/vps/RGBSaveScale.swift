import CoreGraphics
import Foundation

/// 저장하는 RGB 프레임의 해상도 규칙: 긴 변 1600 px.
///
/// 카메라는 1920×1440으로 주지만 VPS DB 빌드(hloc `superpoint_inloc`)는 긴 변을 1600으로
/// 리사이즈해서 특징점을 뽑으므로, 1920으로 저장하는 건 파이프라인이 곧 버릴 픽셀을
/// 디스크에 쓰는 셈이었다(프레임당 약 500 KB → 200 KB, 2026-09-05 실측). 저장 해상도가
/// 바뀌면 `poses.jsonl`의 intrinsics(fx, fy, cx, cy, width, height)도 **같은 배율로**
/// 기록해야 한다 -- 소비자(pipeline `scan_loader`, dc-vps-digital-twin)는 레코드의
/// width/height로 depth 배율을 계산한다. 이 두 계산이 한 곳에서 나오게 여기 모았다.
enum RGBSaveScale {
    static let longSidePixels: CGFloat = 1600

    /// 캡처 해상도 -> 저장 배율(≤ 1). 긴 변이 이미 1600 이하면 1(확대는 안 한다).
    static func factor(for resolution: CGSize) -> CGFloat {
        let long = max(resolution.width, resolution.height)
        guard long > longSidePixels, long > 0 else { return 1 }
        return longSidePixels / long
    }

    /// 실제로 저장되는 이미지 크기.
    static func savedSize(for resolution: CGSize) -> (width: Int, height: Int) {
        let f = factor(for: resolution)
        return (Int((resolution.width * f).rounded()), Int((resolution.height * f).rounded()))
    }

    /// 캡처 해상도 기준 intrinsics -> 저장 해상도 기준 intrinsics.
    static func scaledIntrinsics(fx: Float, fy: Float, cx: Float, cy: Float, factor: CGFloat) -> (fx: Float, fy: Float, cx: Float, cy: Float) {
        let f = Float(factor)
        return (fx * f, fy * f, cx * f, cy * f)
    }
}

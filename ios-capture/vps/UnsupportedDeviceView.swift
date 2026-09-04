import ARKit
import SwiftUI

/// 이 앱의 핵심(스캔)은 LiDAR가 있어야만 된다. App Store 심사 기준상 미지원
/// 기기에서 기능이 조용히 죽으면 리젝 사유라, 앱 진입 시점에 한 번 확인해서
/// 안 되는 기기에는 이유와 지원 기기 목록을 보여준다. `UIRequiredDeviceCapabilities`
/// 에는 "lidar" 같은 키가 없어서(arkit만 있음) 런타임 확인이 유일한 방법이다.
enum DeviceSupport {
    /// `ScanSessionManager.startSession`이 실제로 요구하는 것과 같은 조건 —
    /// sceneDepth(LiDAR depth) + sceneReconstruction(mesh). 둘 중 하나라도 없으면
    /// rgb/depth/poses도 scan.usdz도 못 만든다.
    static var isScanningSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics([.sceneDepth, .smoothedSceneDepth])
            && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }
}

struct UnsupportedDeviceView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("이 기기에서는 스캔할 수 없습니다")
                .font(.title3.weight(.semibold))
            Text("3D 공간 스캔에는 LiDAR 센서가 필요합니다. iPhone 12 Pro 이후의 Pro/Pro Max 모델, 2020년 이후의 iPad Pro에서 사용할 수 있습니다.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

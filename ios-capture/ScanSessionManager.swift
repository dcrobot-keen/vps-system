import ARKit
import Foundation

/// RGB + LiDAR depth + confidence + ARKit pose(6DoF)를 프레임 단위로 동기화해서
/// scan_<name>/ 폴더에 저장한다. 좌표계는 raw(landscape) 방향을 그대로 유지하고
/// 회전 보정은 하지 않는다 — depth/confidence/keypoint 정합은 Python DB 빌드
/// 단계에서 일괄 처리한다.
class ScanSessionManager: NSObject, ARSessionDelegate {
    let session = ARSession()
    var frameIndex = 0
    let outputDir: URL
    var posesFile: FileHandle!

    private var lastCaptureTimestamp: TimeInterval = 0
    private var lastCameraPosition: simd_float3?
    private let captureIntervalSeconds: TimeInterval = 0.4
    private let captureMinDistanceMeters: Float = 0.2

    init(outputDir: URL) {
        self.outputDir = outputDir
        super.init()
    }

    func startSession() {
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = [] // 메시 불필요, depth만 사용
        config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        session.delegate = self
        session.run(config)
    }

    func stopSession() {
        session.pause()
        try? posesFile.close()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard shouldCapture(frame) else { return }
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }

        frameIndex += 1
        saveRGB(frame.capturedImage, index: frameIndex)
        saveDepth(depthData.depthMap, confidenceMap: depthData.confidenceMap, index: frameIndex)
        appendPose(frame: frame, index: frameIndex)
    }

    /// 시간 간격(0.4s) 또는 이동거리(0.2m) 기준으로 프레임을 샘플링한다.
    /// 60fps 그대로 저장하면 몇 분 스캔에도 수만 장이 쌓이므로 스로틀링이 필수다.
    private func shouldCapture(_ frame: ARFrame) -> Bool {
        guard frame.camera.trackingState == .normal else { return false }

        let elapsed = frame.timestamp - lastCaptureTimestamp
        let position = simd_float3(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        let distance = lastCameraPosition.map { simd_distance($0, position) } ?? .greatestFiniteMagnitude

        guard elapsed >= captureIntervalSeconds || distance >= captureMinDistanceMeters else {
            return false
        }

        lastCaptureTimestamp = frame.timestamp
        lastCameraPosition = position
        return true
    }

    private func saveRGB(_ pixelBuffer: CVPixelBuffer, index: Int) {
        // TODO: CVPixelBuffer(YCbCr) -> JPEG 인코딩 후 rgb/frame_XXXXX.jpg로 저장
    }

    private func saveDepth(_ depthMap: CVPixelBuffer, confidenceMap: CVPixelBuffer?, index: Int) {
        // TODO: Float32 raw depth를 depth/frame_XXXXX.depth로 저장 (width x height, row-major)
        // confidenceMap이 있으면 depth/frame_XXXXX.conf로 함께 저장
    }

    func appendPose(frame: ARFrame, index: Int) {
        let t = frame.camera.transform // camera-to-world 4x4
        let intr = frame.camera.intrinsics // 3x3, raw(landscape) 기준
        let resolution = frame.camera.imageResolution

        let record: [String: Any] = [
            "frame_id": index,
            "timestamp": frame.timestamp,
            "rgb_path": "rgb/frame_\(paddedIndex(index)).jpg",
            "depth_path": "depth/frame_\(paddedIndex(index)).depth",
            "camera_transform": matrixToArray(t),
            "intrinsics": [
                "fx": intr[0, 0],
                "fy": intr[1, 1],
                "cx": intr[2, 0],
                "cy": intr[2, 1],
                "width": Int(resolution.width),
                "height": Int(resolution.height),
            ],
            "tracking_state": trackingStateString(frame.camera.trackingState),
        ]

        guard let json = try? JSONSerialization.data(withJSONObject: record) else { return }
        posesFile.write(json)
        posesFile.write("\n".data(using: .utf8)!)
    }

    private func paddedIndex(_ index: Int) -> String {
        String(format: "%05d", index)
    }

    private func matrixToArray(_ m: simd_float4x4) -> [[Float]] {
        [
            [m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x],
            [m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y],
            [m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z],
            [0, 0, 0, 1],
        ]
    }

    private func trackingStateString(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "notAvailable"
        case .limited: return "limited"
        }
    }
}

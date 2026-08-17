import ARKit
import Combine
import CoreImage
import Foundation
import UIKit

/// RGB + LiDAR depth + confidence + ARKit pose(6DoF)를 프레임 단위로 동기화해서
/// scan_<name>/ 폴더에 저장한다. 좌표계는 raw(landscape) 방향을 그대로 유지하고
/// 회전 보정은 하지 않는다 — depth/confidence/keypoint 정합은 Python DB 빌드
/// 단계에서 일괄 처리한다.
final class ScanSessionManager: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()

    @Published private(set) var isRunning = false
    @Published private(set) var frameCount = 0
    @Published private(set) var statusMessage = "대기 중"
    @Published private(set) var lastOutputDir: URL?

    private var frameIndex = 0
    private var sessionName = ""
    private var outputDir: URL!
    private var rgbDir: URL!
    private var depthDir: URL!
    private var posesFile: FileHandle!
    private var sessionStartTime: Date?

    private var lastCaptureTimestamp: TimeInterval = 0
    private var lastCameraPosition: simd_float3?
    private let captureIntervalSeconds: TimeInterval = 0.4
    private let captureMinDistanceMeters: Float = 0.2

    private let ciContext = CIContext()

    override init() {
        super.init()
        session.delegate = self
    }

    /// 캡처 시작 전, 프리뷰만 보여주기 위한 가벼운 세션. sceneDepth는 켜지 않는다.
    func startPreview() {
        guard !isRunning else { return }
        let config = ARWorldTrackingConfiguration()
        session.run(config)
    }

    func startSession(name: String) {
        guard !isRunning else { return }
        guard ARWorldTrackingConfiguration.supportsFrameSemantics([.sceneDepth, .smoothedSceneDepth]) else {
            statusMessage = "이 기기는 LiDAR(sceneDepth)를 지원하지 않습니다"
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionName = trimmedName.isEmpty ? ISO8601DateFormatter().string(from: Date()) : trimmedName
        frameIndex = 0
        lastCaptureTimestamp = 0
        lastCameraPosition = nil
        sessionStartTime = Date()

        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        outputDir = documentsDir.appendingPathComponent("scan_\(sessionName)")
        rgbDir = outputDir.appendingPathComponent("rgb")
        depthDir = outputDir.appendingPathComponent("depth")
        let posesDir = outputDir.appendingPathComponent("poses")

        let fm = FileManager.default
        try? fm.createDirectory(at: rgbDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: depthDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: posesDir, withIntermediateDirectories: true)

        let posesURL = posesDir.appendingPathComponent("poses.jsonl")
        fm.createFile(atPath: posesURL.path, contents: nil)
        posesFile = try? FileHandle(forWritingTo: posesURL)

        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = [] // 메시 불필요, depth만 사용
        config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        session.run(config, options: [.resetTracking, .removeExistingAnchors])

        isRunning = true
        frameCount = 0
        statusMessage = "캡처 중"
    }

    func stopSession() {
        guard isRunning else { return }
        session.pause()
        try? posesFile.close()
        writeManifest()
        isRunning = false
        lastOutputDir = outputDir
        statusMessage = "정지됨 (\(frameCount) 프레임, \(outputDir.lastPathComponent))"
    }

    /// scan_<name>/ 폴더를 zip으로 묶어 반환한다. 완료 콜백은 메인 스레드에서 호출된다.
    func exportZip(completion: @escaping (URL?) -> Void) {
        guard let dir = lastOutputDir else {
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let zipURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(dir.lastPathComponent + ".zip")
            do {
                try ZipArchiver.zip(directory: dir, to: zipURL)
                DispatchQueue.main.async { completion(zipURL) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRunning, shouldCapture(frame) else { return }
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }

        frameIndex += 1
        let index = frameIndex
        saveRGB(frame.capturedImage, index: index)
        saveDepth(depthData.depthMap, confidenceMap: depthData.confidenceMap, index: index)
        appendPose(frame: frame, index: index)

        DispatchQueue.main.async { [weak self] in
            self?.frameCount = index
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.statusMessage = "세션 오류: \(error.localizedDescription)"
        }
    }

    // MARK: - Capture throttling

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

    // MARK: - Frame saving

    private func saveRGB(_ pixelBuffer: CVPixelBuffer, index: Int) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpegData = ciContext.jpegRepresentation(
                  of: ciImage,
                  colorSpace: colorSpace,
                  options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85]
              )
        else { return }

        let url = rgbDir.appendingPathComponent("frame_\(paddedIndex(index)).jpg")
        try? jpegData.write(to: url)
    }

    private func saveDepth(_ depthMap: CVPixelBuffer, confidenceMap: CVPixelBuffer?, index: Int) {
        writeRawFloat32(depthMap, to: depthDir.appendingPathComponent("frame_\(paddedIndex(index)).depth"))
        if let confidenceMap {
            // confidenceMap은 OneComponent8(UInt8, 0=low/1=medium/2=high)로 나오지만
            // pipeline의 load_depth_raw가 depth와 동일하게 float32로 읽으므로
            // 저장 단계에서 float32로 변환해 둔다.
            writeConfidenceAsFloat32(confidenceMap, to: depthDir.appendingPathComponent("frame_\(paddedIndex(index)).conf"))
        }
    }

    private func writeRawFloat32(_ pixelBuffer: CVPixelBuffer, to url: URL) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let tightRowBytes = width * MemoryLayout<Float32>.size

        var data = Data(capacity: tightRowBytes * height)
        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            data.append(ptr + row * bytesPerRow, count: tightRowBytes)
        }
        try? data.write(to: url)
    }

    private func writeConfidenceAsFloat32(_ pixelBuffer: CVPixelBuffer, to url: URL) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

        var floatValues = [Float32](repeating: 0, count: width * height)
        for row in 0..<height {
            let rowBase = row * bytesPerRow
            for col in 0..<width {
                floatValues[row * width + col] = Float32(ptr[rowBase + col])
            }
        }
        let data = floatValues.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: url)
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

    // MARK: - manifest.json

    private func writeManifest() {
        guard let start = sessionStartTime, let outputDir = outputDir else { return }
        let manifest: [String: Any] = [
            "session_name": outputDir.lastPathComponent,
            "device_model": deviceModelIdentifier(),
            "system_version": UIDevice.current.systemVersion,
            "start_time": start.timeIntervalSince1970,
            "end_time": Date().timeIntervalSince1970,
            "frame_count": frameIndex,
            "capture_interval_seconds": captureIntervalSeconds,
            "capture_min_distance_meters": captureMinDistanceMeters,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) else { return }
        try? data.write(to: outputDir.appendingPathComponent("manifest.json"))
    }

    private func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result += String(UnicodeScalar(UInt8(value)))
        }
    }

    // MARK: - Helpers

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

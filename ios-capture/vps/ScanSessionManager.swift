import ARKit
import Combine
import CoreImage
import Foundation
import SceneKit
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
    /// 스캔 중 실시간으로 보여줄 짧은 안내 문구(트래킹 불안정, 거리, 텍스처 커버리지,
    /// 구역 분할 제안 등). nil이면 특별히 알릴 게 없는 정상 상태. VPS DB 품질/텍스처
    /// 품질에 실제로 영향을 준다고 실측/조사로 확인된 것들만 넣는다(아래
    /// updateGuidance 참고).
    @Published private(set) var guidanceMessage: String?

    private var frameIndex = 0
    private var sessionName = ""
    private var outputDir: URL!
    private var rgbDir: URL!
    private var depthDir: URL!
    private var posesFile: FileHandle!
    private var sessionStartTime: Date?

    private var lastCaptureTimestamp: TimeInterval = 0
    private var lastCameraPosition: simd_float3?
    private let captureIntervalSeconds: TimeInterval = 0.1
    private let captureMinDistanceMeters: Float = 0.2

    /// 최근 저장된 프레임들의 카메라 위치(월드 좌표). 텍스처 커버리지 안내용 —
    /// isCameraStationary 참고. 저장되는 프레임에서만 채우므로(모든 ARFrame이
    /// 아니라) TextureBaker가 실제로 쓰는 카메라 집합과 일치한다.
    private var recentCameraPositions: [simd_float3] = []

    // MARK: - 스캔 가이드 임계값
    //
    // VPS DB 품질/텍스처 품질에 실제로 영향을 준다고 확인된 것들만 넣었다:
    // - 트래킹 상태: shouldCapture()가 이미 tracking != .normal인 프레임을 버리고
    //   있다 — 사용자가 "왜 프레임이 안 늘어나지"를 깨닫게 실시간으로 알려준다.
    // - 거리: pipeline/dc_vps_pipeline/config.py의 MAX_DEPTH_METERS(5.0)와 맞춰
    //   여유를 둔 값 — 너무 가깝거나 멀면 그 지점의 depth가 backproject 단계에서
    //   버려져 3D 포인트가 아예 안 생긴다.
    // - 텍스처 커버리지: 온디바이스 텍스처 베이킹(TextureBaker)은 각 표면을 여러
    //   각도에서 본 사진 중 제일 정면에 가까운 걸 골라 쓴다 — 카메라가 같은 자리에서
    //   거의 안 움직이면 표면 대부분이 딱 한 각도(종종 사각/그레이징 각)로만 찍혀서
    //   텍스처가 흐릿하거나 이음새가 남는다. 최근 windowFrameCount 프레임의 카메라
    //   위치가 stationaryRadiusMeters 반경 안에 몰려 있으면 "움직이면서 찍으라"고
    //   안내한다.
    // - 구역 분할 제안: 707프레임짜리 긴 스캔에서 ARKit 트래킹 드리프트가 누적돼
    //   앞/뒤 프레임 사이에 실제 기하 오차가 생기는 걸 실측으로 확인했다(2026-08-22).
    //   한 room(강체 공간) 단위로 짧게 끊는 게 길게 이어 찍는 것보다 일관적이다.
    //   텍스처 커버리지와는 별개 문제라 메시지를 분리했다 — 이건 지오메트리 정확도.
    private static let minGuidanceDepthMeters: Float = 0.3
    private static let maxGuidanceDepthMeters: Float = 4.5
    private static let textureCoverageWindowFrameCount = 60
    private static let textureCoverageStationaryRadiusMeters: Float = 0.4
    private static let wrapUpSuggestionFrameCount = 300

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
        recentCameraPositions = []
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
        // scan.usdz export용 mesh. classification이 되면(벽/바닥/천장 자동 분류) 그걸
        // 쓰고, 안 되면 mesh만이라도 켠다 — 둘 다 LiDAR 기기면 보통 지원되지만
        // 기기별로 다를 수 있어 방어적으로 확인한다.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
            print("[mesh] meshWithClassification 사용")
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            print("[mesh] mesh 사용 (classification 미지원)")
        } else {
            print("[mesh] 이 기기는 sceneReconstruction을 지원하지 않음 -- scan.usdz 안 나옴")
        }
        config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        session.run(config, options: [.resetTracking, .removeExistingAnchors])

        isRunning = true
        frameCount = 0
        statusMessage = "캡처 중"
        guidanceMessage = nil
    }

    func stopSession() {
        guard isRunning else { return }
        // pause() 이후에도 currentFrame이 남아있을 걸로 기대하기보다, 살아있는
        // 상태에서 mesh anchor를 먼저 확보해둔다.
        let meshAnchors = session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        print("[mesh] stopSession 시점 anchor 개수: \(meshAnchors.count), "
            + "총 vertex 수: \(meshAnchors.reduce(0) { $0 + $1.geometry.vertices.count })")
        statusMessage = "저장 중..."

        // getCurrentWorldMap은 세션이 아직 running 상태일 때 호출해야 한다 -- 먼저
        // pause()부터 하면 재국지화에 쓸 특징점이 덜 확보된 상태로 지도가 얼어붙을
        // 수 있다. 콜백(스레드 보장 없음)을 받은 뒤에야 pause()/나머지 정리를 한다.
        session.getCurrentWorldMap { [weak self] worldMap, error in
            DispatchQueue.main.async {
                self?.finishStopSession(meshAnchors: meshAnchors, worldMap: worldMap, worldMapError: error)
            }
        }
    }

    private func finishStopSession(meshAnchors: [ARMeshAnchor], worldMap: ARWorldMap?, worldMapError: Error?) {
        session.pause()
        try? posesFile.close()
        writeManifest()
        let meshStatus = exportMesh(meshAnchors)
        let worldMapStatus = exportWorldMap(worldMap, error: worldMapError)
        isRunning = false
        guidanceMessage = nil
        lastOutputDir = outputDir
        statusMessage = "정지됨 (\(frameCount) 프레임, \(outputDir.lastPathComponent))\(meshStatus)\(worldMapStatus)"
    }

    /// scan.usdz로 내보낸다 (scan-to-map-studio --usdz 입력용, 지도화/robot 연동 트랙).
    /// VPS용 rgb/depth/poses는 이 결과와 무관하게 이미 저장 완료된 상태다. 화면에 바로
    /// 보이도록 결과를 statusMessage에 붙일 문자열로 반환한다.
    ///
    /// 색/텍스처는 넣지 않는다 — Digital Twin급 시각화(사진 기반 텍스처링, 나아가
    /// Gaussian Splatting)는 별도 프로젝트(GPU 서버 트랙)로 분리했고, 이 앱은 VPS와
    /// 지도화에 필요한 raw 데이터(rgb/depth/poses)와 무채색 mesh만 책임진다.
    private func exportMesh(_ meshAnchors: [ARMeshAnchor]) -> String {
        guard let outputDir else { return "" }
        guard !meshAnchors.isEmpty else {
            print("[mesh] mesh anchor가 0개 -- sceneReconstruction이 이 세션에서 활성화 안 됐거나 "
                + "너무 짧게 스캔해서 ARKit이 mesh를 아직 못 만든 상태")
            return ", mesh 없음"
        }
        let usdzURL = outputDir.appendingPathComponent("scan.usdz")
        do {
            try MeshExporter.export(meshAnchors: meshAnchors, to: usdzURL)
            print("[mesh] scan.usdz 저장 완료: \(usdzURL.path)")
            return ", scan.usdz 저장됨"
        } catch {
            print("[mesh] scan.usdz export 실패: \(error)")
            return ", mesh export 실패(\(error.localizedDescription))"
        }
    }

    /// 재국지화(LocalizeSessionManager)가 나중에 initialWorldMap으로 로드해서 "지금
    /// 이 스캔 공간의 어디쯤인가"를 서버 없이 온디바이스로 확인하는 데 쓰는 핵심
    /// 산출물. rgb/depth/poses(VPS DB 빌드용)와는 독립된 산출물이라 이게 실패해도
    /// 스캔 결과 자체는 무사하다.
    private func exportWorldMap(_ worldMap: ARWorldMap?, error: Error?) -> String {
        guard let outputDir else { return "" }
        guard let worldMap else {
            print("[worldmap] getCurrentWorldMap 실패: \(error?.localizedDescription ?? "알 수 없는 오류")")
            return ", 위치확인용 지도 저장 실패"
        }
        let url = outputDir.appendingPathComponent("worldmap.arexperience")
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
            try data.write(to: url)
            print("[worldmap] worldmap.arexperience 저장 완료 (\(data.count) bytes, anchor \(worldMap.anchors.count)개)")
            return ", 위치확인용 지도 저장됨"
        } catch {
            print("[worldmap] worldmap 저장 실패: \(error)")
            return ", 위치확인용 지도 저장 실패(\(error.localizedDescription))"
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // 캡처 스로틀링과 무관하게 매 프레임 갱신한다 — "왜 프레임이 안 늘어나지"를
        // 스로틀링 때문인지 트래킹 문제 때문인지 실시간으로 구분해서 알려줘야 한다.
        if isRunning { updateGuidance(frame: frame) }

        guard isRunning, shouldCapture(frame) else { return }
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }

        frameIndex += 1
        let index = frameIndex
        saveRGB(frame.capturedImage, index: index)
        saveDepth(depthData.depthMap, confidenceMap: depthData.confidenceMap, index: index)
        appendPose(frame: frame, index: index)

        recentCameraPositions.append(simd_float3(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        ))
        if recentCameraPositions.count > Self.textureCoverageWindowFrameCount {
            recentCameraPositions.removeFirst()
        }

        DispatchQueue.main.async { [weak self] in
            self?.frameCount = index
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.statusMessage = "세션 오류: \(error.localizedDescription)"
        }
    }

    // MARK: - 스캔 가이드

    /// 트래킹 상태 -> 거리 -> 텍스처 커버리지 -> 구역 분할 제안 순으로 확인해서
    /// 지금 제일 급한 안내 하나만 고른다(트래킹이 안 좋으면 프레임 자체가 안 찍히니
    /// 제일 급함). 텍스처 커버리지를 구역 분할 제안보다 먼저 보는 이유: 제자리에서만
    /// 찍어서 프레임 수만 채운 상태로 "이제 충분해요"를 먼저 보여주면 텍스처 품질
    /// 문제를 놓치고 그냥 저장하게 된다 — 움직이라는 안내가 더 급하다.
    private func updateGuidance(frame: ARFrame) {
        let message: String?
        switch frame.camera.trackingState {
        case .notAvailable:
            message = "트래킹 준비 중..."
        case .limited(.initializing):
            message = "초기화 중 — 천천히 주변을 비춰주세요"
        case .limited(.relocalizing):
            message = "재추적 중..."
        case .limited(.excessiveMotion):
            message = "너무 빨라요 — 천천히 움직여주세요"
        case .limited(.insufficientFeatures):
            message = "특징이 뚜렷한 곳(가구, 표지판 등)을 비춰주세요"
        case .limited:
            message = "트래킹이 불안정해요"
        case .normal:
            if let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth,
               let depth = Self.centerDepthMeters(depthData.depthMap) {
                if depth < Self.minGuidanceDepthMeters {
                    message = "너무 가까워요 — 조금 물러나주세요"
                } else if depth > Self.maxGuidanceDepthMeters {
                    message = "너무 멀어요 — 조금 다가가주세요"
                } else if isCameraStationary {
                    message = "이 자리에서만 찍고 있어요 — 조금씩 움직이며 여러 각도로 봐야 텍스처가 선명해져요"
                } else if frameCount >= Self.wrapUpSuggestionFrameCount {
                    message = "이 구역은 트래킹 오차가 쌓이기 쉬워요 — 저장하고 새 구역으로 이어가면 더 정확해요"
                } else {
                    message = nil
                }
            } else {
                message = nil
            }
        }

        guard message != guidanceMessage else { return }
        DispatchQueue.main.async { [weak self] in
            self?.guidanceMessage = message
        }
    }

    /// 최근 window 프레임 동안 카메라가 한 자리(반경 stationaryRadiusMeters 안)에
    /// 머물러 있었는지 — 텍스처 베이킹은 각 표면을 여러 각도에서 찍은 사진 중 제일
    /// 정면에 가까운 걸 고르므로, 카메라가 안 움직이면 대부분의 표면이 한 각도로만
    /// 찍혀 텍스처 품질이 떨어진다. window가 아직 안 찼으면(스캔 시작 직후) 판단을
    /// 미룬다 — 초반부터 "움직이세요"를 띄우면 오히려 헷갈린다.
    private var isCameraStationary: Bool {
        guard recentCameraPositions.count >= Self.textureCoverageWindowFrameCount else { return false }
        let centroid = recentCameraPositions.reduce(simd_float3.zero, +) / Float(recentCameraPositions.count)
        let maxRadius = recentCameraPositions.reduce(Float(0)) { max($0, simd_distance($1, centroid)) }
        return maxRadius < Self.textureCoverageStationaryRadiusMeters
    }

    /// depth map 중앙 픽셀의 거리(m)를 읽는다. LiDAR depth는 Float32 CVPixelBuffer.
    private static func centerDepthMeters(_ depthMap: CVPixelBuffer) -> Float? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let rowPointer = base.advanced(by: (height / 2) * bytesPerRow)
        let value = rowPointer.assumingMemoryBound(to: Float32.self)[width / 2]
        guard value.isFinite, value > 0 else { return nil }
        return value
    }

    // MARK: - Capture throttling

    /// 시간 간격(0.1s) 또는 이동거리(0.2m) 기준으로 프레임을 샘플링한다.
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

    /// 얼굴 검출+모자이크(FaceRedactor)를 JPEG 인코딩 직전에 거친다 -- 이 함수가
    /// 디스크에 쓰는 게 곧 VPS 업로드/텍스처 베이킹/썸네일이 보는 전부이므로,
    /// 여기 한 곳만 처리하면 원본(비식별화 전) 얼굴 픽셀이 어디에도 안 남는다.
    private func saveRGB(_ pixelBuffer: CVPixelBuffer, index: Int) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let redacted = FaceRedactor.redactFaces(in: ciImage)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpegData = ciContext.jpegRepresentation(
                  of: redacted,
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

        let record = ScanRecordBuilder.buildPoseRecord(
            frameId: index,
            timestamp: frame.timestamp,
            rgbPath: "rgb/frame_\(paddedIndex(index)).jpg",
            depthPath: "depth/frame_\(paddedIndex(index)).depth",
            cameraTransform: matrixToArray(t),
            intrinsics: (fx: intr[0, 0], fy: intr[1, 1], cx: intr[2, 0], cy: intr[2, 1],
                         width: Int(resolution.width), height: Int(resolution.height)),
            trackingState: trackingStateString(frame.camera.trackingState)
        )

        guard let json = try? JSONSerialization.data(withJSONObject: record) else { return }
        posesFile.write(json)
        posesFile.write("\n".data(using: .utf8)!)
    }

    // MARK: - manifest.json

    private func writeManifest() {
        guard let start = sessionStartTime, let outputDir = outputDir else { return }
        let manifest = ScanRecordBuilder.buildManifest(
            sessionName: outputDir.lastPathComponent,
            deviceModel: deviceModelIdentifier(),
            systemVersion: UIDevice.current.systemVersion,
            startTime: start.timeIntervalSince1970,
            endTime: Date().timeIntervalSince1970,
            frameCount: frameIndex,
            captureIntervalSeconds: captureIntervalSeconds,
            captureMinDistanceMeters: captureMinDistanceMeters
        )
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

// MARK: - 실시간 mesh 프리뷰 (ARSCNViewDelegate)

/// 스캔 중 카메라 화면 위에 지금까지 재구성된 LiDAR mesh를 반투명 와이어프레임으로
/// 겹쳐 그린다 — 어디를 아직 못 찍었는지 스캔하면서 바로 알 수 있게 하기 위함
/// (지도 커버리지 부족 문제를 스캔 단계에서 예방). scan.usdz export(MeshExporter)와
/// 동일한 vertex/normal 파싱 로직을 재사용하되, 여기서는 anchor.transform을 다시
/// 적용하지 않는다 — ARSCNView가 콜백으로 주는 node를 이미 그 anchor의 위치에
/// 놔주기 때문(이중 적용하면 mesh가 엉뚱한 곳에 렌더링된다).
extension ScanSessionManager: ARSCNViewDelegate {
    private static let liveMeshMaterial: SCNMaterial = {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.cyan
        material.fillMode = .lines
        material.isDoubleSided = true
        return material
    }()

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        updateMeshVisualization(node: node, anchor: anchor)
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        updateMeshVisualization(node: node, anchor: anchor)
    }

    private func updateMeshVisualization(node: SCNNode, anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor,
              let geometry = MeshExporter.scnGeometry(for: meshAnchor, worldSpace: false)
        else { return }
        geometry.materials = [Self.liveMeshMaterial]
        node.geometry = geometry
    }
}

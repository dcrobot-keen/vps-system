import ARKit
import Combine
import CoreImage
import Foundation
import SceneKit
import UIKit
import os

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

    /// 세션 전체의 카메라 (x, z) 궤적 -- `recentCameraPositions`(최근 60프레임짜리
    /// 슬라이딩 윈도)와 달리 끝까지 전부 쌓아둔다. 스캔이 끝난 뒤 `FloorPlanRenderer`가
    /// 바닥 평면 위에 겹쳐 그릴 실제 이동 경로로 쓴다 -- 저장되는 프레임 수(보통
    /// 수백~수천)만큼만 쌓이므로 메모리 부담은 없다.
    private var scanPathXZ: [SIMD2<Float>] = []

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

    /// 저장 공간 확인은 디스크 I/O라 매 프레임(최대 60Hz) 하지 않고 이 간격(초)마다만
    /// 다시 확인한다 -- 그 사이엔 마지막으로 확인한 값을 그대로 쓴다.
    private static let storageCheckIntervalSeconds: TimeInterval = 5
    private var lastStorageCheckTimestamp: TimeInterval = 0
    private var isStorageCritical = false

    private let ciContext = CIContext()
    private let logger = Logger(subsystem: "com.dcrobot.scanmesh", category: "ScanSession")

    /// 얼굴 검출+JPEG 인코딩+raw depth/confidence 쓰기를 ARSession 델리게이트
    /// 콜백 스레드 밖으로 옮기는 큐 -- 이 작업들이 전부 콜백 안에서 동기로 돌면
    /// 프레임 처리가 밀리거나 트래킹이 끊기는 원인이 될 수 있다(2026-09-04,
    /// PRODUCT-PLAN.md "캡처 루프 오프로딩" 항목).
    private let processingQueue = DispatchQueue(label: "scanmesh.frame-processing", qos: .userInitiated)
    private let processingLock = NSLock()
    private var isProcessingFrame = false

    /// 세션당 저장 실패가 누적되면(디스크 공간 부족 등 시스템적 문제일 가능성이
    /// 높음) 프레임마다 조용히 실패하는 대신 한 번은 사용자에게 알린다 -- 매
    /// 프레임마다 알리면 그 자체로 방해가 되므로 임계값을 넘을 때 한 번만.
    private var saveFailureCount = 0
    private static let saveFailureGuidanceThreshold = 3

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

    /// `continuingFromWorldMapURL`: 그룹(ScanGroupStore)에 이미 스캔이 있어서 "이어서
    /// 스캔"하는 경우, 그 이전 스캔이 저장한 `worldmap.arexperience`를 넘긴다 --
    /// `initialWorldMap`으로 로드하면 ARKit이 같은 물리 공간을 다시 알아볼 때까지
    /// 재국지화를 시도하고(기존 `updateGuidance`의 `.limited(.relocalizing)` 안내가
    /// 그대로 뜬다), 성공하면 새 스캔의 포즈/mesh가 이전 스캔과 정확히 같은 world
    /// 좌표계에 놓인다 -- 그래서 나중에 정합(registration) 계산 없이 그냥 이어붙이기만
    /// 해도 되는 것(ScanGroupMerger 참고). 못 읽으면(파일 없음/손상) 조용히 새 좌표계로
    /// 시작한다 -- 완전히 막는 것보다는 새로 찍게 해주는 쪽이 낫다.
    func startSession(name: String, continuingFromWorldMapURL: URL? = nil) {
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
        scanPathXZ = []
        lastStorageCheckTimestamp = 0
        isStorageCritical = false
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
            logger.debug("meshWithClassification 사용")
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            logger.debug("mesh 사용 (classification 미지원)")
        } else {
            logger.notice("이 기기는 sceneReconstruction을 지원하지 않음 -- scan.usdz 안 나옴")
        }
        config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]

        if let continuingFromWorldMapURL,
           let data = try? Data(contentsOf: continuingFromWorldMapURL),
           let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
            config.initialWorldMap = worldMap
            logger.debug("이전 스캔의 worldmap을 이어서 로드함 -- 같은 좌표계에서 시작")
        } else if continuingFromWorldMapURL != nil {
            logger.error("이전 스캔의 worldmap을 못 읽음 -- 새 좌표계로 시작(그룹 안에서 정합이 안 맞을 수 있음)")
        }

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
        logger.debug("stopSession 시점 anchor 개수: \(meshAnchors.count), 총 vertex 수: \(meshAnchors.reduce(0) { $0 + $1.geometry.vertices.count })")
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
        let posesCloseStatus = closePosesFile()
        let manifestStatus = writeManifest()
        let meshStatus = exportMesh(meshAnchors)
        let worldMapStatus = exportWorldMap(worldMap, error: worldMapError)
        let floorPlanStatus = exportFloorPlan(meshAnchors, scanPathXZ: scanPathXZ)
        isRunning = false
        guidanceMessage = nil
        lastOutputDir = outputDir
        statusMessage = "정지됨 (\(frameCount) 프레임, \(outputDir.lastPathComponent))\(posesCloseStatus)\(manifestStatus)\(meshStatus)\(worldMapStatus)\(floorPlanStatus)"
    }

    /// poses.jsonl 파일 핸들을 닫는다 -- 실패해도 이미 쓴 내용은 디스크에 남아있을
    /// 가능성이 높지만(대개 버퍼가 이미 flush된 뒤라), 파일 시스템이 진짜 문제가
    /// 있는 상태(디스크 꽉 참 등)일 수도 있어 조용히 넘기지 않는다.
    private func closePosesFile() -> String {
        do {
            try posesFile.close()
            return ""
        } catch {
            logger.error("poses.jsonl 닫기 실패 -- \(error.localizedDescription, privacy: .public)")
            return ", poses 파일 닫기 실패"
        }
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
            logger.notice("mesh anchor가 0개 -- sceneReconstruction이 이 세션에서 활성화 안 됐거나 너무 짧게 스캔해서 ARKit이 mesh를 아직 못 만든 상태")
            return ", mesh 없음"
        }
        let usdzURL = outputDir.appendingPathComponent("scan.usdz")
        do {
            try MeshExporter.export(meshAnchors: meshAnchors, to: usdzURL)
            logger.debug("scan.usdz 저장 완료: \(usdzURL.path, privacy: .public)")
            return ", scan.usdz 저장됨"
        } catch {
            logger.error("scan.usdz export 실패 -- \(error.localizedDescription, privacy: .public)")
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
            logger.error("getCurrentWorldMap 실패 -- \(error?.localizedDescription ?? "알 수 없는 오류", privacy: .public)")
            return ", 위치확인용 지도 저장 실패"
        }
        let url = outputDir.appendingPathComponent("worldmap.arexperience")
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
            try data.write(to: url)
            logger.debug("worldmap.arexperience 저장 완료 (\(data.count) bytes, anchor \(worldMap.anchors.count)개)")
            return ", 위치확인용 지도 저장됨"
        } catch {
            logger.error("worldmap 저장 실패 -- \(error.localizedDescription, privacy: .public)")
            return ", 위치확인용 지도 저장 실패(\(error.localizedDescription))"
        }
    }

    /// 바닥 평면 2D 이미지(floorplan.png) -- 온디바이스에서 즉석으로 만드는 대략
    /// 버전(PRODUCT-PLAN.md "바닥 평면/경로 오버레이" 항목, 2026-09-04). classification이
    /// 되면 실제 바닥/벽 mesh face로, 안 되면 높이 휴리스틱으로 만든다. scan.usdz와
    /// 달리 다운스트림 파이프라인이 소비하는 계약(scan-format)의 일부가 아니라 앱
    /// 자체 편의 산출물이라 스캔 포맷 회귀 게이트 대상은 아니다.
    private func exportFloorPlan(_ meshAnchors: [ARMeshAnchor], scanPathXZ: [SIMD2<Float>]) -> String {
        guard let outputDir else { return "" }
        guard let result = FloorPlanRenderer.render(meshAnchors: meshAnchors, scanPathXZ: scanPathXZ) else {
            logger.notice("바닥 평면 이미지 생성 실패 -- 바닥/벽으로 분류된 mesh face가 없음(mesh anchor 0개 또는 너무 짧은 스캔)")
            return ", 바닥 평면 이미지 없음"
        }
        guard let pngData = result.image.pngData() else {
            logger.error("floorplan.png 인코딩 실패")
            return ", 바닥 평면 이미지 인코딩 실패"
        }
        let url = outputDir.appendingPathComponent("floorplan.png")
        do {
            try pngData.write(to: url)
            // floorplan.png는 픽셀만 담고 있어서, world <-> pixel 매핑과 바닥 높이를
            // 나중에(텍스처 베이킹 후 바닥 재색칠, 위치확인 AR 오버레이) 다시 알려면
            // 이 사이드카가 있어야 한다 -- Result.metadataDictionary 참고.
            let metaData = try JSONSerialization.data(withJSONObject: result.metadataDictionary, options: [.prettyPrinted])
            try metaData.write(to: outputDir.appendingPathComponent("floorplan.json"))
            logger.debug("floorplan.png 저장 완료 (\(result.widthPx)x\(result.heightPx)px, \(result.resolutionMetersPerPixel) m/px)")
            return ", 바닥 평면 이미지 저장됨"
        } catch {
            logger.error("floorplan.png 쓰기 실패 -- \(error.localizedDescription, privacy: .public)")
            return ", 바닥 평면 이미지 저장 실패(\(error.localizedDescription))"
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // 캡처 스로틀링과 무관하게 매 프레임 갱신한다 — "왜 프레임이 안 늘어나지"를
        // 스로틀링 때문인지 트래킹 문제 때문인지 실시간으로 구분해서 알려줘야 한다.
        if isRunning { updateGuidance(frame: frame) }

        guard isRunning, shouldCapture(frame) else { return }
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }

        guard tryBeginProcessing() else {
            // 이전 프레임의 백그라운드 처리가 아직 안 끝났다 -- 이 프레임은 그냥
            // 버린다. 큐를 계속 쌓는 대신 최신 상태를 유지하는 쪽을 택했다(오래된
            // 프레임을 늦게 저장해봐야 스캔 품질에 도움이 안 됨). 캡처 자체가 이미
            // 0.1초/0.2m로 스로틀링돼 있어서 정상 기기에서는 거의 안 일어난다 --
            // 자주 찍히면 발열/저사양 신호로 볼 수 있다.
            logger.notice("이전 프레임 처리 중 -- frame \(self.frameIndex + 1) 건너뜀")
            return
        }

        frameIndex += 1
        let index = frameIndex

        // 픽셀 버퍼를 강한 참조로 잡아 백그라운드 큐로 넘긴다 -- ARKit은 콜백이
        // 반환된 뒤 자기 내부 재사용 풀에서 이 프레임을 빼낼 뿐이고, Swift가
        // 참조를 들고 있는 한 CVPixelBuffer 자체는 안전하다. 얼굴 검출+JPEG
        // 인코딩(FaceRedactor, Vision+CoreImage)과 raw depth/confidence 파일
        // 쓰기가 무거운 부분이라 이 콜백 스레드 밖으로 뺀다. appendPose는
        // transform/intrinsics 같은 가벼운 값만 읽으므로 그대로 동기로 둔다 --
        // poses.jsonl에 순서대로 즉시 남는 게 이후 처리 완료 순서와 무관해도 된다.
        let colorBuffer = frame.capturedImage
        let depthBuffer = depthData.depthMap
        let confidenceBuffer = depthData.confidenceMap
        appendPose(frame: frame, index: index)

        let cameraPosition = simd_float3(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        recentCameraPositions.append(cameraPosition)
        if recentCameraPositions.count > Self.textureCoverageWindowFrameCount {
            recentCameraPositions.removeFirst()
        }
        scanPathXZ.append(SIMD2<Float>(cameraPosition.x, cameraPosition.z))

        processingQueue.async { [weak self] in
            guard let self else { return }
            self.saveRGB(colorBuffer, index: index)
            self.saveDepth(depthBuffer, confidenceMap: confidenceBuffer, index: index)
            self.endProcessing()
        }

        DispatchQueue.main.async { [weak self] in
            self?.frameCount = index
        }
    }

    /// 처리 중이 아니면 true를 반환하며 "처리 중"으로 표시하고, 이미 처리 중이면
    /// false(이번 프레임은 버림). `processingQueue`의 작업이 끝나면 반드시
    /// `endProcessing()`을 호출해 다시 열어줘야 한다.
    private func tryBeginProcessing() -> Bool {
        processingLock.lock()
        defer { processingLock.unlock() }
        guard !isProcessingFrame else { return false }
        isProcessingFrame = true
        return true
    }

    private func endProcessing() {
        processingLock.lock()
        isProcessingFrame = false
        processingLock.unlock()
    }

    /// 프레임 저장(사진/depth) 실패를 누적하다가 임계값을 넘으면 한 번만
    /// guidanceMessage로 알린다. `processingQueue`에서 호출되므로 게시되는 상태는
    /// 전부 메인 큐로 넘긴다.
    private func recordSaveFailure() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.saveFailureCount += 1
            if self.saveFailureCount == Self.saveFailureGuidanceThreshold {
                self.guidanceMessage = "저장에 계속 실패하고 있어요 — 저장 공간을 확인해주세요"
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        logger.error("ARSession 오류 -- \(error.localizedDescription, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.statusMessage = "세션 오류: \(error.localizedDescription)"
        }
    }

    // MARK: - 스캔 가이드

    /// 발열 -> 저장 공간 -> 트래킹 상태 -> 거리 -> 텍스처 커버리지 -> 구역 분할
    /// 제안 순으로 확인해서 지금 제일 급한 안내 하나만 고른다(트래킹이 안 좋으면
    /// 프레임 자체가 안 찍히니 제일 급함). 텍스처 커버리지를 구역 분할 제안보다
    /// 먼저 보는 이유: 제자리에서만 찍어서 프레임 수만 채운 상태로 "이제 충분해요"를
    /// 먼저 보여주면 텍스처 품질 문제를 놓치고 그냥 저장하게 된다 — 움직이라는 안내가
    /// 더 급하다.
    private func updateGuidance(frame: ARFrame) {
        // 발열이 트래킹/거리 안내보다 급하다 -- 계속 스캔하면 iOS가 스스로 성능을
        // 낮추거나(프레임 드롭 심해짐) 최악의 경우 앱이 강제 종료될 수 있다.
        if let thermalMessage = Self.thermalGuidanceMessage(for: ProcessInfo.processInfo.thermalState) {
            guard thermalMessage != guidanceMessage else { return }
            DispatchQueue.main.async { [weak self] in self?.guidanceMessage = thermalMessage }
            return
        }

        // 저장 공간도 발열 다음으로 급하다 -- 이후 프레임 저장이 통째로 실패하기
        // 시작할 수 있다(recordSaveFailure는 이미 실패가 난 뒤에야 반응하므로,
        // 미리 알려주는 게 낫다). 디스크 여유 확인은 I/O라 storageCheckIntervalSeconds
        // 마다만 다시 하고, 그 사이엔 마지막 값을 그대로 쓴다.
        if frame.timestamp - lastStorageCheckTimestamp > Self.storageCheckIntervalSeconds {
            lastStorageCheckTimestamp = frame.timestamp
            isStorageCritical = (DeviceStorage.availableBytes() ?? .max) < DeviceStorage.criticalStorageBytes
        }
        if isStorageCritical {
            let message = "저장 공간이 거의 다 찼어요 — 지금 저장하고 마무리해주세요"
            guard message != guidanceMessage else { return }
            DispatchQueue.main.async { [weak self] in self?.guidanceMessage = message }
            return
        }

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

    /// `.serious`/`.critical`일 때만 안내한다 -- `.nominal`/`.fair`는 정상 범위라
    /// 스캔 흐름을 방해할 필요가 없다.
    private static func thermalGuidanceMessage(for state: ProcessInfo.ThermalState) -> String? {
        switch state {
        case .critical: return "기기가 많이 뜨거워요 — 스캔을 마무리하고 식힌 뒤 이어가세요"
        case .serious: return "기기가 뜨거워지고 있어요 — 잠시 쉬었다 스캔하면 좋아요"
        case .nominal, .fair: return nil
        @unknown default: return nil
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
        else {
            logger.error("frame \(index): JPEG 인코딩 실패")
            recordSaveFailure()
            return
        }

        let url = rgbDir.appendingPathComponent("frame_\(paddedIndex(index)).jpg")
        do {
            try jpegData.write(to: url)
        } catch {
            logger.error("frame \(index): rgb 쓰기 실패 -- \(error.localizedDescription, privacy: .public)")
            recordSaveFailure()
        }
    }

    private func saveDepth(_ depthMap: CVPixelBuffer, confidenceMap: CVPixelBuffer?, index: Int) {
        writeRawFloat32(depthMap, to: depthDir.appendingPathComponent("frame_\(paddedIndex(index)).depth"), index: index, label: "depth")
        if let confidenceMap {
            // confidenceMap은 OneComponent8(UInt8, 0=low/1=medium/2=high)로 나오지만
            // pipeline의 load_depth_raw가 depth와 동일하게 float32로 읽으므로
            // 저장 단계에서 float32로 변환해 둔다.
            writeConfidenceAsFloat32(confidenceMap, to: depthDir.appendingPathComponent("frame_\(paddedIndex(index)).conf"), index: index)
        }
    }

    private func writeRawFloat32(_ pixelBuffer: CVPixelBuffer, to url: URL, index: Int, label: String) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            logger.error("frame \(index): \(label, privacy: .public) 버퍼 주소를 못 얻음")
            recordSaveFailure()
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let tightRowBytes = width * MemoryLayout<Float32>.size

        var data = Data(capacity: tightRowBytes * height)
        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            data.append(ptr + row * bytesPerRow, count: tightRowBytes)
        }
        do {
            try data.write(to: url)
        } catch {
            logger.error("frame \(index): \(label, privacy: .public) 쓰기 실패 -- \(error.localizedDescription, privacy: .public)")
            recordSaveFailure()
        }
    }

    private func writeConfidenceAsFloat32(_ pixelBuffer: CVPixelBuffer, to url: URL, index: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            logger.error("frame \(index): confidence 버퍼 주소를 못 얻음")
            recordSaveFailure()
            return
        }

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
        do {
            try data.write(to: url)
        } catch {
            logger.error("frame \(index): confidence 쓰기 실패 -- \(error.localizedDescription, privacy: .public)")
            recordSaveFailure()
        }
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

    /// manifest.json 쓰기 실패는 한 번뿐인 세션 종료 이벤트라(프레임마다 반복되는
    /// saveRGB/saveDepth 실패와 달리), 조용히 넘기지 않고 statusMessage에 바로
    /// 보이게 한다 -- exportMesh/exportWorldMap과 같은 패턴.
    private func writeManifest() -> String {
        guard let start = sessionStartTime, let outputDir else { return "" }
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
        do {
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            try data.write(to: outputDir.appendingPathComponent("manifest.json"))
            return ""
        } catch {
            logger.error("manifest.json 쓰기 실패 -- \(error.localizedDescription, privacy: .public)")
            return ", manifest 저장 실패"
        }
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

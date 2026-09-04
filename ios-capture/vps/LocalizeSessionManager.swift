import ARKit
import Combine
import Foundation
import UIKit

enum LocalizePhase: Equatable {
    case loadingWorldMap
    case relocalizing
    case tracking
    case failed(String)
}

/// 위치 확인에 쓸 지도 후보 하나 = 스캔 하나. 프로젝트 단위 위치 확인은 여러 후보를
/// 받고, 스캔 단위(ProjectDetailView에서 열 때)는 후보가 하나(identity)다.
struct LocalizeCandidate: Identifiable, Equatable {
    let id: String // scanID
    let label: String
    let folderURL: URL
    /// 이 스캔 좌표계 -> 프로젝트 기준(첫 스캔) 좌표계. 정렬 화면에서 맞춘 값.
    let alignment: ScanAlignment
}

/// 저장된 ARWorldMap(ScanSessionManager가 스캔 종료 시 저장)을 initialWorldMap으로
/// 로드해 같은 물리 공간에서 재국지화를 시도하고, 성공하면 현재 위치/heading을
/// 계속 갱신한다.
///
/// **프로젝트 단위(여러 스캔)**: ARKit은 세션당 지도 하나만 불러올 수 있고 두 지도를
/// 합치는 API도 없다. 그래서 후보 지도를 하나씩 시도한다 -- 사용자가 "지금 근처
/// 스캔"을 고르면 그 지도부터, 안 고르면 스캔 1부터 타임아웃(`relocalizeTimeout`)
/// 마다 다음 지도로 자동 순환(ARKit이 실패를 알려주지 않아서 시간으로 넘긴다).
/// 어느 지도에서 잡히든 그 스캔의 정렬 변환(`ScanAlignment`)으로 기준 스캔 좌표계로
/// 옮겨서 보여주므로, 정확도는 수동 정렬의 정확도만큼이다.
///
/// vps-system 서버(`/localize`, hloc 기반)를 전혀 거치지 않는 완전 온디바이스
/// 경로다 -- ARKit 자체 특징점 재국지화만 쓴다. "대충 여기쯤이다"를 서버/네트워크
/// 없이 즉시 확인하는 용도라 이 정도로 충분하다.
final class LocalizeSessionManager: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()

    @Published private(set) var phase: LocalizePhase = .loadingWorldMap
    @Published private(set) var candidates: [LocalizeCandidate] = []
    /// 지금 시도 중인 지도(후보 인덱스).
    @Published private(set) var activeIndex = 0
    /// 사용자가 지도를 직접 골랐으면 false(그 지도만 계속 시도), 아니면 타임아웃마다 순환.
    @Published private(set) var isAutoCycling = true

    /// 기준(첫 스캔) 좌표계 기준 현재 pose. `mapPose`는 기준 스캔 폴더에
    /// registration_transform.json이 있을 때만(로봇 map 좌표).
    @Published private(set) var groundPose: GroundPose?
    @Published private(set) var mapPose: GroundPose?
    /// 화면 그리기용 -- 기준 좌표계의 world (x, z)와 전방 방향 벡터.
    @Published private(set) var currentXZ: SIMD2<Float>?
    @Published private(set) var currentForwardXZ: SIMD2<Float>?
    /// 후보별 과거 궤적(기준 좌표계로 옮긴 world (x, z)) -- 배경에 흐리게 깔아 방향을
    /// 잡기 쉽게 한다.
    @Published private(set) var trajectoriesXZ: [[SIMD2<Float>]] = []
    /// 후보별 바닥 평면(있는 것만) -- 상단 2D 개략도의 배경 지도.
    @Published private(set) var layers: [FloorPlanLayer] = []
    @Published private(set) var calibration: RegistrationTransform?

    private static let relocalizeTimeout: TimeInterval = 18
    private var relocalizingSince: Date?
    private var cycleTimer: Timer?

    override init() {
        super.init()
        session.delegate = self
    }

    /// 스캔 하나로(ProjectDetailView의 "위치 확인") -- 후보 하나, identity.
    func start(project: ScanProject) {
        start(candidates: [
            LocalizeCandidate(id: project.id, label: project.id, folderURL: project.url, alignment: .identity),
        ], startIndex: 0, autoCycle: false)
    }

    func start(candidates: [LocalizeCandidate], startIndex: Int, autoCycle: Bool) {
        self.candidates = candidates
        isAutoCycling = autoCycle && candidates.count > 1
        calibration = candidates.first.flatMap { RegistrationTransform.load(from: $0.folderURL) }
        loadBackground()
        runSession(index: startIndex)
    }

    func stop() {
        cycleTimer?.invalidate()
        cycleTimer = nil
        session.pause()
    }

    /// 사용자가 "지금 근처 스캔"을 직접 고른 경우 -- 그 지도만 계속 시도한다.
    func select(index: Int) {
        guard candidates.indices.contains(index) else { return }
        isAutoCycling = false
        runSession(index: index)
    }

    /// 다시 자동 순환으로(현재 지도부터).
    func resumeAutoCycle() {
        guard candidates.count > 1 else { return }
        isAutoCycling = true
        relocalizingSince = Date()
    }

    private func runSession(index: Int) {
        guard candidates.indices.contains(index) else { return }
        activeIndex = index
        groundPose = nil
        mapPose = nil
        currentXZ = nil
        currentForwardXZ = nil

        let worldMapURL = candidates[index].folderURL.appendingPathComponent("worldmap.arexperience")
        guard let data = try? Data(contentsOf: worldMapURL),
              let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
        else {
            // 이 스캔엔 지도가 없다(위치확인 기능 이전 스캔 등). 순환 중이면 다음 후보로.
            if isAutoCycling, candidates.count > 1 {
                runSession(index: (index + 1) % candidates.count)
            } else {
                phase = .failed("저장된 위치 지도를 읽을 수 없습니다 -- 이 스캔은 위치확인 기능 이전에 만들어졌을 수 있습니다")
            }
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.initialWorldMap = worldMap
        phase = .relocalizing
        relocalizingSince = Date()
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        startCycleTimerIfNeeded()
    }

    /// 자동 순환용 -- 재국지화가 타임아웃을 넘기면 다음 지도로 교체. 델리게이트 콜백은
    /// 트래킹이 안 되는 동안 안 올 수도 있어서(프레임은 오지만 상태만 limited) 타이머로
    /// 따로 본다.
    private func startCycleTimerIfNeeded() {
        cycleTimer?.invalidate()
        guard candidates.count > 1 else { return }
        cycleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isAutoCycling, self.phase == .relocalizing,
                  let since = self.relocalizingSince,
                  Date().timeIntervalSince(since) > Self.relocalizeTimeout
            else { return }
            self.runSession(index: (self.activeIndex + 1) % self.candidates.count)
        }
    }

    /// registration_transform.json은 scan-to-map-studio(별도 데스크탑 파이프라인)가
    /// 만드는 파일이라 자동으로 생기지 않는다 -- 사용자가 화면의 "정합 파일
    /// 가져오기"로 나중에 넣어줄 수 있으므로, 그때 다시 불러 map 좌표 표시를
    /// 활성화한다. 기준(첫) 스캔 폴더 것을 쓴다.
    func reloadCalibration() {
        guard let reference = candidates.first else { return }
        calibration = RegistrationTransform.load(from: reference.folderURL)
        if let groundPose {
            mapPose = calibration?.scanBasemapToMap(groundPose)
        }
    }

    var referenceFolderURL: URL? { candidates.first?.folderURL }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard frame.camera.trackingState == .normal else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.phase != .relocalizing else { return }
                self.phase = .relocalizing
                self.relocalizingSince = Date()
            }
            return
        }

        let index = activeIndex
        guard candidates.indices.contains(index) else { return }
        let alignment = candidates[index].alignment

        let t = frame.camera.transform
        let posXZ = alignment.applyXZ(x: t.columns.3.x, z: t.columns.3.z)
        // 카메라 전방은 로컬 -Z -> world: -columns.2.
        let fwd = alignment.rotateXZ(x: -t.columns.2.x, z: -t.columns.2.z)
        let pose = alignment.applyGroundPose(GroundPose.fromARKitTransform(t))

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.phase = .tracking
            self.relocalizingSince = nil
            self.currentXZ = SIMD2(posXZ.x, posXZ.z)
            self.currentForwardXZ = SIMD2(fwd.x, fwd.z)
            self.groundPose = pose
            self.mapPose = self.calibration?.scanBasemapToMap(pose)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - 배경(바닥 평면 + 궤적) 로드

    /// 후보마다 floorplan.png(+json)와 poses.jsonl 궤적을 읽어 정렬 변환을 적용해둔다.
    /// 파일이 클 수 있어 백그라운드에서 읽고, 궤적은 후보당 최대 2000점으로 솎는다.
    private func loadBackground() {
        let snapshot = candidates
        DispatchQueue.global(qos: .userInitiated).async {
            var loadedLayers: [FloorPlanLayer] = []
            var loadedTrajectories: [[SIMD2<Float>]] = []
            for candidate in snapshot {
                if let layer = FloorPlanLayer.load(scanID: candidate.id, label: candidate.label, folderURL: candidate.folderURL) {
                    loadedLayers.append(layer)
                }
                let raw = FloorPlanRenderer.loadScanPathXZ(from: candidate.folderURL)
                let stride = max(1, raw.count / 2000)
                let sampled = raw.enumerated().compactMap { i, p -> SIMD2<Float>? in
                    guard i % stride == 0 else { return nil }
                    let q = candidate.alignment.applyXZ(x: p.x, z: p.y)
                    return SIMD2(q.x, q.z)
                }
                loadedTrajectories.append(sampled)
            }
            DispatchQueue.main.async { [weak self] in
                self?.layers = loadedLayers
                self?.trajectoriesXZ = loadedTrajectories
            }
        }
    }

    func alignment(forLayer layer: FloorPlanLayer) -> ScanAlignment {
        candidates.first { $0.id == layer.id }?.alignment ?? .identity
    }
}

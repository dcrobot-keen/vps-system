import ARKit
import Combine
import Foundation
import UIKit

/// LocalizeView가 AR 카메라 화면 위에 얹는 반투명 바닥 평면(floorplan.png)의 배치
/// 정보. `LocalizeSessionManager.start(project:)`가 `floorplan.png` +
/// `FloorPlanRenderer.PersistedMeta`(floorplan.json)로 한 번만 계산해둔다 -- 세션
/// 내내 안 바뀐다.
struct FloorPlanOverlay {
    let image: UIImage
    /// 평면 중심의 world X/Z, 그리고 그 평면이 놓일 world Y(바닥 높이).
    let centerX: Float
    let centerZ: Float
    let floorY: Float
    /// 평면의 실제 크기(미터) -- widthPx/heightPx * resolution.
    let worldWidth: Float
    let worldDepth: Float
}

enum LocalizePhase: Equatable {
    case loadingWorldMap
    case relocalizing
    case tracking
    case failed(String)
}

/// 저장된 ARWorldMap(ScanSessionManager가 스캔 종료 시 저장)을 initialWorldMap으로
/// 로드해 같은 물리 공간에서 재국지화를 시도하고, 성공하면 그 스캔 좌표계
/// (scan_basemap) 기준 현재 위치/heading을 계속 갱신한다.
///
/// vps-system 서버(`/localize`, hloc 기반)를 전혀 거치지 않는 완전 온디바이스
/// 경로다 -- ARKit 자체 특징점 재국지화만 쓴다. 로봇 제어급 정밀도가 필요한 게
/// 아니라 "대충 여기쯤이다"를 서버/네트워크 없이 즉시 확인하는 용도라 이 정도로
/// 충분하다(자세한 트레이드오프는 doc/vps-system.md 참고).
final class LocalizeSessionManager: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()

    @Published private(set) var phase: LocalizePhase = .loadingWorldMap
    @Published private(set) var groundPose: GroundPose?
    @Published private(set) var mapPose: GroundPose?
    /// scan_basemap 프레임의 과거 궤적(x,y) -- 지금 위치 점 하나만 덩그러니 있는 것보다
    /// 스캔 당시 훑었던 범위를 배경에 흐리게 깔아주면 방향을 잡기 쉽다.
    @Published private(set) var trajectory: [SIMD2<Double>] = []
    @Published private(set) var calibration: RegistrationTransform?
    /// AR 화면에 얹을 반투명 바닥 평면 -- floorplan.png/floorplan.json이 없거나
    /// (구버전 스캔) 바닥 높이 정보가 없으면(classification 미지원 기기에서 바닥이
    /// 하나도 안 잡힌 경우) nil -- 그때는 기존처럼 카메라 화면 + 상단 2D 개략도만
    /// 보여준다(부가 기능이라 실패해도 위치확인 자체는 그대로 동작해야 함).
    @Published private(set) var floorPlanOverlay: FloorPlanOverlay?
    /// 이번 프레임의 raw ARKit world 위치(GroundPose 변환 전) -- floorPlanOverlay와
    /// 같은 좌표계라 AR 마커를 그 위에 그대로 얹을 수 있다.
    @Published private(set) var worldPosition: SIMD3<Float>?

    private var projectURL: URL?

    override init() {
        super.init()
        session.delegate = self
    }

    func start(project: ScanProject) {
        projectURL = project.url
        calibration = RegistrationTransform.load(from: project.url)
        loadTrajectory(from: project.url)
        floorPlanOverlay = Self.loadFloorPlanOverlay(from: project.url)

        let worldMapURL = project.url.appendingPathComponent("worldmap.arexperience")
        guard let data = try? Data(contentsOf: worldMapURL),
              let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
        else {
            phase = .failed("저장된 위치 지도를 읽을 수 없습니다 -- 이 스캔은 위치확인 기능 이전에 만들어졌을 수 있습니다")
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.initialWorldMap = worldMap
        phase = .relocalizing
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
    }

    /// registration_transform.json은 scan-to-map-studio(별도 데스크탑 파이프라인)가
    /// 만드는 파일이라 자동으로 생기지 않는다 -- 사용자가 화면의 "정합 파일
    /// 가져오기"로 나중에 넣어줄 수 있으므로, 그때 다시 불러 map 좌표 표시를
    /// 활성화한다.
    func reloadCalibration() {
        guard let projectURL else { return }
        calibration = RegistrationTransform.load(from: projectURL)
        if let groundPose {
            mapPose = calibration?.scanBasemapToMap(groundPose)
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard frame.camera.trackingState == .normal else {
            DispatchQueue.main.async { [weak self] in
                self?.phase = .relocalizing
            }
            return
        }

        let pose = GroundPose.fromARKitTransform(frame.camera.transform)
        let worldPos = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.phase = .tracking
            self.groundPose = pose
            self.mapPose = self.calibration?.scanBasemapToMap(pose)
            self.worldPosition = worldPos
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - AR 바닥 오버레이

    /// floorplan.png + floorplan.json(FloorPlanRenderer.PersistedMeta)에서 AR
    /// 평면 배치 정보를 만든다. 바닥 높이(floor_height_min/max)가 없으면(바닥
    /// 삼각형이 하나도 안 잡힌 스캔) 평면을 어디 높이에 놓을지 알 수 없어 nil을
    /// 반환한다 -- 그 경우 AR 오버레이만 빠지고 위치확인 자체는 그대로 동작한다.
    private static func loadFloorPlanOverlay(from projectURL: URL) -> FloorPlanOverlay? {
        guard let meta = FloorPlanRenderer.PersistedMeta.load(from: projectURL),
              let floorHeightMin = meta.floorHeightMin, let floorHeightMax = meta.floorHeightMax,
              let image = UIImage(contentsOfFile: projectURL.appendingPathComponent("floorplan.png").path)
        else { return nil }

        let worldWidth = Float(meta.widthPx) * meta.resolutionMetersPerPixel
        let worldDepth = Float(meta.heightPx) * meta.resolutionMetersPerPixel
        return FloorPlanOverlay(
            image: image,
            centerX: meta.originX + worldWidth / 2,
            centerZ: meta.originTopZ - worldDepth / 2,
            floorY: (floorHeightMin + floorHeightMax) / 2,
            worldWidth: worldWidth,
            worldDepth: worldDepth
        )
    }

    // MARK: - 궤적 로드(배경 표시용)

    /// poses.jsonl에서 camera_transform의 위치 성분만 뽑아 scan_basemap (x,y) 점
    /// 목록으로 만든다. 파일이 클 수 있어 백그라운드에서 읽고, 화면에는 최대
    /// 2000개로 솎아서만 채운다(그리기 성능 + 배경 표시 목적엔 그걸로 충분).
    private func loadTrajectory(from projectURL: URL) {
        let posesURL = projectURL.appendingPathComponent("poses/poses.jsonl")
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = try? Data(contentsOf: posesURL), let text = String(data: data, encoding: .utf8) else {
                return
            }
            var points: [SIMD2<Double>] = []
            for line in text.split(separator: "\n") {
                guard let lineData = line.data(using: .utf8),
                      let record = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let transform = record["camera_transform"] as? [[Double]],
                      transform.count >= 3, transform[0].count >= 4, transform[2].count >= 4
                else { continue }
                // ScanSessionManager.matrixToArray()의 row-major 표현: arr[row][col].
                // 마지막 열(col 3)이 world 좌표계의 카메라 위치(x,y,z) -- GroundPose와
                // 동일한 (x, -z) 평면 변환을 적용한다.
                let x = transform[0][3]
                let y = -transform[2][3]
                points.append(SIMD2(x, y))
            }
            let stride = max(1, points.count / 2000)
            let sampled = points.enumerated().compactMap { index, point in index % stride == 0 ? point : nil }
            DispatchQueue.main.async { [weak self] in
                self?.trajectory = sampled
            }
        }
    }
}

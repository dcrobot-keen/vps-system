import ARKit
import Combine
import Foundation
import UIKit

/// `LocalizeView`의 상단 2D 개략도(topDownView Canvas)에 배경으로 깔 floorplan.png.
/// `LocalizeSessionManager.start(project:)`가 `floorplan.png` +
/// `FloorPlanRenderer.PersistedMeta`(floorplan.json)로 한 번만 계산해둔다 -- 세션
/// 내내 안 바뀐다.
struct FloorPlanBackground {
    /// scan_basemap(GroundPose, (x, -z)) 좌표계 기준으로 이미 위아래를 뒤집어둔
    /// 이미지 -- `TopDownBounds.project`가 y가 클수록 화면 위쪽으로 그리는데,
    /// floorplan.png는 row가 클수록(아래로 갈수록) world Z가 작아지도록(= GroundPose
    /// y가 커지도록) 저장돼 있어서, 그대로 그리면 위아래가 뒤집혀 보인다.
    let image: UIImage
    /// scan_basemap 좌표계 기준 이 이미지의 바운딩 박스 -- topDownView가 이 배경을
    /// 어디에 그릴지, 그리고 화면 줌 범위(TopDownBounds)를 잡는 데 쓴다.
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double
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
    /// 상단 2D 개략도의 배경 지도 -- floorplan.png/floorplan.json이 없으면(구버전
    /// 스캔) nil, 그때는 기존처럼 배경 없이 궤적/위치만 보여준다(부가 기능이라
    /// 실패해도 위치확인 자체는 그대로 동작해야 함).
    @Published private(set) var floorPlanBackground: FloorPlanBackground?

    private var projectURL: URL?

    override init() {
        super.init()
        session.delegate = self
    }

    func start(project: ScanProject) {
        projectURL = project.url
        calibration = RegistrationTransform.load(from: project.url)
        loadTrajectory(from: project.url)
        floorPlanBackground = Self.loadFloorPlanBackground(from: project.url)

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
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.phase = .tracking
            self.groundPose = pose
            self.mapPose = self.calibration?.scanBasemapToMap(pose)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - 2D 개략도 배경 지도

    /// floorplan.png + floorplan.json(FloorPlanRenderer.PersistedMeta)을
    /// scan_basemap(GroundPose) 좌표계로 옮긴다.
    ///
    /// world -> GroundPose 매핑은 `GroundPose.fromARKitTransform`과 같다(x는 그대로,
    /// z는 부호 반전: y = -z). floorplan.png는 row가 커질수록(아래로 갈수록) world
    /// Z가 작아지도록 저장돼 있는데(`FloorPlanRenderer` 참고), 그 말은 GroundPose
    /// y = -z 기준으로는 row가 커질수록 y가 커진다는 뜻이다. `TopDownBounds.project`는
    /// y가 클수록 화면 위쪽에 그리므로, floorplan.png를 그대로(가공 없이) 그리면
    /// 위아래가 뒤집혀 보인다 -- 그래서 여기서 미리 세로로 뒤집어둔다.
    private static func loadFloorPlanBackground(from projectURL: URL) -> FloorPlanBackground? {
        guard let meta = FloorPlanRenderer.PersistedMeta.load(from: projectURL),
              let image = UIImage(contentsOfFile: projectURL.appendingPathComponent("floorplan.png").path),
              let flipped = verticallyFlipped(image)
        else { return nil }

        let worldWidth = Double(meta.widthPx) * Double(meta.resolutionMetersPerPixel)
        let worldDepth = Double(meta.heightPx) * Double(meta.resolutionMetersPerPixel)
        let minX = Double(meta.originX)
        let maxX = minX + worldWidth
        // GroundPose y = -z. world Z는 [originTopZ - worldDepth, originTopZ] 범위이므로
        // y = -z는 [-originTopZ, worldDepth - originTopZ] 범위가 된다.
        let minY = -Double(meta.originTopZ)
        let maxY = minY + worldDepth
        return FloorPlanBackground(image: flipped, minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    /// `UIImage.draw(at:)`는 항상 이미지 row 0을 그리는 rect의 위쪽에 놓으므로,
    /// 실제로 위아래를 뒤집으려면 그리기 전에 컨텍스트 자체를 뒤집어야 한다.
    private static func verticallyFlipped(_ image: UIImage) -> UIImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { context in
            context.cgContext.translateBy(x: 0, y: image.size.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            image.draw(at: .zero)
        }
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

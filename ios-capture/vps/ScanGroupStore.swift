import Combine
import Foundation

/// 여러 스캔(`scan_<name>/`)을 하나의 "프로젝트"로 묶는다. 기존 스캔 폴더는 전혀
/// 옮기거나 중첩시키지 않는다 -- `ZipArchiver`/`TextureBaker`/`FloorPlanRenderer`/
/// `VPSUploadClient` 등 그 폴더를 직접 다루는 코드가 전부 그대로 동작해야 하므로,
/// `Documents/scan_groups.json`에 그룹 정보(이름 + 속한 scan_<name> 폴더 이름 목록)만
/// 가벼운 인덱스로 따로 둔다.
///
/// 스캔들은 각자 따로(독립된 ARKit 세션, 따라서 각자 다른 world 원점) 찍고 나중에
/// 합친다(2026-09-04 결정 -- 처음엔 이전 스캔의 worldmap을 이어받는 "이어서 스캔"으로
/// 했는데 실사용에서 어색해서 바꿈). 그래서 합칠 때 스캔마다 정렬 변환(`ScanAlignment`)이
/// 필요하고, 그건 `ScanAlignmentView`에서 사용자가 위에서 내려다본 2D 화면으로 직접
/// 맞춘다. 중력 방향(Y)은 ARKit이 세션마다 항상 맞춰주고 바닥 높이는 floorplan.json에
/// 있어서, 사용자가 맞출 건 평면 위치(x, z)와 회전(yaw)뿐이다.
struct ScanGroup: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    /// 캡처한 순서 그대로, 각 항목은 scan_<name> 폴더 이름 전체(= `ScanProject.id`).
    /// 첫 항목이 합칠 때의 기준 좌표계(정렬 변환 없이 그대로)가 된다.
    var scanIDs: [String]
    let createdAt: Date
    /// scanID -> 그 스캔을 기준 스캔의 좌표계로 옮기는 변환. 없으면 identity.
    var alignments: [String: ScanAlignment]

    var latestScanID: String? { scanIDs.last }

    init(id: String, name: String, scanIDs: [String], createdAt: Date, alignments: [String: ScanAlignment] = [:]) {
        self.id = id
        self.name = name
        self.scanIDs = scanIDs
        self.createdAt = createdAt
        self.alignments = alignments
    }

    func alignment(for scanID: String) -> ScanAlignment {
        alignments[scanID] ?? .identity
    }

    // alignments는 나중에 추가된 필드라, 그 전에 저장된 scan_groups.json에는 키 자체가
    // 없다 -- 없으면 빈 딕셔너리로 읽는다(합성 Codable은 키가 없으면 실패함).
    private enum CodingKeys: String, CodingKey {
        case id, name, scanIDs, createdAt, alignments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        scanIDs = try c.decode([String].self, forKey: .scanIDs)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        alignments = try c.decodeIfPresent([String: ScanAlignment].self, forKey: .alignments) ?? [:]
    }
}

/// 스캔 하나를 그룹의 기준 좌표계로 옮기는 강체 변환(평면 위치 + yaw). 수직(Y)
/// 오프셋은 여기 없다 -- 합칠 때 두 스캔의 바닥 높이(floorplan.json의
/// floor_height_min)를 맞춰서 자동으로 채운다(ScanGroupMerger).
///
/// 적용 순서: 먼저 Y축 기준 yaw 회전, 그다음 (offsetX, offsetZ) 이동. 이 공식 하나를
/// 합치기(3D)와 정렬 화면(2D 미리보기)이 똑같이 써야 미리보기가 결과와 일치한다.
struct ScanAlignment: Codable, Equatable {
    var offsetX: Float
    var offsetZ: Float
    var yawRadians: Float

    static let identity = ScanAlignment(offsetX: 0, offsetZ: 0, yawRadians: 0)

    func apply(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let (x, z) = applyXZ(x: p.x, z: p.z)
        return SIMD3(x, p.y, z)
    }

    func applyXZ(x: Float, z: Float) -> (x: Float, z: Float) {
        let c = cos(yawRadians), s = sin(yawRadians)
        return (x * c + z * s + offsetX, -x * s + z * c + offsetZ)
    }
}

@MainActor
final class ScanGroupStore: ObservableObject {
    @Published private(set) var groups: [ScanGroup] = []

    private let indexURL: URL

    /// 기본값은 실제 앱이 쓰는 `Documents/scan_groups.json`. 테스트가 임시 경로를
    /// 넣어줄 수 있도록 주입 가능하게 해뒀다(ScanGroupStoreTests).
    init(indexURL: URL? = nil) {
        self.indexURL = indexURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("scan_groups.json")
    }

    func refresh() {
        guard let data = try? Data(contentsOf: indexURL) else {
            groups = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        groups = ((try? decoder.decode([ScanGroup].self, from: data)) ?? [])
            .sorted { $0.createdAt > $1.createdAt }
    }

    func groupExists(named name: String) -> Bool {
        groups.contains { $0.name == name }
    }

    @discardableResult
    func createGroup(name: String) -> ScanGroup {
        let group = ScanGroup(id: UUID().uuidString, name: name, scanIDs: [], createdAt: Date())
        groups.insert(group, at: 0)
        save()
        return group
    }

    /// 스캔이 저장을 마친 뒤(ScanView의 onSaved) 호출해서 그 scan_<name> 폴더를
    /// 그룹에 등록한다.
    func addScan(scanID: String, to groupID: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard !groups[index].scanIDs.contains(scanID) else { return }
        groups[index].scanIDs.append(scanID)
        save()
    }

    /// 그룹 인덱스에서만 뺀다 -- scan_<name> 폴더 자체는 그대로(개별 스캔 삭제는 스캔
    /// 화면에서). 그 스캔의 정렬 변환도 같이 지운다.
    func removeScan(scanID: String, from groupID: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].scanIDs.removeAll { $0 == scanID }
        groups[index].alignments.removeValue(forKey: scanID)
        save()
    }

    /// 정렬 화면(ScanAlignmentView)에서 "저장"할 때 한꺼번에 반영한다.
    func setAlignments(_ alignments: [String: ScanAlignment], for groupID: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].alignments = alignments
        save()
    }

    /// 그룹 인덱스만 지운다 -- 실제 scan_<name> 폴더는 그대로 둔다(다른 그룹에도
    /// 속할 수 있는 건 아니지만, 폴더 자체를 지우는 건 되돌릴 수 없는 파괴적 동작이라
    /// 그룹 삭제와는 분리해뒀다. 개별 스캔 삭제는 각 스캔 화면에서 한다).
    func deleteGroup(_ group: ScanGroup) {
        groups.removeAll { $0.id == group.id }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(groups) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

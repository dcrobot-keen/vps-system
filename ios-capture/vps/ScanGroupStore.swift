import Combine
import Foundation

/// 여러 스캔(`scan_<name>/`)을 하나의 "프로젝트"로 묶는다. 기존 스캔 폴더는 전혀
/// 옮기거나 중첩시키지 않는다 -- `ZipArchiver`/`TextureBaker`/`FloorPlanRenderer`/
/// `VPSUploadClient` 등 그 폴더를 직접 다루는 코드가 전부 그대로 동작해야 하므로,
/// `Documents/scan_groups.json`에 그룹 정보(이름 + 속한 scan_<name> 폴더 이름 목록)만
/// 가벼운 인덱스로 따로 둔다.
///
/// "합치기"는 정합(registration) 알고리즘 없이 이어서 스캔하는 방식으로 한다
/// (2026-09-04 결정) -- 그룹의 첫 스캔 이후로는 그 스캔이 저장한
/// `worldmap.arexperience`를 `initialWorldMap`으로 불러와 같은 좌표계에서 캡처하므로,
/// 그룹 안의 스캔들은 이미 하나의 world 좌표계를 공유한다(ScanSessionManager.startSession
/// 참고). 그래서 "합치기"는 각 스캔의 mesh/포즈를 그대로 이어붙이기만 하면 된다
/// (ScanGroupMerger 참고).
struct ScanGroup: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    /// 캡처한 순서 그대로 -- 첫 항목이 그룹의 좌표계 기준(worldmap 원본)이 된다.
    var scanIDs: [String]
    let createdAt: Date

    /// 다음 스캔이 "이어서 찍기"용으로 불러올 worldmap -- 그룹의 마지막 스캔 것을 쓴다
    /// (제일 최근까지 갱신된 특징점 맵이라 재국지화가 더 잘 될 가능성이 높음).
    var latestScanID: String? { scanIDs.last }
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

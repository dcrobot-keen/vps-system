import Combine
import Foundation

/// Documents 밑 scan_<name>/ 폴더 하나를 나타낸다. ScanSessionManager가 실제로 만드는
/// 폴더 구조(manifest.json, rgb/, depth/, poses/, 있으면 scan.usdz)를 읽기만 한다.
struct ScanProject: Identifiable, Equatable {
    let id: String // 폴더 이름, 예: scan_20260817_203941
    let url: URL
    let frameCount: Int?
    let hasUSDZ: Bool
    let hasWorldMap: Bool
    let startTime: Date?

    static func == (lhs: ScanProject, rhs: ScanProject) -> Bool {
        lhs.id == rhs.id
    }
}

/// Documents 밑 scan_*/ 폴더들을 프로젝트 목록으로 보여주고, 삭제/내보내기를 처리한다.
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [ScanProject] = []

    private var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func refresh() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: documentsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []

        projects = items
            .filter { $0.lastPathComponent.hasPrefix("scan_") }
            .compactMap { url -> ScanProject? in
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return nil
                }
                let manifest = readManifest(at: url)
                let startTime = (manifest?["start_time"] as? Double).map { Date(timeIntervalSince1970: $0) }
                return ScanProject(
                    id: url.lastPathComponent,
                    url: url,
                    frameCount: manifest?["frame_count"] as? Int,
                    hasUSDZ: fm.fileExists(atPath: url.appendingPathComponent("scan.usdz").path),
                    hasWorldMap: fm.fileExists(atPath: url.appendingPathComponent("worldmap.arexperience").path),
                    startTime: startTime
                )
            }
            .sorted { ($0.startTime ?? .distantPast) > ($1.startTime ?? .distantPast) }
    }

    /// 새 프로젝트 이름 입력 화면에서 중복 체크용.
    func projectExists(named name: String) -> Bool {
        var isDirectory: ObjCBool = false
        let path = documentsDir.appendingPathComponent("scan_\(name)").path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func delete(_ project: ScanProject) {
        try? FileManager.default.removeItem(at: project.url)
        refresh()
    }

    /// project.url 폴더를 zip으로 묶어 반환한다. 완료 콜백은 메인 스레드에서 호출된다.
    func exportZip(_ project: ScanProject, completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let zipURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(project.id + ".zip")
            do {
                try ZipArchiver.zip(directory: project.url, to: zipURL)
                DispatchQueue.main.async { completion(zipURL) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    private func readManifest(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
}

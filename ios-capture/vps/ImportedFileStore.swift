import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.dcrobot.keen.scanmesh", category: "ImportedFileStore")

/// glb/pcd/ply/usdz/obj 같은 외부 3D 결과물(파이프라인/scan-to-map-studio/
/// Gaussian Splatting 등에서 나온 파일)을 폰으로 가져와서 보기 위한 저장소.
/// 이 앱 자체가 만드는 `scan_*/` 프로젝트와는 별개로, `Documents/imports/`에
/// 파일을 복사해서 보관한다 — Files 앱 문서 선택기로 가져오므로(LocalSend로
/// 받은 파일도 Files에 저장해두면 여기서 바로 골라올 수 있다), 원본 위치가
/// iCloud Drive든 로컬이든 상관없이 앱 안에 독립된 사본을 갖는다.
@MainActor
final class ImportedFileStore: ObservableObject {
    @Published private(set) var files: [ImportedFile] = []
    @Published var importErrorMessage: String?

    static let supportedExtensions: Set<String> = ["glb", "pcd", "ply", "usdz", "obj"]

    private var importsDir: URL {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = documentsDir.appendingPathComponent("imports")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        refresh()
    }

    func refresh() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: importsDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )) ?? []
        files = urls
            .filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .map { ImportedFile(url: $0) }
            .sorted { $0.modifiedDate > $1.modifiedDate }
    }

    /// 문서 선택기가 넘겨준 보안 스코프 URL에서 읽어 imports/ 아래로 복사한다.
    /// 원본이 iCloud Drive에 있으면 접근 전 `startAccessingSecurityScopedResource()`가
    /// 필요하다 — 안 하면 파일 없다는 에러만 나오고 원인이 안 보여서 주의가 필요했다.
    func importFile(from sourceURL: URL) {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let destination = uniqueDestination(for: sourceURL.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            refresh()
        } catch {
            logger.error("파일 가져오기 실패(\(sourceURL.lastPathComponent, privacy: .public)) -- \(error.localizedDescription, privacy: .public)")
            importErrorMessage = "\"\(sourceURL.lastPathComponent)\" 가져오기 실패: \(error.localizedDescription)"
        }
    }

    func delete(_ file: ImportedFile) {
        try? FileManager.default.removeItem(at: file.url)
        refresh()
    }

    private func uniqueDestination(for filename: String) -> URL {
        var destination = importsDir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: destination.path) else { return destination }

        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var index = 2
        repeat {
            destination = importsDir.appendingPathComponent("\(base)_\(index).\(ext)")
            index += 1
        } while FileManager.default.fileExists(atPath: destination.path)
        return destination
    }
}

struct ImportedFile: Identifiable {
    let url: URL
    var id: URL { url }

    var name: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.lowercased() }

    var modifiedDate: Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    var fileSize: Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }
}

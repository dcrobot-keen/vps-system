import SwiftUI

/// 프로젝트(ScanGroup) 하나의 내용 -- 그 프로젝트에 속한 스캔들을 보여주고, "스캔
/// 추가"로 새 스캔을 이어서 찍는다. 그룹에 이미 스캔이 있으면 그 마지막 스캔의
/// worldmap.arexperience를 이어서 로드해서(ScanSessionManager.startSession의
/// continuingFromWorldMapURL) 같은 좌표계에서 캡처한다 -- 정합(registration) 계산 없이
/// 그냥 이어붙일 수 있는 이유(ScanGroupStore 상단 주석 참고).
struct ProjectGroupDetailView: View {
    let groupID: String
    @ObservedObject var store: ScanGroupStore
    @StateObject private var scanStore = ProjectStore()

    @State private var isNavigatingToScan = false
    @State private var pendingScanName = ""
    @State private var pendingContinuationWorldMapURL: URL?

    @State private var isExporting = false
    @State private var exportShareItem: ShareItem?
    @State private var exportErrorMessage: String?

    /// export 시 고를 수 있는 형식(2026-09-04 결정) -- 프로젝트(합쳐진 것) 단위만
    /// 지원한다, 스캔 개별 export는 범위 밖. ply/pcd/glb는 그룹 안 스캔들의
    /// scan.usdz를 합친 mesh(ScanGroupMerger)에서 나오고, zip은 스캔 폴더들을 그냥
    /// 논리적으로 묶는다(ZipArchiver.zip(directories:)).
    private enum ExportFormat: String, CaseIterable, Identifiable {
        case ply, pcd, glb, zip
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ply: return "PLY (합쳐진 mesh)"
            case .pcd: return "PCD (합쳐진 포인트)"
            case .glb: return "GLB (합쳐진 mesh)"
            case .zip: return "프로젝트 전체 (zip)"
            }
        }
    }

    init(group: ScanGroup, store: ScanGroupStore) {
        self.groupID = group.id
        self.store = store
    }

    /// `store.groups`에서 매번 다시 찾는다(고정된 값을 들고 있지 않음) -- 스캔을
    /// 추가하면 store가 갱신되고, 그 변화를 이 화면에도 바로 반영하기 위해서다.
    private var group: ScanGroup? {
        store.groups.first { $0.id == groupID }
    }

    private var scansInGroup: [ScanProject] {
        guard let group else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: scanStore.projects.map { ($0.id, $0) })
        return group.scanIDs.compactMap { byID[$0] }
    }

    var body: some View {
        Group {
            if let group, !scansInGroup.isEmpty {
                List {
                    Section {
                        ForEach(scansInGroup) { scan in
                            NavigationLink {
                                ProjectDetailView(project: scan)
                            } label: {
                                scanRow(scan)
                            }
                        }
                    } header: {
                        Text("스캔 \(group.scanIDs.count)개")
                    }
                }
            } else {
                emptyState
            }
        }
        .navigationTitle(group?.name ?? "프로젝트")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    startNewScan()
                } label: {
                    Label("스캔 추가", systemImage: "plus.viewfinder")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isExporting {
                    ProgressView()
                } else {
                    Menu {
                        ForEach(ExportFormat.allCases) { format in
                            Button(format.label) { exportMerged(as: format) }
                        }
                    } label: {
                        Label("내보내기", systemImage: "square.and.arrow.up")
                    }
                    .disabled(scansInGroup.isEmpty)
                }
            }
        }
        .navigationDestination(isPresented: $isNavigatingToScan) {
            ScanView(projectName: pendingScanName, continuingFromWorldMapURL: pendingContinuationWorldMapURL) {
                store.addScan(scanID: pendingScanName, to: groupID)
                scanStore.refresh()
            }
        }
        .sheet(item: $exportShareItem) { item in
            ShareSheet(activityItems: [item.url])
        }
        .alert("내보내기 실패", isPresented: Binding(
            get: { exportErrorMessage != nil }, set: { if !$0 { exportErrorMessage = nil } }
        )) {
            Button("확인") { exportErrorMessage = nil }
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .onAppear { scanStore.refresh() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("아직 스캔이 없습니다")
                .font(.headline)
            Text("오른쪽 위 \"스캔 추가\"로 첫 스캔을 시작하세요")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scanRow(_ scan: ScanProject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(scan.id)
                .font(.headline)
            HStack(spacing: 8) {
                if let frameCount = scan.frameCount {
                    Text("\(frameCount) 프레임")
                }
                if scan.hasUSDZ {
                    Label("mesh", systemImage: "cube")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// 그룹의 마지막 스캔이 있으면 그 worldmap을 이어서 로드하도록 넘긴다(없으면 첫
    /// 스캔이라 새 좌표계로 시작). 스캔 폴더 이름은 프로젝트 표시 이름과 별개로,
    /// 기존 단독 스캔과 같은 타임스탬프 규칙(파일시스템에 안전한 형식)을 쓴다.
    private func startNewScan() {
        pendingScanName = Self.newScanFolderName()
        if let latestScanID = group?.latestScanID {
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let worldMapURL = documentsDir
                .appendingPathComponent("scan_\(latestScanID)")
                .appendingPathComponent("worldmap.arexperience")
            pendingContinuationWorldMapURL = FileManager.default.fileExists(atPath: worldMapURL.path) ? worldMapURL : nil
        } else {
            pendingContinuationWorldMapURL = nil
        }
        isNavigatingToScan = true
    }

    private static func newScanFolderName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: - Export

    /// mesh 합치기(ScanGroupMerger, scan.usdz가 하나도 없으면 실패)나 zip 압축
    /// 둘 다 시간이 걸릴 수 있어 백그라운드 큐에서 돌리고, 끝나면 공유 시트를 띄운다.
    private func exportMerged(as format: ExportFormat) {
        let scanURLs = scansInGroup.map(\.url)
        let projectName = group?.name ?? "프로젝트"
        guard !scanURLs.isEmpty else { return }

        isExporting = true
        exportErrorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let destURL = try Self.buildExportFile(format: format, scanURLs: scanURLs, projectName: projectName)
                DispatchQueue.main.async {
                    isExporting = false
                    exportShareItem = ShareItem(url: destURL)
                }
            } catch {
                DispatchQueue.main.async {
                    isExporting = false
                    exportErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private static func buildExportFile(format: ExportFormat, scanURLs: [URL], projectName: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        // 프로젝트 이름은 자유 텍스트라(경로 구분자 등도 입력 가능) 파일 이름으로
        // 그대로 쓰면 안 된다 -- 경로로 해석될 수 있는 문자만 안전하게 바꾼다.
        let sanitized = projectName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = sanitized.isEmpty ? "project" : sanitized

        switch format {
        case .zip:
            let url = tempDir.appendingPathComponent("\(safeName).zip")
            try? FileManager.default.removeItem(at: url)
            try ZipArchiver.zip(directories: scanURLs, to: url)
            return url

        case .ply:
            let merged = try ScanGroupMerger.mergeMesh(scanFolderURLs: scanURLs)
            let url = tempDir.appendingPathComponent("\(safeName).ply")
            try? FileManager.default.removeItem(at: url)
            try PLYWriter.write(positions: merged.positions, normals: merged.normals, indices: merged.indices, to: url)
            return url

        case .pcd:
            let merged = try ScanGroupMerger.mergeMesh(scanFolderURLs: scanURLs)
            let url = tempDir.appendingPathComponent("\(safeName).pcd")
            try? FileManager.default.removeItem(at: url)
            try PCDWriter.write(positions: merged.positions, to: url)
            return url

        case .glb:
            let merged = try ScanGroupMerger.mergeMesh(scanFolderURLs: scanURLs)
            // GLBWriter는 텍스처를 필수로 받는다(TextureBaker 전용으로 설계됨) --
            // 합쳐진 결과는 무채색이라(MeshExporter와 같은 방침) 1x1 흰 텍스처를
            // placeholder로 채운다. 인덱스 버퍼도 지원 안 해서 unindexedForGLB로 편다.
            let (positions, normals, vertexCount) = merged.unindexedForGLB()
            let uvs = [Float](repeating: 0, count: vertexCount * 2)
            let whitePixel: [UInt8] = [255, 255, 255, 255]
            let url = tempDir.appendingPathComponent("\(safeName).glb")
            try? FileManager.default.removeItem(at: url)
            try GLBWriter.write(
                positions: positions, normals: normals, uvs: uvs,
                textureRGBA: whitePixel, textureWidth: 1, textureHeight: 1, to: url
            )
            return url
        }
    }
}

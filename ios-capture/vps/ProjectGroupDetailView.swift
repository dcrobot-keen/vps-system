import SwiftUI

/// 프로젝트(ScanGroup) 하나의 내용 -- 속한 스캔 목록, 플로팅 버튼으로 스캔 추가(각
/// 스캔은 독립된 세션으로 따로 찍음), ⋯ 메뉴에서 정렬(ScanAlignmentView)과 내보내기.
struct ProjectGroupDetailView: View {
    let groupID: String
    @ObservedObject var store: ScanGroupStore
    @StateObject private var scanStore = ProjectStore()

    @State private var isNavigatingToScan = false
    @State private var pendingScanName = ""

    @State private var isShowingAlignment = false
    @State private var isShowingMergedViewer = false
    @State private var isShowingLocalize = false
    @State private var isExporting = false
    @State private var exportShareItem: ShareItem?
    @State private var exportErrorMessage: String?

    /// export 시 고를 수 있는 형식(2026-09-04 결정) -- 프로젝트(합쳐진 것) 단위만
    /// 지원한다, 스캔 개별 export는 범위 밖. ply/pcd/glb는 그룹 안 스캔들의
    /// scan.usdz를 정렬 변환 적용 후 합친 mesh(ScanGroupMerger)에서 나오고, zip은 스캔
    /// 폴더들을 그냥 논리적으로 묶는다(ZipArchiver.zip(directories:)). zip은 두 프로파일
    /// (ScanExportProfile): 전체(VPS DB용, 방당 수백 MB)와 지도용(usdz·바닥평면·궤적만,
    /// 수 MB) -- 2D 지도/시뮬레이터/정렬 작업엔 지도용으로 충분하다.
    private enum ExportFormat: String, CaseIterable, Identifiable {
        case ply, pcd, glb, zipMap, zip
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ply: return "PLY (합쳐진 mesh)"
            case .pcd: return "PCD (합쳐진 포인트)"
            case .glb: return "GLB (합쳐진 mesh)"
            case .zipMap: return ScanExportProfile.map.label
            case .zip: return ScanExportProfile.full.label
            }
        }
    }

    init(group: ScanGroup, store: ScanGroupStore) {
        self.groupID = group.id
        self.store = store
    }

    /// `store.groups`에서 매번 다시 찾는다(고정된 값을 들고 있지 않음) -- 스캔을
    /// 추가/정렬하면 store가 갱신되고, 그 변화를 이 화면에도 바로 반영하기 위해서다.
    private var group: ScanGroup? {
        store.groups.first { $0.id == groupID }
    }

    /// `group.scanIDs`는 scan_<name> 폴더 이름 전체(= `ScanProject.id`)라 그대로 대조한다.
    /// (처음엔 `scan_` 접두사 없는 이름을 등록해서 여기서 하나도 안 잡히는 버그가 있었음.)
    private var scansInGroup: [ScanProject] {
        guard let group else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: scanStore.projects.map { ($0.id, $0) })
        return group.scanIDs.compactMap { byID[$0] }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let group, !scansInGroup.isEmpty {
                    List {
                        Section {
                            ForEach(Array(scansInGroup.enumerated()), id: \.element.id) { index, scan in
                                NavigationLink {
                                    ProjectDetailView(project: scan, displayName: "스캔 \(index + 1)") {
                                        store.removeScan(scanID: scan.id, from: groupID)
                                        scanStore.refresh()
                                    }
                                } label: {
                                    scanRow(scan, index: index, isReference: index == 0)
                                }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        store.removeScan(scanID: scan.id, from: groupID)
                                    } label: {
                                        Label("프로젝트에서 제거", systemImage: "minus.circle")
                                    }
                                }
                            }
                        } header: {
                            Text("스캔 \(group.scanIDs.count)개")
                        } footer: {
                            if group.scanIDs.count >= 1 {
                                Text("다음 방을 찍을 때 \"이전 스캔 위치에 맞추기\"를 켜면 정렬이 자동으로 채워집니다(방마다 문 밖을 조금 같이 찍어두세요). 안 잡힌 스캔은 ⋯ 메뉴의 \"스캔 정렬\"로 맞추세요. 첫 번째 스캔이 기준입니다.")
                            }
                        }
                    }
                } else {
                    emptyState
                }
            }

            FloatingActionButton(systemImage: "camera.viewfinder") {
                startNewScan()
            }
        }
        .navigationTitle(group?.name ?? "프로젝트")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isExporting {
                    ProgressView()
                } else {
                    Menu {
                        Button {
                            isShowingAlignment = true
                        } label: {
                            Label("스캔 정렬", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                        }
                        .disabled(scansInGroup.count < 2)

                        Button {
                            isShowingMergedViewer = true
                        } label: {
                            Label("합친 mesh 보기", systemImage: "cube.transparent")
                        }
                        .disabled(!scansInGroup.contains { $0.hasUSDZ })

                        Button {
                            isShowingLocalize = true
                        } label: {
                            Label("위치 확인 (서버 없이)", systemImage: "location.viewfinder")
                        }
                        .disabled(!scansInGroup.contains { $0.hasWorldMap })

                        Menu {
                            ForEach(ExportFormat.allCases) { format in
                                Button(format.label) { exportMerged(as: format) }
                            }
                        } label: {
                            Label("내보내기", systemImage: "square.and.arrow.up")
                        }
                        .disabled(scansInGroup.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .navigationDestination(isPresented: $isNavigatingToScan) {
            ScanView(projectName: pendingScanName, anchorCandidates: anchorCandidates) { alignment in
                // ScanSessionManager는 폴더를 scan_<name>으로 만들고, ScanProject.id도
                // 그 폴더 이름 전체다 -- 그룹엔 그 전체 이름으로 등록해야 목록 조회와 맞는다.
                let scanID = "scan_\(pendingScanName)"
                store.addScan(scanID: scanID, to: groupID)
                if let alignment {
                    // "이전 스캔 위치에 맞추기"로 찍은 스캔 -- 정렬이 자동으로 채워진다.
                    store.setAlignment(alignment, for: scanID, in: groupID)
                }
                scanStore.refresh()
            }
        }
        .sheet(isPresented: $isShowingAlignment) {
            if let group {
                ScanAlignmentView(group: group, scans: scansInGroup) { alignments in
                    store.setAlignments(alignments, for: groupID)
                }
            }
        }
        .fullScreenCover(isPresented: $isShowingMergedViewer) {
            MergedMeshViewer(scans: mergeInputs) { isShowingMergedViewer = false }
        }
        .fullScreenCover(isPresented: $isShowingLocalize) {
            NavigationStack {
                LocalizeView(candidates: localizeCandidates)
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
        ContentUnavailableView {
            Label("아직 스캔이 없습니다", systemImage: "camera.viewfinder")
        } description: {
            Text("오른쪽 아래 버튼으로 첫 스캔을 시작하세요")
        }
    }

    /// 정렬 변환 포함 -- 미리보기(MergedMeshViewer)와 내보내기가 같은 입력을 쓴다.
    private var mergeInputs: [ScanGroupMerger.ScanInput] {
        guard let group else { return [] }
        return scansInGroup.map {
            ScanGroupMerger.ScanInput(folderURL: $0.url, alignment: group.alignment(for: $0.id))
        }
    }

    /// "이전 스캔 위치에 맞추기" 후보 -- 지도가 있는 스캔만, 최근 것부터(옆방일 가능성이
    /// 높아 먼저 시도). 각 후보의 정렬 변환을 이어 붙여 새 스캔이 프로젝트 기준 좌표계에
    /// 놓이게 한다.
    private var anchorCandidates: [ScanSessionManager.AnchorCandidate] {
        guard let group else { return [] }
        return scansInGroup.enumerated().reversed().compactMap { index, scan in
            guard scan.hasWorldMap else { return nil }
            return ScanSessionManager.AnchorCandidate(
                id: scan.id, label: "스캔 \(index + 1)",
                worldMapURL: scan.url.appendingPathComponent("worldmap.arexperience"),
                alignment: group.alignment(for: scan.id)
            )
        }
    }

    /// 프로젝트 단위 위치 확인용 -- 지도(worldmap)가 있는 스캔만, 정렬 변환 포함.
    private var localizeCandidates: [LocalizeCandidate] {
        guard let group else { return [] }
        return scansInGroup.enumerated().compactMap { index, scan in
            guard scan.hasWorldMap else { return nil }
            return LocalizeCandidate(
                id: scan.id, label: "스캔 \(index + 1)", folderURL: scan.url, alignment: group.alignment(for: scan.id)
            )
        }
    }

    /// 제목은 프로젝트 안 순번 + 찍은 시각("스캔 2 · 오후 3:12"), 폴더명은 부제
    /// (2026-09-04 IA 검토 #1 -- 타임스탬프 폴더명은 읽기 어려움).
    private func scanRow(_ scan: ScanProject, index: Int, isReference: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("스캔 \(index + 1)")
                    .font(.headline)
                if let startTime = scan.startTime {
                    Text("· \(startTime.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if isReference {
                    Text("기준")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }
            HStack(spacing: 8) {
                if let frameCount = scan.frameCount {
                    Text("\(frameCount) 프레임")
                }
                if scan.hasUSDZ {
                    Label("mesh", systemImage: "cube")
                }
                if scan.hasFloorPlan {
                    Label("바닥 평면", systemImage: "square.grid.3x3.topleft.filled")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(scan.id)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// 각 스캔은 독립된 세션으로 시작한다(이전 스캔 worldmap을 이어받지 않음 --
    /// 실사용에서 어색해서 뺐고, 대신 나중에 ScanAlignmentView로 맞춘다). 스캔 폴더
    /// 이름은 프로젝트 표시 이름과 별개로, 파일시스템에 안전한 타임스탬프 규칙.
    private func startNewScan() {
        pendingScanName = Self.newScanFolderName()
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
        guard let group else { return }
        let scans = scansInGroup.map {
            ScanGroupMerger.ScanInput(folderURL: $0.url, alignment: group.alignment(for: $0.id))
        }
        let projectName = group.name
        guard !scans.isEmpty else { return }
        // 프로젝트 zip에 같이 들어가는 정렬 파일(scan-group-alignment-v1). 만들기에 실패해도
        // 스캔 데이터 export 자체는 막지 않는다 -- 정렬은 데스크탑에서 다시 만들 수 있다.
        let alignmentJSON = (try? GroupAlignmentExport.data(for: group)) ?? nil

        isExporting = true
        exportErrorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let destURL = try Self.buildExportFile(
                    format: format, scans: scans, projectName: projectName, alignmentJSON: alignmentJSON
                )
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

    private static func buildExportFile(
        format: ExportFormat, scans: [ScanGroupMerger.ScanInput], projectName: String, alignmentJSON: Data? = nil
    ) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        // 프로젝트 이름은 자유 텍스트라(경로 구분자 등도 입력 가능) 파일 이름으로
        // 그대로 쓰면 안 된다 -- 경로로 해석될 수 있는 문자만 안전하게 바꾼다.
        let sanitized = projectName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = sanitized.isEmpty ? "project" : sanitized

        func fresh(_ ext: String) -> URL {
            let url = tempDir.appendingPathComponent("\(safeName).\(ext)")
            try? FileManager.default.removeItem(at: url)
            return url
        }

        switch format {
        case .zip, .zipMap:
            let profile: ScanExportProfile = format == .zipMap ? .map : .full
            let url = fresh(profile == .map ? "map.zip" : "zip")
            var extras: [ZipArchiver.ExtraFile] = []
            if let alignmentJSON {
                extras.append(.init(name: GroupAlignmentExport.fileName, data: alignmentJSON))
            }
            try ZipArchiver.zip(directories: scans.map(\.folderURL), extraFiles: extras, include: profile.zipFilter, to: url)
            return url

        case .ply:
            let merged = try ScanGroupMerger.mergeMesh(scans: scans)
            let url = fresh("ply")
            try PLYWriter.write(positions: merged.positions, normals: merged.normals, indices: merged.indices, to: url)
            return url

        case .pcd:
            let merged = try ScanGroupMerger.mergeMesh(scans: scans)
            let url = fresh("pcd")
            try PCDWriter.write(positions: merged.positions, to: url)
            return url

        case .glb:
            let merged = try ScanGroupMerger.mergeMesh(scans: scans)
            // GLBWriter는 텍스처를 필수로 받는다(TextureBaker 전용으로 설계됨) --
            // 합쳐진 결과는 무채색이라(MeshExporter와 같은 방침) 1x1 흰 텍스처를
            // placeholder로 채운다. 인덱스 버퍼도 지원 안 해서 unindexedForGLB로 편다.
            let (positions, normals, vertexCount) = merged.unindexedForGLB()
            let uvs = [Float](repeating: 0, count: vertexCount * 2)
            let whitePixel: [UInt8] = [255, 255, 255, 255]
            let url = fresh("glb")
            try GLBWriter.write(
                positions: positions, normals: normals, uvs: uvs,
                textureRGBA: whitePixel, textureWidth: 1, textureHeight: 1, to: url
            )
            return url
        }
    }
}

import SwiftUI

/// 앱의 루트 화면. Documents 밑 scan_*/ 폴더들을 "프로젝트" 목록으로 보여주고,
/// 새 프로젝트 만들기 -> 스캔 -> 저장 흐름의 시작점 역할을 한다.
struct ProjectListView: View {
    @StateObject private var store = ProjectStore()
    @State private var isShowingNewProjectSheet = false
    @State private var newProjectName = ""
    @State private var isNavigatingToScan = false
    @State private var activeProjectName = ""
    @State private var shareItem: ShareItem?
    @State private var exportingProjectID: String?
    @State private var isShowingServerSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if store.projects.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(store.projects) { project in
                            projectRow(project)
                        }
                    }
                }
            }
            .navigationTitle("스캔메시")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newProjectName = ProjectListView.defaultProjectName()
                        isShowingNewProjectSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        isShowingServerSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .navigationDestination(isPresented: $isNavigatingToScan) {
                ScanView(projectName: activeProjectName) {
                    store.refresh()
                }
            }
            .sheet(isPresented: $isShowingNewProjectSheet) {
                NewProjectSheet(name: $newProjectName, nameTaken: store.projectExists(named:)) {
                    activeProjectName = newProjectName
                    isShowingNewProjectSheet = false
                    isNavigatingToScan = true
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(activityItems: [item.url])
            }
            .sheet(isPresented: $isShowingServerSettings) {
                ServerSettingsView()
            }
            .onAppear { store.refresh() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.metering.none")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("스캔한 프로젝트가 없습니다")
                .font(.headline)
            Text("오른쪽 위 + 버튼으로 새 프로젝트를 시작하세요")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func projectRow(_ project: ScanProject) -> some View {
        NavigationLink {
            ProjectDetailView(project: project)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.id)
                        .font(.headline)
                    HStack(spacing: 8) {
                        if let frameCount = project.frameCount {
                            Text("\(frameCount) 프레임")
                        }
                        if project.hasUSDZ {
                            Label("mesh", systemImage: "cube")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if exportingProjectID == project.id {
                    ProgressView()
                } else {
                    Button {
                        exportingProjectID = project.id
                        store.exportZip(project) { url in
                            exportingProjectID = nil
                            if let url {
                                shareItem = ShareItem(url: url)
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                store.delete(project)
            } label: {
                Label("삭제", systemImage: "trash")
            }
        }
    }

    static func defaultProjectName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}

private struct NewProjectSheet: View {
    @Binding var name: String
    let nameTaken: (String) -> Bool
    let onCreate: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var isNameValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !nameTaken(name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("프로젝트 이름", text: $name)
                        .autocorrectionDisabled()
                    if nameTaken(name) {
                        Text("이미 있는 이름입니다")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                } footer: {
                    Text("실제 저장 폴더 이름은 scan_<이름>이 됩니다.")
                }
            }
            .navigationTitle("새 프로젝트")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("만들기", action: onCreate)
                        .disabled(!isNameValid)
                }
            }
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

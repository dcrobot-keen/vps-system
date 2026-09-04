import SwiftUI

/// 앱의 루트 화면(이 뷰가 "프로젝트" 탭). `scan_groups.json`(ScanGroupStore)에 있는
/// 프로젝트들을 보여준다 -- 프로젝트 하나 = 여러 스캔(scan_<name>/)을 이어서 찍어
/// 모은 것. 실제 스캔 목록/스캔 시작은 ProjectGroupDetailView에서 한다.
struct ProjectGroupListView: View {
    @StateObject private var store = ScanGroupStore()
    @State private var isShowingNewProjectSheet = false
    @State private var newProjectName = ""
    @State private var isShowingServerSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if store.groups.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(store.groups) { group in
                            groupRow(group)
                        }
                    }
                }
            }
            .navigationTitle("스캔메시")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newProjectName = ProjectGroupListView.defaultProjectName()
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
            .sheet(isPresented: $isShowingNewProjectSheet) {
                NewScanGroupSheet(name: $newProjectName, nameTaken: store.groupExists(named:)) {
                    store.createGroup(name: newProjectName)
                    isShowingNewProjectSheet = false
                }
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
            Text("만든 프로젝트가 없습니다")
                .font(.headline)
            Text("오른쪽 위 + 버튼으로 새 프로젝트를 시작하세요")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func groupRow(_ group: ScanGroup) -> some View {
        NavigationLink {
            ProjectGroupDetailView(group: group, store: store)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(.headline)
                Text("스캔 \(group.scanIDs.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                store.deleteGroup(group)
            } label: {
                Label("삭제", systemImage: "trash")
            }
        }
    }

    static func defaultProjectName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}

private struct NewScanGroupSheet: View {
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
                    Text("만든 뒤 스캔을 여러 번 추가해서 이어붙일 수 있습니다.")
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

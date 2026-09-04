import SwiftUI

/// 앱의 루트 화면(이 뷰가 "프로젝트" 탭). `scan_groups.json`(ScanGroupStore)에 있는
/// 프로젝트들을 보여준다 -- 프로젝트 하나 = 따로 찍은 여러 스캔(scan_<name>/)을 모아
/// 정렬·합치는 단위. 실제 스캔 목록/스캔 추가/정렬/내보내기는 ProjectGroupDetailView.
///
/// 레이아웃(2026-09-04 사용자 피드백): 앱 이름을 목록 제목으로 쓰지 않고 목록이 실제로
/// 담고 있는 것("프로젝트")을 큰 제목으로, 설정은 오른쪽 위 ⋯ 메뉴 안으로, 새 항목
/// 만들기는 오른쪽 아래 플로팅 + 버튼으로 -- iOS의 흔한 목록 화면 관례.
struct ProjectGroupListView: View {
    @StateObject private var store = ScanGroupStore()
    @State private var isShowingNewProjectSheet = false
    @State private var newProjectName = ""
    @State private var isShowingServerSettings = false
    @State private var isShowingImportedFiles = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
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

                FloatingActionButton(systemImage: "plus") {
                    newProjectName = ProjectGroupListView.defaultProjectName()
                    isShowingNewProjectSheet = true
                }
            }
            .navigationTitle("프로젝트")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            isShowingImportedFiles = true
                        } label: {
                            Label("가져온 파일", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            isShowingServerSettings = true
                        } label: {
                            Label("설정", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $isShowingImportedFiles) {
                ImportedFilesView()
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
        ContentUnavailableView {
            Label("만든 프로젝트가 없습니다", systemImage: "square.stack.3d.up")
        } description: {
            Text("오른쪽 아래 + 버튼으로 새 프로젝트를 시작하세요")
        }
    }

    @ViewBuilder
    private func groupRow(_ group: ScanGroup) -> some View {
        NavigationLink {
            ProjectGroupDetailView(group: group, store: store)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(.headline)
                HStack(spacing: 6) {
                    Text("스캔 \(group.scanIDs.count)개")
                    Text("·")
                    Text(group.createdAt.formatted(date: .abbreviated, time: .omitted))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
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

/// 오른쪽 아래 플로팅 원형 버튼. 목록(ProjectGroupListView)과 프로젝트 화면
/// (ProjectGroupDetailView)이 같은 모양을 쓴다 -- 스크롤 내용 위에 항상 떠 있어야
/// 하므로 ZStack(alignment: .bottomTrailing) 안에서 쓴다.
struct FloatingActionButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        }
        .padding(20)
        .accessibilityLabel(Text(systemImage == "plus" ? "새 프로젝트" : "스캔 추가"))
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
                    Text("만든 뒤 스캔을 여러 개 추가하고, 정렬해서 하나로 합칠 수 있습니다.")
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

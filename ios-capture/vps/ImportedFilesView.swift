import SwiftUI
import UniformTypeIdentifiers

/// "프로젝트"(이 앱이 직접 스캔한 것) 밖에서 온 3D 결과물 — 파이프라인의 .ply,
/// scan-to-map-studio의 .glb, Gaussian Splatting 트랙에서 나올 .obj 등 — 을
/// Files 문서 선택기로 가져와서 목록으로 보여준다. LocalSend로 받은 파일을
/// Files 앱에 저장해두면 여기서 바로 골라올 수 있다.
struct ImportedFilesView: View {
    @StateObject private var store = ImportedFileStore()
    @State private var isShowingPicker = false

    var body: some View {
        NavigationStack {
            Group {
                if store.files.isEmpty {
                    ContentUnavailableView(
                        "가져온 파일 없음",
                        systemImage: "cube.transparent",
                        description: Text("오른쪽 위 +로 glb/pcd/ply/usdz/obj 파일을 가져오세요")
                    )
                } else {
                    List {
                        ForEach(store.files) { file in
                            NavigationLink {
                                UniversalModelViewer(file: file)
                            } label: {
                                fileRow(file)
                            }
                        }
                        .onDelete { offsets in
                            for offset in offsets { store.delete(store.files[offset]) }
                        }
                    }
                }
            }
            .navigationTitle("가져온 파일")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingPicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $isShowingPicker) {
                DocumentPicker { url in
                    store.importFile(from: url)
                }
            }
            .alert(
                "가져오기 실패",
                isPresented: Binding(
                    get: { store.importErrorMessage != nil },
                    set: { if !$0 { store.importErrorMessage = nil } }
                ),
                presenting: store.importErrorMessage
            ) { _ in
                Button("확인") { store.importErrorMessage = nil }
            } message: { message in
                Text(message)
            }
        }
    }

    private func fileRow(_ file: ImportedFile) -> some View {
        HStack {
            Image(systemName: icon(for: file.fileExtension))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                Text("\(file.fileExtension.uppercased()) · \(formattedSize(file.fileSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func icon(for fileExtension: String) -> String {
        switch fileExtension {
        case "pcd", "ply": return "circle.grid.3x3"
        default: return "cube"
        }
    }

    private func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// glb/pcd/ply/usdz/obj를 고를 수 있는 표준 Files 문서 선택기. 이 확장자들은
/// 시스템에 등록된 UTType이 아니어서(usdz만 표준) `UTType(filenameExtension:)`로
/// 즉석에서 만든다 — 앱이 그 타입의 "핸들러"로 등록될 필요 없이 그냥 골라오는
/// 용도라 이걸로 충분하다.
private struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let extraTypes = ["glb", "pcd", "ply"].compactMap { UTType(filenameExtension: $0) }
        let types = [UTType.usdz, UTType(filenameExtension: "obj")].compactMap { $0 } + extraTypes
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            for url in urls { onPick(url) }
        }
    }
}

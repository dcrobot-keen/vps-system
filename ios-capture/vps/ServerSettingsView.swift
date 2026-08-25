import SwiftUI

/// VPS 서버 주소를 입력받는 간단한 폼. Tailscale IP는 기기마다/재기동마다 바뀔 수
/// 있어서 하드코딩하지 않고 여기서 직접 설정한다.
struct ServerSettingsView: View {
    @StateObject private var store = ServerSettingsStore()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://100.x.x.x:8000", text: $store.serverURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("VPS 서버 주소")
                } footer: {
                    Text("같은 Tailscale 네트워크 또는 같은 Wi-Fi에 있는 서버의 주소를 입력하세요. "
                        + "예: http://100.64.1.2:8000")
                }
            }
            .navigationTitle("서버 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }
}

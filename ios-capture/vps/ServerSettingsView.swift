import SwiftUI

/// 설정 시트. 고급 모드/VPS 서버 주소(로봇 스택 연동)에 더해, 일반 사용자에게도
/// 의미 있는 것들 -- 저장 공간 요약, 앱 버전, 개인정보 처리방침 링크 -- 을 같이
/// 둔다(2026-09-04 IA 검토: 서버 항목만 있으면 일반 사용자에겐 빈 화면처럼 보임).
/// Tailscale IP는 기기마다/재기동마다 바뀔 수 있어서 하드코딩하지 않고 여기서 입력.
struct ServerSettingsView: View {
    @StateObject private var store = ServerSettingsStore()
    @Environment(\.dismiss) private var dismiss
    @State private var availableStorageText: String?
    @State private var scanDataSizeText: String?

    private static let privacyPolicyURL = URL(string: "https://dcrobot-keen.github.io/vps-system/privacy/")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("남은 공간", value: availableStorageText ?? "…")
                    LabeledContent("스캔 데이터", value: scanDataSizeText ?? "…")
                } header: {
                    Text("저장 공간")
                } footer: {
                    Text("스캔 데이터는 이 앱이 저장한 모든 스캔 폴더의 합계입니다. 스캔은 각 스캔 화면에서 지울 수 있습니다.")
                }

                Section {
                    Toggle("고급 모드", isOn: $store.isAdvancedModeEnabled)
                } footer: {
                    Text("로봇 시스템(VPS 서버)과 연동하는 기능을 켭니다. 일반적인 스캔·내보내기에는 필요 없습니다.")
                }

                if store.isAdvancedModeEnabled {
                    Section {
                        TextField("http://100.x.x.x:8000", text: $store.serverURLString)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("VPS 서버 주소")
                    } footer: {
                        // 한 리터럴로 합쳤다 -- 두 문자열을 +로 이어붙이면 String으로
                        // 타입이 굳어서 Text(_:LocalizedStringKey)가 아니라
                        // Text(_:String)(그대로 표시, 지역화 안 됨) 쪽으로 빠진다.
                        Text("같은 Tailscale 네트워크 또는 같은 Wi-Fi에 있는 서버의 주소를 입력하세요. 예: http://100.64.1.2:8000")
                    }
                }

                Section {
                    LabeledContent("버전", value: Self.versionString)
                    Link(destination: Self.privacyPolicyURL) {
                        Label("개인정보 처리방침", systemImage: "hand.raised")
                    }
                } header: {
                    Text("정보")
                } footer: {
                    Text("ScanMesh")
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
            .onAppear(perform: loadStorageSummary)
        }
    }

    /// 앱 이름은 앱 안에서 제목으로 쓰지 않는다(홈 화면 라벨만) -- 버전 옆 footer에
    /// 한 번만 보여준다.
    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// 스캔 폴더 합계는 파일이 수천 개일 수 있어 백그라운드에서 잰다.
    private func loadStorageSummary() {
        if let bytes = DeviceStorage.availableBytes() {
            availableStorageText = DeviceStorage.formatted(bytes)
        }
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        DispatchQueue.global(qos: .utility).async {
            let scanDirs = ((try? FileManager.default.contentsOfDirectory(
                at: documentsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []).filter { $0.lastPathComponent.hasPrefix("scan_") }
            let total = scanDirs.reduce(Int64(0)) { $0 + DeviceStorage.directorySizeBytes(at: $1) }
            let text = DeviceStorage.formatted(total)
            DispatchQueue.main.async { scanDataSizeText = text }
        }
    }
}

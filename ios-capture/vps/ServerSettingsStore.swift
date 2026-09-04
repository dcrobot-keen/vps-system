import Combine
import Foundation

/// VPS 서버 주소(예: `http://100.x.x.x:8000`, Tailscale IP라 사용자가 직접 입력)와
/// 진행 중인 업로드 job의 마지막으로 본 상태를 `UserDefaults`에 저장한다 -- 이 앱의
/// 첫 설정 저장소. `ProjectStore`와 같은 패턴으로 각 화면이 자기 인스턴스를 만들어
/// 쓴다(싱글턴 아님) -- 값 자체는 `UserDefaults`로 항상 같은 곳에서 읽고 쓰므로
/// 화면 간에 굳이 라이브 공유할 필요가 없다.
final class ServerSettingsStore: ObservableObject {
    @Published var serverURLString: String {
        didSet { UserDefaults.standard.set(serverURLString, forKey: Self.serverURLKey) }
    }

    /// "고급 모드" — 서버 업로드 같은 로봇 스택 연동 기능을 켜는 스위치. 기본 꺼짐.
    /// 일반 사용자(App Store)에게 앱은 서버 없이 완결된 LiDAR 스캐너여야 하고, 서버
    /// 연동은 우리 로봇 시스템을 쓰는 경우에만 의미가 있어서 설정 안쪽에 숨긴다
    /// (PRODUCT-PLAN.md "방향 C"). 다른 화면은 `@AppStorage(ServerSettingsStore
    /// .advancedModeKey)`로 같은 값을 읽는다.
    @Published var isAdvancedModeEnabled: Bool {
        didSet { UserDefaults.standard.set(isAdvancedModeEnabled, forKey: Self.advancedModeKey) }
    }

    static let advancedModeKey = "vpsAdvancedModeEnabled"
    private static let serverURLKey = "vpsServerURLString"
    private static let jobStatusesKey = "vpsUploadJobStatuses"

    init() {
        serverURLString = UserDefaults.standard.string(forKey: Self.serverURLKey) ?? ""
        isAdvancedModeEnabled = UserDefaults.standard.bool(forKey: Self.advancedModeKey)
    }

    /// 입력값이 스킴/호스트를 갖춘 URL이 아니면 nil -- 업로드 버튼을 그 경우
    /// 비활성화하는 데 쓴다.
    var serverURL: URL? {
        let trimmed = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            return nil
        }
        return url
    }

    /// scan_name -> 마지막으로 관측한 job status 문자열("building" 등). 화면을
    /// 나갔다 왔거나 업로드 도중 앱을 재실행해도 폴링을 이어갈 수 있게 남겨둔다 --
    /// 실제 진실은 서버 쪽 job 상태이고 이건 재개용 힌트일 뿐이다.
    func lastKnownStatus(forScanName scanName: String) -> String? {
        Self.readJobStatuses()[scanName]
    }

    func setLastKnownStatus(_ status: String?, forScanName scanName: String) {
        var statuses = Self.readJobStatuses()
        if let status {
            statuses[scanName] = status
        } else {
            statuses.removeValue(forKey: scanName)
        }
        guard let data = try? JSONEncoder().encode(statuses) else { return }
        UserDefaults.standard.set(data, forKey: Self.jobStatusesKey)
    }

    private static func readJobStatuses() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: jobStatusesKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }
}

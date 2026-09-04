import Foundation

/// 스캔 시작 전/중에 남은 저장 공간을 확인하고, 프로젝트 폴더 하나의 용량을 잰다.
/// 스캔 하나가 프레임당 rgb(JPEG) + depth/confidence(raw float32) 합쳐 대략
/// 0.5~1MB라, 수백~수천 프레임짜리 스캔은 수백 MB~수 GB를 쓸 수 있다 -- 저장 공간이
/// 부족한 채로 시작하면 중간에 조용히 프레임 저장이 실패하기 시작한다
/// (`ScanSessionManager.recordSaveFailure`가 반응은 하지만, 사전에 알려주는 게 낫다).
enum DeviceStorage {
    /// 이 밑으로 떨어지면 스캔 시작 전에 "부족할 수 있다"고 알린다 -- 방 하나
    /// 스캔에 필요한 대략적인 여유(수백 MB~1GB)를 감안한 값.
    static let lowStorageWarningBytes: Int64 = 1_000_000_000 // 1GB

    /// 이 밑에서는 스캔 도중이라도 몇 분 안에 저장이 실패하기 시작할 가능성이 높아
    /// `ScanSessionManager`가 더 강하게 경고한다.
    static let criticalStorageBytes: Int64 = 200_000_000 // 200MB

    /// Documents 볼륨의 가용 공간. `volumeAvailableCapacityForImportantUsage`는 시스템이
    /// 캐시 정리 등으로 추가 확보해줄 수 있는 여유까지 포함해서, 단순
    /// `volumeAvailableCapacity`보다 "실제로 앱이 쓸 수 있는 양"에 더 가깝다.
    static func availableBytes() -> Int64? {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let values = try? documentsDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    /// "12.3GB" 같은 사람이 읽기 좋은 문자열.
    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// `scan_<name>/` 폴더 하나의 전체 용량(모든 하위 파일 합산). 파일이 수백~수천
    /// 개일 수 있어 호출부(ProjectDetailView)가 백그라운드 큐에서 불러야 한다.
    static func directorySizeBytes(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey]),
                  values.isDirectory != true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

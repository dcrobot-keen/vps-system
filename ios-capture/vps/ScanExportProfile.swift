import Foundation

/// 프로젝트 zip을 내보낼 때 스캔 폴더에서 무엇을 넣을지 고르는 프로파일.
///
/// 스캔 폴더는 대부분이 VPS DB 빌드용 프레임(`rgb/` 1920×1440 JPEG, `depth/` float32)이라
/// 방 하나에 700 MB 안팎인데, 2D 지도·슬라이스·시뮬레이터 월드·정렬 워크스페이스는
/// `scan.usdz`(수 MB)와 바닥 평면, 궤적만 쓴다. 지도 작업에 필요한 것만 담는 `map`
/// 프로파일이면 같은 프로젝트가 수 MB로 나간다. `full`은 지금까지의 동작 그대로다.
///
/// `map` 결과는 scan_<name>/ 포맷의 **부분집합**이라 `conformance_check.py`는 통과하지
/// 않는다(rgb/depth가 없으니). scan-to-map-studio의 `studio.py process --usdz`,
/// `slice_map.py`, `merge_slicemaps.py`, `align_workspace.py`는 이 부분집합만으로 동작한다.
enum ScanExportProfile: String, CaseIterable, Identifiable {
    case full
    case map

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: return "프로젝트 전체 (zip)"
        case .map: return "지도용 zip (usdz·바닥평면·궤적)"
        }
    }

    /// `map`이 남기는 파일. 스캔 폴더 기준 상대경로(접두사 없음, `/` 구분).
    static let mapFiles: Set<String> = [
        "manifest.json",
        "poses/poses.jsonl",
        "scan.usdz",
        "floorplan.png",
        "floorplan.json",
    ]

    /// 이 상대경로를 zip에 넣을지. `full`은 전부, `map`은 `mapFiles`만.
    func includes(relativePath: String) -> Bool {
        switch self {
        case .full: return true
        case .map: return Self.mapFiles.contains(relativePath)
        }
    }

    /// ZipArchiver에 넘길 필터. `full`이면 nil(필터 없음).
    var zipFilter: ((String) -> Bool)? {
        switch self {
        case .full: return nil
        case .map: return { Self.mapFiles.contains($0) }
        }
    }
}

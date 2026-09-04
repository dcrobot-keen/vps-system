import Foundation

/// 프로젝트(ScanGroup)의 스캔별 정렬 변환을 데스크탑 파이프라인이 읽는 파일로 만든다.
///
/// 포맷 `scan-group-alignment-v1`은 scan-to-map-studio의 `studio/merge_slicemaps.py`가
/// 정본으로 읽고(스캔별 slicemap을 이 변환으로 한 격자에 합성 → 시뮬레이터 월드,
/// nav.html iPhone 맵, pathfinder), 데스크탑 정합 워크스페이스가 같은 파일에
/// method/metrics를 덧붙여 확정본을 만든다. 앱은 여기서 "초안"(앵커링·수동 정렬 값)을
/// 내보내고, 확정본을 다시 가져오는 왕복은 다음 단계다(전략 문서 "데이터 계약").
///
/// 변환 의미는 `ScanAlignment.applyXZ`와 같다: 스캔 로컬 ARKit (x, z)를 기준 스캔
/// (scanIDs 첫 항목) 좌표계로 옮기는 "회전 후 이동". `up_axis_convention`은 2D 화면
/// 관례(위 = -z, 2026-09-04 거울상 정정 이후)를 소비자가 확인할 수 있게 적어둔다.
enum GroupAlignmentExport {
    static let fileName = "group_alignment.json"
    static let format = "scan-group-alignment-v1"
    static let upAxisConvention = "top = -z"

    struct Entry: Codable, Equatable {
        let offsetX: Float
        let offsetZ: Float
        let yawRadians: Float
        /// "app" = 사용자가 정렬 화면이나 앵커링으로 실제로 놓은 값, "identity" = 아직
        /// 정렬한 적 없음(값은 0). 데스크탑이 ICP/기준점 쌍으로 고치면 그쪽 이름으로 바뀐다.
        let method: String
    }

    struct Document: Codable, Equatable {
        let format: String
        let group: String
        let reference: String
        let up_axis_convention: String
        /// 기준 스캔은 들어가지 않는다(항상 identity). 나머지 스캔은 정렬 여부와 상관없이
        /// 전부 들어가서, 소비자가 "이 프로젝트에 스캔이 몇 개인지"를 이 파일만으로 안다.
        let alignments: [String: Entry]
    }

    /// 스캔이 하나도 없는 그룹은 기준을 정할 수 없어 nil.
    static func document(for group: ScanGroup) -> Document? {
        guard let reference = group.scanIDs.first else { return nil }
        var entries: [String: Entry] = [:]
        for scanID in group.scanIDs.dropFirst() {
            let a = group.alignment(for: scanID)
            entries[scanID] = Entry(
                offsetX: a.offsetX,
                offsetZ: a.offsetZ,
                yawRadians: a.yawRadians,
                method: group.alignments[scanID] == nil ? "identity" : "app"
            )
        }
        return Document(
            format: format,
            group: group.name,
            reference: reference,
            up_axis_convention: upAxisConvention,
            alignments: entries
        )
    }

    /// 사람이 diff로 읽을 수 있게 키 정렬 + 줄바꿈. 스캔이 없으면 nil.
    static func data(for group: ScanGroup) throws -> Data? {
        guard let doc = document(for: group) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(doc)
    }
}

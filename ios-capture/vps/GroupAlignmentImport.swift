import Foundation

/// 데스크탑 정합 워크스페이스(scan-to-map-studio, `/groups/<프로젝트>`)가 확정한
/// `group_alignment.json`(scan-group-alignment-v1)을 프로젝트(ScanGroup)에 되돌려 넣는다 --
/// `GroupAlignmentExport`의 역방향. 이걸로 앱의 위치 확인 화면과 합친 mesh가 데스크탑에서
/// 고친 자리를 그대로 쓴다(전략 문서 "데이터 계약", Phase 3 왕복).
///
/// 규칙: `reference`가 이 프로젝트의 첫 스캔과 같아야 한다(다른 프로젝트 파일을 잘못
/// 고른 경우를 막는다). 프로젝트에 없는 스캔 id는 건너뛰고 알려준다. `method`/`metrics`는
/// 데스크탑 쪽 정보라 앱 모델(ScanAlignment 세 값)에는 들어가지 않는다.
enum GroupAlignmentImport {
    enum ImportError: LocalizedError, Equatable {
        case notAlignmentFile(found: String?)
        case referenceMismatch(file: String, group: String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .notAlignmentFile(let found):
                return "정렬 파일(scan-group-alignment-v1)이 아닙니다" + (found.map { " (format: \($0))" } ?? "")
            case .referenceMismatch(let file, let group):
                return "다른 프로젝트의 정렬 파일입니다: 기준 스캔이 \(file), 이 프로젝트는 \(group)"
            case .malformed(let what):
                return "정렬 파일을 읽을 수 없습니다: \(what)"
            }
        }
    }

    struct Result: Equatable {
        let reference: String
        /// 이 프로젝트의 스캔에 해당하는 항목만.
        let alignments: [String: ScanAlignment]
        /// 파일에는 있지만 이 프로젝트에 없는 스캔 id.
        let skipped: [String]
        /// 데스크탑이 붙인 method (표시용).
        let methods: [String: String]
    }

    static func parse(_ data: Data, group: ScanGroup) throws -> Result {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch { throw ImportError.malformed(error.localizedDescription) }
        guard let doc = object as? [String: Any] else { throw ImportError.malformed("최상위가 객체가 아님") }
        let format = doc["format"] as? String
        guard format == GroupAlignmentExport.format else { throw ImportError.notAlignmentFile(found: format) }
        guard let reference = doc["reference"] as? String, !reference.isEmpty else { throw ImportError.malformed("reference 없음") }
        guard let groupReference = group.scanIDs.first else { throw ImportError.malformed("프로젝트에 스캔이 없음") }
        guard reference == groupReference else { throw ImportError.referenceMismatch(file: reference, group: groupReference) }
        guard let entries = doc["alignments"] as? [String: Any] else { throw ImportError.malformed("alignments 없음") }

        var alignments: [String: ScanAlignment] = [:]
        var methods: [String: String] = [:]
        var skipped: [String] = []
        let inGroup = Set(group.scanIDs)
        for (scanID, raw) in entries {
            guard let e = raw as? [String: Any] else { throw ImportError.malformed("alignments[\(scanID)]가 객체가 아님") }
            guard let ox = number(e["offsetX"]), let oz = number(e["offsetZ"]), let yaw = number(e["yawRadians"]) else {
                throw ImportError.malformed("alignments[\(scanID)]의 offsetX/offsetZ/yawRadians가 숫자가 아님")
            }
            guard inGroup.contains(scanID), scanID != reference else { skipped.append(scanID); continue }
            alignments[scanID] = ScanAlignment(offsetX: ox, offsetZ: oz, yawRadians: yaw)
            if let m = e["method"] as? String { methods[scanID] = m }
        }
        return Result(reference: reference, alignments: alignments, skipped: skipped.sorted(), methods: methods)
    }

    private static func number(_ v: Any?) -> Float? {
        if let d = v as? Double, d.isFinite { return Float(d) }
        if let i = v as? Int { return Float(i) }
        return nil
    }
}

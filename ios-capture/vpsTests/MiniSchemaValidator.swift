import Foundation

/// 이 프로젝트의 스캔 포맷 회귀 게이트에 필요한 만큼만 지원하는 아주 좁은 JSON
/// Schema 서브셋 검증기다 -- 범용 JSON Schema 구현이 아니다. `required` 존재 여부와
/// `properties`의 `type`(1단계 중첩까지, `intrinsics` 객체 검증용)만 본다. 이
/// 프로젝트가 실제로 쓰는 두 스키마(`manifest.schema.json`, `pose-record.schema.json`)
/// 가 그 이상을 안 쓰기 때문에 이걸로 충분하다 -- 더 정교한 검증이 필요해지면 그때
/// 확장한다.
enum MiniSchemaValidator {
    static func violations(of json: [String: Any], against schema: [String: Any]) -> [String] {
        var errors: [String] = []
        let required = schema["required"] as? [String] ?? []
        for key in required where json[key] == nil {
            errors.append("missing required key: \(key)")
        }
        guard let properties = schema["properties"] as? [String: Any] else { return errors }
        for key in required {
            guard let value = json[key], let propSchema = properties[key] as? [String: Any] else { continue }
            errors.append(contentsOf: checkType(value: value, schema: propSchema, path: key))
        }
        return errors
    }

    private static func checkType(value: Any, schema: [String: Any], path: String) -> [String] {
        guard let type = schema["type"] as? String else { return [] }
        switch type {
        case "string":
            return value is String ? [] : ["\(path): expected string"]
        case "number":
            return value is NSNumber ? [] : ["\(path): expected number"]
        case "integer":
            guard let n = value as? NSNumber else { return ["\(path): expected integer"] }
            return n.doubleValue.truncatingRemainder(dividingBy: 1) == 0 ? [] : ["\(path): expected integer, got fractional"]
        case "array":
            return value is [Any] ? [] : ["\(path): expected array"]
        case "object":
            guard let obj = value as? [String: Any] else { return ["\(path): expected object"] }
            var errors: [String] = []
            for key in (schema["required"] as? [String] ?? []) where obj[key] == nil {
                errors.append("\(path).\(key): missing required key")
            }
            if let nestedProps = schema["properties"] as? [String: Any] {
                for (k, v) in obj {
                    guard let propSchema = nestedProps[k] as? [String: Any] else { continue }
                    errors.append(contentsOf: checkType(value: v, schema: propSchema, path: "\(path).\(k)"))
                }
            }
            return errors
        default:
            return []
        }
    }
}

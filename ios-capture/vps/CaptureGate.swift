import Foundation
import simd

/// 프레임 저장 게이트: "움직였을 때만, 너무 자주는 말고".
///
/// 예전 규칙은 `elapsed >= interval || distance >= minDistance`였다 -- 0.1초만 지나면
/// 무조건 저장이라 제자리에 서 있어도 초당 10장이 쌓였고, 방 하나 750프레임 중 상당수가
/// 거의 같은 사진이었다. 새 규칙은 두 조건을 AND로 묶고 회전을 더한다:
///
///     elapsed >= interval  &&  (distance >= minDistance || angle >= minAngle)
///
/// - 서 있으면 저장 안 함(크기 절감), 제자리에서 돌면 회전 임계마다 저장(커버리지 유지),
///   걸으면 거리 임계마다 저장. `interval`은 상한(최대 저장률)일 뿐이다.
/// - 첫 프레임(이전 pose 없음)은 무조건 저장.
///
/// ARFrame에 의존하지 않는 값만 받아 `CaptureGateTests`로 검증한다.
struct CaptureGate {
    var intervalSeconds: TimeInterval = 0.1
    var minDistanceMeters: Float = 0.2
    var minRotationRadians: Float = 15 * .pi / 180

    var minRotationDegrees: Float { minRotationRadians * 180 / .pi }

    /// `distance`/`angle`이 nil이면 이전 pose가 없다는 뜻(세션 첫 프레임).
    func shouldSave(elapsed: TimeInterval, distance: Float?, angle: Float?) -> Bool {
        guard let distance, let angle else { return true }
        guard elapsed >= intervalSeconds else { return false }
        return distance >= minDistanceMeters || angle >= minRotationRadians
    }

    /// 두 카메라 변환 사이의 회전각(라디안, 0...pi). 위치는 무시하고 3x3 회전만 비교한다.
    static func rotationAngle(from a: simd_float4x4, to b: simd_float4x4) -> Float {
        let ra = simd_float3x3(simd_float3(a.columns.0.x, a.columns.0.y, a.columns.0.z),
                               simd_float3(a.columns.1.x, a.columns.1.y, a.columns.1.z),
                               simd_float3(a.columns.2.x, a.columns.2.y, a.columns.2.z))
        let rb = simd_float3x3(simd_float3(b.columns.0.x, b.columns.0.y, b.columns.0.z),
                               simd_float3(b.columns.1.x, b.columns.1.y, b.columns.1.z),
                               simd_float3(b.columns.2.x, b.columns.2.y, b.columns.2.z))
        let rel = simd_quatf(ra.inverse * rb)
        // quaternion angle is in [0, 2pi); fold to the shortest rotation
        let angle = rel.angle
        return angle > .pi ? 2 * .pi - angle : angle
    }

    static func position(of t: simd_float4x4) -> simd_float3 {
        simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    }
}

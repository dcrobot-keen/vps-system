import Foundation
import simd

/// 2D 지면(ground-plane) pose. scan-to-map-studio의 "Z-up" 평면 컨벤션
/// (아래 GroundPose.fromARKitTransform 참고) 위에서의 x/y/heading이다.
struct GroundPose {
    var x: Double
    var y: Double
    var headingRad: Double
}

extension GroundPose {
    /// ARKit의 camera-to-world 4x4 변환(Y-up, 카메라는 로컬 -Z를 바라봄)을
    /// scan-to-map-studio가 실제로 쓰는 평면 컨벤션으로 옮긴다.
    ///
    /// 이 변환은 새로 정하는 게 아니라 이미 문서화된 관례를 그대로 따른 것이다 --
    /// `vps-system/pipeline/dc_vps_pipeline/export_pointcloud.py`가 정확히 이렇게
    /// 적어뒀다: "ARKit(Y-up) -> scan-to-map-studio 관례(Z-up): (x, y, z) -> (x, -z, y)".
    /// 즉 지면(바닥) 평면은 ARKit의 (X, -Z)이고 ARKit의 Y(높이)는 다루지 않는다 --
    /// heading도 같은 평면에 투영해서 뽑아야 한다(단순히 쿼터니언의 Z 성분을 쓰면
    /// ARKit이 아니라 Z-up 프레임을 가정한 공식이라 여기선 안 맞는다).
    static func fromARKitTransform(_ transform: simd_float4x4) -> GroundPose {
        let position = transform.columns.3
        let x = Double(position.x)
        let y = Double(-position.z)

        // 카메라 로컬 -Z(전방)을 world로 변환한 뒤 같은 평면 변환((x,y,z)->(x,-z,y))을
        // 적용해서 heading을 구한다. transform.columns.2는 카메라 로컬 +Z축의 world
        // 방향이므로, 전방은 그 반대(-columns.2)다.
        let localForward = -simd_float3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        let headingRad = atan2(Double(-localForward.z), Double(localForward.x))

        return GroundPose(x: x, y: y, headingRad: headingRad)
    }
}

/// scan-to-map-studio의 `registration_transform.json`
/// ({"rotation_deg": ..., "translation": [tx, ty]}) 그대로. ICP 정합 결과로,
/// "map(로봇 SLAM) 좌표 -> scan_basemap(이 스캔) 좌표" 방향이다:
///   scan_basemap_point = R(rotation_deg) @ map_point + translation
/// (scan-to-map-studio의 studio/tf_export.py 문서 주석과 동일).
struct RegistrationTransform: Decodable {
    let rotationDeg: Double
    let translation: [Double]

    enum CodingKeys: String, CodingKey {
        case rotationDeg = "rotation_deg"
        case translation
    }

    /// scan_<name>/registration_transform.json이 있으면 읽는다. scan-to-map-studio는
    /// 별도(보통 데스크탑) 파이프라인이라 이 파일이 자동으로 생기지 않는다 --
    /// 사용자가 Files 앱 등으로 직접 이 스캔 폴더에 복사해 넣어야 한다(LocalizeView의
    /// "정합 파일 가져오기" 참고). 없으면 nil을 반환하고, 그 경우 위치 확인 화면은
    /// scan_basemap(이 스캔 자체) 좌표만 보여준다.
    static func load(from projectURL: URL) -> RegistrationTransform? {
        let url = projectURL.appendingPathComponent("registration_transform.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RegistrationTransform.self, from: data)
    }

    /// pathfinder의 `src/livePoseTransform.js`(scanBasemapToMap)와 **동일한 수학**이다
    /// -- 수정 시 두 곳을 같이 바꿀 것. scan_basemap 프레임의 pose를 map 프레임으로
    /// 옮긴다(정합 변환의 역방향, R(theta)^-1 = R(-theta)).
    func scanBasemapToMap(_ pose: GroundPose) -> GroundPose {
        let theta = rotationDeg * .pi / 180
        let cosT = cos(theta)
        let sinT = sin(theta)
        let tx = translation.count > 0 ? translation[0] : 0
        let ty = translation.count > 1 ? translation[1] : 0
        let dx = pose.x - tx
        let dy = pose.y - ty
        return GroundPose(
            x: cosT * dx + sinT * dy,
            y: -sinT * dx + cosT * dy,
            headingRad: pose.headingRad - theta
        )
    }
}

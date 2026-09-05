import Foundation

/// `scan_<name>/manifest.json`과 `poses/poses.jsonl` 레코드를 만드는 순수 함수만
/// 모아둔 곳. `ScanSessionManager.appendPose`/`writeManifest`가 그대로 쓴다 --
/// ARKit 타입(`ARFrame` 등)에 의존하지 않는 원시 값만 받게 분리해서, 이 두 함수를
/// `vps-system/scan-format/*.schema.json`(정본, item ④) 대조 테스트로 직접
/// 검증할 수 있게 한다(ARFrame은 테스트에서 만들 수 없음). 두 파일의 실제 소비자
/// (vps-system/pipeline, dc-vps-digital-twin)는 이 키 이름을 그대로 읽으므로,
/// 여기서 키를 하나라도 빼거나 이름을 바꾸면 다운스트림이 조용히 깨진다 -- 이
/// 파일이 스캔 포맷 계약의 Swift 쪽 유일한 소스다.
enum ScanRecordBuilder {
    static func buildPoseRecord(
        frameId: Int,
        timestamp: TimeInterval,
        rgbPath: String,
        depthPath: String,
        cameraTransform: [[Float]],
        intrinsics: (fx: Float, fy: Float, cx: Float, cy: Float, width: Int, height: Int),
        trackingState: String
    ) -> [String: Any] {
        [
            "frame_id": frameId,
            "timestamp": timestamp,
            "rgb_path": rgbPath,
            "depth_path": depthPath,
            "camera_transform": cameraTransform,
            "intrinsics": [
                "fx": intrinsics.fx,
                "fy": intrinsics.fy,
                "cx": intrinsics.cx,
                "cy": intrinsics.cy,
                "width": intrinsics.width,
                "height": intrinsics.height,
            ],
            "tracking_state": trackingState,
        ]
    }

    static func buildManifest(
        sessionName: String,
        deviceModel: String,
        systemVersion: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        frameCount: Int,
        captureIntervalSeconds: TimeInterval,
        captureMinDistanceMeters: Float,
        depthEncoding: [String: Any]? = nil
    ) -> [String: Any] {
        var manifest: [String: Any] = [
            "session_name": sessionName,
            "device_model": deviceModel,
            "system_version": systemVersion,
            "start_time": startTime,
            "end_time": endTime,
            "frame_count": frameCount,
            "capture_interval_seconds": captureIntervalSeconds,
            "capture_min_distance_meters": captureMinDistanceMeters,
        ]
        // depth/*.depth, *.conf 인코딩(DepthEncoding.manifestEntry). 없으면 읽는 쪽은 v1로
        // 본다 -- depth 프레임을 하나도 못 쓴 세션에서만 비어 있다.
        if let depthEncoding {
            manifest["depth_encoding"] = depthEncoding
        }
        return manifest
    }
}

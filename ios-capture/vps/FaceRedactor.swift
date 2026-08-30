import CoreImage
import Vision

/// 캡처한 RGB 프레임에서 사람 얼굴을 감지해 모자이크 처리한다. 공용 공간을
/// 스캔하다 보면 사람이 찍히는 걸 완전히 피하기 어려운데, 그 사진들이 VPS DB
/// 빌드(서버 업로드)/텍스처 베이킹(`TextureBaker`, `scan.usdz`에 사진 그대로
/// 프로젝션)/썸네일 그리드에 그대로 쓰인다 -- `ScanSessionManager.saveRGB`에서
/// JPEG로 인코딩하기 직전에 호출해서, 원본(비식별화 전) 얼굴 픽셀이 디스크에
/// 한 번도 안 남게 한다. 얼굴 검출은 Vision 프레임워크로 완전히 온디바이스에서
/// 돈다(네트워크 호출 없음, 서버에 원본이 갈 일도 없음).
enum FaceRedactor {
    /// ciImage 안의 얼굴 영역을 강한 pixellate로 뭉갠 새 CIImage를 반환한다.
    /// 얼굴이 하나도 없으면 원본을 그대로 반환한다(불필요한 재렌더링 방지 --
    /// 대부분의 프레임에는 사람이 없으므로 이 경로가 훨씬 자주 탄다).
    static func redactFaces(in ciImage: CIImage) -> CIImage {
        let request = VNDetectFaceRectanglesRequest()
        // ARKit의 capturedImage는 항상 raw(landscape) 방향이고 이 앱은 회전 보정을
        // 하지 않는 정책이다(ScanSessionManager 상단 주석 참고) -- 스캔은 보통
        // 세로로 들고 하므로, 그 경우 landscape 버퍼를 세워서 보려면 시계 방향
        // 90도 회전이 필요하다(.right). 기기를 가로로 들고 스캔하면 검출 정확도가
        // 떨어질 수 있다(알려진 한계).
        let handler = VNImageRequestHandler(ciImage: ciImage, orientation: .right)
        try? handler.perform([request])

        guard let observations = request.results as? [VNFaceObservation], !observations.isEmpty else {
            return ciImage
        }

        var result = ciImage
        let imageExtent = ciImage.extent
        for observation in observations {
            // Vision의 boundingBox는 정규화 좌표(원점 좌하단, [0,1])다. 얼굴 검출이
            // 이마/턱/귀를 살짝 놓치는 경우가 있어 여유를 두고 확장한다 -- 얼굴
            // 일부가 그대로 남는 것보다 배경을 조금 더 가리는 쪽이 안전하다.
            let box = observation.boundingBox
            let margin = 0.3
            let expanded = CGRect(
                x: box.minX - box.width * margin,
                y: box.minY - box.height * margin,
                width: box.width * (1 + 2 * margin),
                height: box.height * (1 + 2 * margin)
            )
            let faceRect = VNImageRectForNormalizedRect(expanded, Int(imageExtent.width), Int(imageExtent.height))
                .intersection(imageExtent)
            guard !faceRect.isEmpty else { continue }

            // CIPixellate의 스케일(모자이크 블록 크기)을 얼굴 크기에 비례시켜서,
            // 사진 해상도나 얼굴이 화면에서 차지하는 크기와 무관하게 항상 알아볼
            // 수 없을 만큼 뭉개지도록 한다.
            let blockSize = max(faceRect.width, faceRect.height) / 8
            let pixellated = result
                .clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: blockSize])
                .cropped(to: faceRect)

            result = pixellated.composited(over: result)
        }
        return result
    }
}

import CoreGraphics
import UIKit

/// floorplan.png를 RGBA 바이트로 풀어둔 것. 정렬 화면(ScanAlignmentView)이 (1) 못 본
/// 곳(회색)을 투명하게 뚫어 다른 스캔이 비쳐 보이게 하고 (2) 스캔마다 다른 색으로 틴트한
/// 이미지를 만들고 (3) 자동 맞춤(ScanRegistration)에 넣을 벽 픽셀을 world (x, z) 점으로
/// 뽑는 데 쓴다. 픽셀 분류는 FloorPlanRenderer의 색 관례를 따른다 -- free 흰색,
/// occupied 검정, unknown 205 회색, 경로 파랑, 마커 초록/빨강, 텍스처 베이킹 후엔
/// 바닥이 사진 색(그래서 "검정에 가까우면 벽, 205 회색이면 미확인, 나머지는 바닥/기타"로
/// 느슨하게 본다 -- 아주 어두운 바닥 사진은 벽으로 잘못 잡힐 수 있지만 드물다).
struct FloorPlanPixels {
    enum Kind {
        case unknown
        case wall
        case other
    }

    let width: Int
    let height: Int
    /// RGBA8 premultipliedLast, row 0이 이미지 위쪽. 원본이 불투명이라 alpha는 전부 255.
    private let rgba: [UInt8]

    init?(image: UIImage) {
        guard let cg = image.cgImage, cg.width > 0, cg.height > 0 else { return nil }
        let width = cg.width, height = cg.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        rgba = buffer
    }

    func kind(col: Int, row: Int) -> Kind {
        guard col >= 0, col < width, row >= 0, row < height else { return .unknown }
        return kind(at: (row * width + col) * 4)
    }

    private func kind(at i: Int) -> Kind {
        let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
        if r <= 40, g <= 40, b <= 40 { return .wall }
        if abs(r - 205) <= 8, abs(g - 205) <= 8, abs(b - 205) <= 8 { return .unknown }
        return .other
    }

    /// 벽 픽셀 중심의 world (x, z) -- 이 스캔의 로컬 좌표(정렬 변환 전). `maxPoints`보다
    /// 많으면 래스터 순서로 일정 간격 솎는다(ICP엔 수천 점이면 충분).
    func wallPointsXZ(meta: FloorPlanRenderer.PersistedMeta, maxPoints: Int) -> [SIMD2<Float>] {
        let resolution = meta.resolutionMetersPerPixel
        var points: [SIMD2<Float>] = []
        for row in 0..<height {
            for col in 0..<width where kind(at: (row * width + col) * 4) == .wall {
                points.append(SIMD2(
                    meta.originX + (Float(col) + 0.5) * resolution,
                    meta.originTopZ + (Float(row) + 0.5) * resolution
                ))
            }
        }
        guard points.count > maxPoints, maxPoints > 0 else { return points }
        let step = Int((Double(points.count) / Double(maxPoints)).rounded(.up))
        return points.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil }
    }

    /// 못 본 곳만 투명하게 뚫고 나머지는 원래 색 -- 위치 확인 화면의 배경 지도용.
    func overlayImage() -> UIImage? {
        makeImage { kind, r, g, b in
            kind == .unknown ? (0, 0, 0, 0) : (r, g, b, 255)
        }
    }

    /// 정렬 화면용: 못 본 곳 투명, 벽은 `tint` 불투명, 바닥은 `tint` 옅게, 경로/마커/사진
    /// 바닥처럼 채도 있는 픽셀은 원래 색(어느 스캔인지는 벽 색으로 구분되고, 경로와
    /// 시작 마커는 맞출 때 좋은 단서라 남긴다).
    func tintedImage(_ tint: UIColor) -> UIImage? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        tint.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let tr = UInt8(max(0, min(255, red * 255))), tg = UInt8(max(0, min(255, green * 255))), tb = UInt8(max(0, min(255, blue * 255)))
        return makeImage { kind, r, g, b in
            switch kind {
            case .unknown:
                return (0, 0, 0, 0)
            case .wall:
                return (tr, tg, tb, 255)
            case .other:
                let saturation = Int(max(r, g, b)) - Int(min(r, g, b))
                return saturation > 60 ? (r, g, b, 230) : (tr, tg, tb, 70)
            }
        }
    }

    /// 픽셀마다 (분류, r, g, b) -> (r, g, b, a)로 바꿔 새 이미지를 만든다(premultiply는 여기서).
    private func makeImage(_ map: (Kind, UInt8, UInt8, UInt8) -> (UInt8, UInt8, UInt8, UInt8)) -> UIImage? {
        var out = [UInt8](repeating: 0, count: rgba.count)
        var i = 0
        while i < rgba.count {
            let (r, g, b, a) = map(kind(at: i), rgba[i], rgba[i + 1], rgba[i + 2])
            if a == 255 {
                out[i] = r; out[i + 1] = g; out[i + 2] = b; out[i + 3] = 255
            } else if a > 0 {
                let alpha = Int(a)
                out[i] = UInt8(Int(r) * alpha / 255)
                out[i + 1] = UInt8(Int(g) * alpha / 255)
                out[i + 2] = UInt8(Int(b) * alpha / 255)
                out[i + 3] = a
            }
            i += 4
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let cg = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }
}

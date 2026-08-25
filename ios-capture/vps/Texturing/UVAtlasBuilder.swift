import Foundation
import simd

/// "다이아몬드" UV 아틀라스: 전역 UV unwrap 없이 삼각형 두 개(정사각형 하나)씩 순서대로
/// 아틀라스에 채워 넣는다 — 지저분한 LiDAR mesh 위상에서 chart 기반 unwrap이 겪던 문제를
/// 원천적으로 피한다. `project_photos_onto_lidar_mesh.py`의 `build_uv_atlas` 포트.
///
/// face f의 3개 코너는 원본 삼각형의 정점 순서(0,1,2)와 코너 위치로 1:1 대응한다 —
/// `TextureBaker`가 face f, corner i의 world position(원본 mesh)과 uv(이 아틀라스)를
/// 같은 (f,i) 인덱스로 짝지어 쓴다.
enum UVAtlasBuilder {
    struct Atlas {
        var textureSize: Int
        /// length == faceCount * 3, [f*3 + corner] = 그 코너의 UV(0...1 범위, 텍스처 좌상단 기준)
        var cornerUVs: [SIMD2<Float>]
        /// length == textureSize * textureSize, row-major(index = py*textureSize+px) — 그
        /// 텍셀이 속한 face 인덱스. 홀 채우기 단계에서 "이 face가 아틀라스의 어느 텍셀들을
        /// 갖고 있나"를 CPU에서 되짚어 채워 넣을 때 쓴다.
        var tileToFace: [Int32]

        /// face의 세 코너 UV 중심(centroid)을 텍스처 픽셀 좌표로 변환 — 홀 채우기 단계에서
        /// 베이킹된 아틀라스 텍셀 하나를 그 face의 "대표 색"으로 샘플링할 때 쓴다.
        func centroidPixel(face: Int) -> SIMD2<Int> {
            let a = cornerUVs[face * 3], b = cornerUVs[face * 3 + 1], c = cornerUVs[face * 3 + 2]
            let center = (a + b + c) / 3
            let px = min(max(Int(center.x * Float(textureSize)), 0), textureSize - 1)
            let py = min(max(Int(center.y * Float(textureSize)), 0), textureSize - 1)
            return SIMD2(px, py)
        }
    }

    /// `maxTextureSize`(폰 메모리/발열 예산 — 기본 2048)를 넘지 않도록 square 크기를 먼저
    /// 정하고 거기서 실제 텍스처 크기를 역산한다(데스크톱은 1814카메라 기준 10128였음).
    ///
    /// 다만 square 크기엔 `minSquareSize`라는 바닥이 있다 — 코너마다 넣는 seam 방지용
    /// pixel inset이 최대 ±3(아래 `insets` 참고)인데, face가 많아서 square가 그보다
    /// 훨씬 작아지면(예: face 43만개짜리 mesh는 maxTextureSize=2048 기준 square=4까지
    /// 줄어듦) inset이 정사각형 크기의 대부분/전부를 차지해버려서 UV가 깨진다 —
    /// 코너들이 서로 겹치거나 옆 square로 밀려나면서 face 전체가 사실상 그려지지 않는
    /// 정도까지 갈 수 있다(실기기에서 큰 스캔만 텍스처가 전혀 안 써지는 문제로 재현됨).
    /// 그래서 face가 아주 많으면 `maxTextureSize`보다 실제 텍스처가 커질 수 있다 —
    /// 용량/발열보다 정확성이 우선.
    static func build(faceCount: Int, maxTextureSize: Int = 2048, minSquareSize: Int = 8) -> Atlas {
        guard faceCount > 0 else { return Atlas(textureSize: 1, cornerUVs: [], tileToFace: [0]) }

        let nSquares = faceCount / 2 + 1
        let nSquarePerAxis = Int(sqrt(Double(nSquares)) + 1.0)
        let squareSize = max(minSquareSize, maxTextureSize / nSquarePerAxis)
        let textureSize = squareSize * nSquarePerAxis

        var cornerUVs = [SIMD2<Float>](repeating: .zero, count: faceCount * 3)

        // 각 square의 6개 코너(아래 삼각형 3개 + 위 삼각형 3개)에 대한, square-local 정수
        // 오프셋(대각선 seam에서 텍셀이 새어나가지 않도록 넣는 몇 px짜리 inset)들.
        // Python 버전과 동일한 상수.
        let insets: [SIMD2<Float>] = [
            SIMD2(-2, 1), SIMD2(2, 1), SIMD2(-2, -3),
            SIMD2(1, -1), SIMD2(1, 3), SIMD2(-3, -1),
        ]

        for square in 0..<nSquares {
            let sx = Float(square / nSquarePerAxis)
            let sy = Float(square % nSquarePerAxis)
            // bottom 삼각형(square*2): (sx+1,sy), (sx,sy), (sx+1,sy+1)
            // top 삼각형(square*2+1):  (sx,sy+1), (sx,sy), (sx+1,sy+1)
            let baseCorners: [SIMD2<Float>] = [
                SIMD2(sx + 1, sy), SIMD2(sx, sy), SIMD2(sx + 1, sy + 1),
                SIMD2(sx, sy + 1), SIMD2(sx, sy), SIMD2(sx + 1, sy + 1),
            ]

            for slot in 0..<6 {
                let face = square * 2 + slot / 3
                guard face < faceCount else { continue }
                let corner = slot % 3
                let pixel = baseCorners[slot] * Float(squareSize) + insets[slot]
                cornerUVs[face * 3 + corner] = pixel / Float(textureSize)
            }
        }

        // 역방향 조회 테이블: 텍셀 (px,py) -> 그걸 소유한 face. square 안에서 대각선
        // localX < localY 인 쪽이 "top"(square*2+1), 아니면 "bottom"(square*2) — 위
        // 코너 배치(u_shift/v_shift)에서 그대로 유도된다. 위 코너 계산과 별개로 유도했지만
        // 같은 정점 배치를 근거로 하므로 항상 서로 맞아떨어진다.
        var tileToFace = [Int32](repeating: 0, count: textureSize * textureSize)
        for py in 0..<textureSize {
            let sy = py / squareSize
            let localY = py % squareSize
            for px in 0..<textureSize {
                let sx = px / squareSize
                let localX = px % squareSize
                let square = sx * nSquarePerAxis + sy
                let isTop = localX < localY
                let face = min(square * 2 + (isTop ? 1 : 0), faceCount - 1)
                tileToFace[py * textureSize + px] = Int32(face)
            }
        }

        return Atlas(textureSize: textureSize, cornerUVs: cornerUVs, tileToFace: tileToFace)
    }
}

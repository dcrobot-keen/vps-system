import Foundation
import simd

/// 스캔끼리 자동 맞춤 -- 2D ICP(Iterative Closest Point). scan-to-map-studio의
/// `studio/registration.py`(icp_2d / icp_2d_multistart -- 로봇 SLAM 지도를 iPhone
/// 스캔 지도에 정합할 때 쓰는 것)를 Swift로 옮긴 것이다. 여기선 두 스캔의 floorplan.png
/// 벽 픽셀(`FloorPlanPixels.wallPointsXZ`)을 점집합으로 넣어 스캔 하나를 이미 놓인
/// 스캔들에 맞춘다. 최근접점 탐색은 scipy cKDTree 대신 균일 격자 해시(`PointGrid`).
///
/// 원본과 같은 한계가 있다: 초기값에서 대략 ±30° 안쪽에서만 믿을 만하게 수렴하고,
/// 겹치는 벽이 적거나 방이 대칭이면 엉뚱한 곳에 붙는다. 그래서 정렬 화면에서 손으로
/// 대충 놓은 값을 초기값으로 받아(그 주변 몇 개 각도로 멀티스타트) 마무리만 맡는
/// "자동 미세 맞춤"으로 쓴다. 겹치는 벽이 적으면 `inlierFraction`이 낮게 나오므로
/// 호출부는 `minimumInlierFraction` 아래면 결과를 버리고 사용자에게 알린다.
enum ScanRegistration {
    struct Result {
        /// source 점(스캔 로컬 좌표)을 target 좌표계(기준 스캔)로 옮기는 변환.
        let alignment: ScanAlignment
        /// 마지막 반복에서 대응된 점들의 RMS 거리(m). 대응이 3개 미만이면 무한대.
        let rmse: Float
        /// source 점 중 대응 거리 안에 짝이 있었던 비율(0...1).
        let inlierFraction: Float
        let iterations: Int
    }

    /// 이보다 대응 비율이 낮으면 "겹치는 벽을 못 찾음"으로 본다.
    static let minimumInlierFraction: Float = 0.3

    /// 손으로 놓은 `initial` 주변에서 멀티스타트(yaw만 몇 도씩 틀어서) -> 거친 ICP(대응
    /// 0.5m) -> 정밀 ICP(대응 0.15m) 순으로 돌리고 가장 좋은 결과를 돌려준다. 대응
    /// 비율이 기준 이상인 후보 중 RMSE 최소, 그런 후보가 없으면 대응 비율 최대.
    static func align(
        source: [SIMD2<Float>],
        target: [SIMD2<Float>],
        initial: ScanAlignment,
        seedYawOffsetsDegrees: [Float] = [-12, -6, 0, 6, 12],
        maxSourcePoints: Int = 3000
    ) -> Result {
        let src = subsample(source.filter { $0.x.isFinite && $0.y.isFinite }, maxCount: maxSourcePoints)
        let tgt = target.filter { $0.x.isFinite && $0.y.isFinite }
        guard !src.isEmpty, !tgt.isEmpty else {
            return Result(alignment: initial, rmse: .infinity, inlierFraction: 0, iterations: 0)
        }
        let coarseGrid = PointGrid(points: tgt, cellSize: 0.5)
        let fineGrid = PointGrid(points: tgt, cellSize: 0.15)

        // 멀티스타트 회전 중심: 초기값으로 옮긴 source의 중심(스캔 원점이 아니라).
        var centroid = SIMD2<Float>.zero
        for p in src {
            let q = initial.applyXZ(x: p.x, z: p.y)
            centroid += SIMD2(q.x, q.z)
        }
        centroid /= Float(src.count)

        var best: Result?
        for degrees in seedYawOffsetsDegrees {
            let seed = initial.rotated(by: degrees * .pi / 180, aboutX: centroid.x, z: centroid.y)
            let coarse = refine(source: src, grid: coarseGrid, initial: seed, maxCorrespondenceDistance: 0.5, maxIterations: 30)
            let fine = refine(source: src, grid: fineGrid, initial: coarse.alignment, maxCorrespondenceDistance: 0.15, maxIterations: 30)
            let candidate = Result(
                alignment: fine.alignment, rmse: fine.rmse, inlierFraction: fine.inlierFraction,
                iterations: coarse.iterations + fine.iterations
            )
            if isBetter(candidate, than: best) { best = candidate }
        }
        return best ?? Result(alignment: initial, rmse: .infinity, inlierFraction: 0, iterations: 0)
    }

    /// 단일 시작 ICP(registration.py의 icp_2d에 해당하되 centroid 초기화 대신 `initial`에서 시작).
    static func refine(
        source: [SIMD2<Float>],
        target: [SIMD2<Float>],
        initial: ScanAlignment,
        maxCorrespondenceDistance: Float = 0.5,
        maxIterations: Int = 50,
        tolerance: Float = 1e-5
    ) -> Result {
        refine(
            source: source, grid: PointGrid(points: target, cellSize: maxCorrespondenceDistance),
            initial: initial, maxCorrespondenceDistance: maxCorrespondenceDistance,
            maxIterations: maxIterations, tolerance: tolerance
        )
    }

    static func isBetter(_ a: Result, than b: Result?) -> Bool {
        guard let b else { return true }
        let aReliable = a.inlierFraction >= minimumInlierFraction
        let bReliable = b.inlierFraction >= minimumInlierFraction
        if aReliable != bReliable { return aReliable }
        if aReliable { return a.rmse < b.rmse }
        return a.inlierFraction > b.inlierFraction
    }

    // MARK: - 내부

    private static func refine(
        source: [SIMD2<Float>], grid: PointGrid, initial: ScanAlignment,
        maxCorrespondenceDistance: Float, maxIterations: Int, tolerance: Float = 1e-5
    ) -> Result {
        var (rotation, translation) = matrixForm(initial)
        var previousRmse = Float.infinity
        var rmse = Float.infinity
        var inliers = 0
        var iterations = 0
        var pairsSource: [SIMD2<Float>] = []
        var pairsTarget: [SIMD2<Float>] = []
        pairsSource.reserveCapacity(source.count)
        pairsTarget.reserveCapacity(source.count)

        for _ in 0..<maxIterations {
            pairsSource.removeAll(keepingCapacity: true)
            pairsTarget.removeAll(keepingCapacity: true)
            for p in source {
                let current = rotation * p + translation
                if let match = grid.nearest(to: current, within: maxCorrespondenceDistance) {
                    pairsSource.append(current)
                    pairsTarget.append(match)
                }
            }
            inliers = pairsSource.count
            iterations += 1
            guard inliers >= 3 else {
                rmse = .infinity
                break
            }

            let (stepRotation, stepTranslation) = bestFit(pairsSource, pairsTarget)
            rotation = stepRotation * rotation
            translation = stepRotation * translation + stepTranslation

            var sum: Float = 0
            for k in 0..<inliers {
                sum += simd_length_squared(stepRotation * pairsSource[k] + stepTranslation - pairsTarget[k])
            }
            rmse = (sum / Float(inliers)).squareRoot()
            if abs(previousRmse - rmse) < tolerance { break }
            previousRmse = rmse
        }

        return Result(
            alignment: alignmentForm(rotation, translation),
            rmse: rmse,
            inlierFraction: Float(inliers) / Float(max(source.count, 1)),
            iterations: iterations
        )
    }

    /// 대응 쌍 `p[i] -> q[i]`를 최소제곱으로 맞추는 강체 변환(2D Kabsch). 2D라 SVD 없이
    /// 회전각을 닫힌 식으로 구한다: θ = atan2(Σ p×q, Σ p·q) (중심 뺀 뒤).
    private static func bestFit(_ p: [SIMD2<Float>], _ q: [SIMD2<Float>]) -> (simd_float2x2, SIMD2<Float>) {
        let n = Float(p.count)
        var pCentroid = SIMD2<Float>.zero
        var qCentroid = SIMD2<Float>.zero
        for i in p.indices {
            pCentroid += p[i]
            qCentroid += q[i]
        }
        pCentroid /= n
        qCentroid /= n

        var dot: Float = 0
        var cross: Float = 0
        for i in p.indices {
            let a = p[i] - pCentroid
            let b = q[i] - qCentroid
            dot += a.x * b.x + a.y * b.y
            cross += a.x * b.y - a.y * b.x
        }
        let theta = atan2(cross, dot)
        let c = cos(theta), s = sin(theta)
        let rotation = simd_float2x2(columns: (SIMD2(c, s), SIMD2(-s, c)))
        return (rotation, qCentroid - rotation * pCentroid)
    }

    /// `ScanAlignment.applyXZ`(x' = x c + z s + ox, z' = -x s + z c + oz)를 행렬 R, t로.
    private static func matrixForm(_ a: ScanAlignment) -> (simd_float2x2, SIMD2<Float>) {
        let c = cos(a.yawRadians), s = sin(a.yawRadians)
        return (simd_float2x2(columns: (SIMD2(c, -s), SIMD2(s, c))), SIMD2(a.offsetX, a.offsetZ))
    }

    private static func alignmentForm(_ r: simd_float2x2, _ t: SIMD2<Float>) -> ScanAlignment {
        // matrixForm의 역: 첫 열이 (c, -s), 둘째 열이 (s, c).
        ScanAlignment(offsetX: t.x, offsetZ: t.y, yawRadians: atan2(r.columns.1.x, r.columns.0.x))
    }

    private static func subsample(_ points: [SIMD2<Float>], maxCount: Int) -> [SIMD2<Float>] {
        guard points.count > maxCount, maxCount > 0 else { return points }
        let step = Int((Double(points.count) / Double(maxCount)).rounded(.up))
        return points.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil }
    }

    /// 균일 격자 해시로 "반경 안 최근접점"을 찾는다. 셀 크기 = 탐색 반경이면 3x3 셀만
    /// 보면 된다. 점 수만 개 규모에서 ICP 반복마다 다시 쓰기에 충분히 빠르다.
    struct PointGrid {
        let points: [SIMD2<Float>]
        let cellSize: Float
        private var buckets: [Int64: [Int32]] = [:]

        init(points: [SIMD2<Float>], cellSize: Float) {
            self.points = points
            self.cellSize = max(cellSize, 1e-3)
            for (i, p) in points.enumerated() where p.x.isFinite && p.y.isFinite {
                buckets[key(cellX(p.x), cellZ(p.y)), default: []].append(Int32(i))
            }
        }

        func nearest(to p: SIMD2<Float>, within maxDistance: Float) -> SIMD2<Float>? {
            guard p.x.isFinite, p.y.isFinite else { return nil }
            let reach = Int32(max(1, (maxDistance / cellSize).rounded(.up)))
            let ix = cellX(p.x), iz = cellZ(p.y)
            var bestDistanceSquared = maxDistance * maxDistance
            var best: SIMD2<Float>?
            for dx in -reach...reach {
                for dz in -reach...reach {
                    guard let bucket = buckets[key(ix + dx, iz + dz)] else { continue }
                    for index in bucket {
                        let candidate = points[Int(index)]
                        let d2 = simd_length_squared(candidate - p)
                        if d2 < bestDistanceSquared {
                            bestDistanceSquared = d2
                            best = candidate
                        }
                    }
                }
            }
            return best
        }

        private func cellX(_ x: Float) -> Int32 { Int32(clamping: Int((x / cellSize).rounded(.down))) }
        private func cellZ(_ z: Float) -> Int32 { Int32(clamping: Int((z / cellSize).rounded(.down))) }
        private func key(_ ix: Int32, _ iz: Int32) -> Int64 {
            (Int64(ix) << 32) | Int64(UInt32(bitPattern: iz))
        }
    }
}

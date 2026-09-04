import Foundation
import simd

/// 프로젝트(ScanGroup) 안 스캔들의 `scan.usdz`를 하나의 mesh로 합친다. 그룹의 스캔들은
/// "이어서 스캔"(ScanSessionManager.startSession의 continuingFromWorldMapURL)으로
/// 찍혀서 이미 같은 world 좌표계를 공유하므로, 정합(registration) 계산 없이 각
/// scan.usdz의 vertex/index 버퍼를 그대로 이어붙이기만 하면 된다 -- 이어붙인 뒤
/// `MeshUnifier.weld`로 스캔 경계에서 위상적으로 안 이어진 근접 중복 정점만
/// 정리한다(TextureBaker가 anchor 경계에 쓰는 것과 같은 처리).
enum ScanGroupMerger {
    struct MergedMesh {
        let positions: [SIMD3<Float>]
        let normals: [SIMD3<Float>]
        let indices: [UInt32] // 항상 삼각형 리스트

        /// `GLBWriter`는 인덱스 버퍼를 지원하지 않는다(TextureBaker의 다이아몬드
        /// 아틀라스가 face-corner마다 독립된 UV 정사각형을 쓰는 탓에 애초에 정점
        /// 공유가 불가능하게 설계됨) -- GLB로 내보낼 때만 face-corner마다 정점을
        /// 새로 풀어서 평탄한 배열로 만든다(정점 수가 늘지만, 이 앱의 기존 GLB
        /// export 경로와 같은 트레이드오프).
        func unindexedForGLB() -> (positions: [Float], normals: [Float], vertexCount: Int) {
            var flatPositions: [Float] = []
            var flatNormals: [Float] = []
            flatPositions.reserveCapacity(indices.count * 3)
            flatNormals.reserveCapacity(indices.count * 3)
            for index in indices {
                let i = Int(index)
                guard i < positions.count else { continue }
                let p = positions[i]
                let n = i < normals.count ? normals[i] : SIMD3<Float>(0, 1, 0)
                flatPositions.append(contentsOf: [p.x, p.y, p.z])
                flatNormals.append(contentsOf: [n.x, n.y, n.z])
            }
            return (flatPositions, flatNormals, flatPositions.count / 3)
        }
    }

    enum MergeError: LocalizedError {
        case noScansWithMesh

        var errorDescription: String? {
            switch self {
            case .noScansWithMesh:
                return "이 프로젝트엔 mesh가 있는 스캔이 없습니다 (너무 짧게 찍었거나 이 기기가 3D mesh를 지원하지 않는 경우일 수 있어요)"
            }
        }
    }

    /// `scanFolderURLs`: 그룹의 각 scan_<name>/ 폴더 경로(캡처 순서 무관 -- 위치는
    /// 이미 world 좌표계에 저장돼 있어서 합치는 순서가 결과에 영향 없음). scan.usdz가
    /// 없는 스캔(너무 짧게 찍었거나 sceneReconstruction 미지원 기기)은 조용히
    /// 건너뛴다 -- 하나라도 있으면 합쳐서 반환한다.
    static func mergeMesh(scanFolderURLs: [URL], weldEpsilon: Float = 0.003) throws -> MergedMesh {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for scanURL in scanFolderURLs {
            let usdzURL = scanURL.appendingPathComponent("scan.usdz")
            guard let raw = try? MeshUnifier.load(usdzURL: usdzURL) else { continue }
            let vertexOffset = UInt32(positions.count)
            positions.append(contentsOf: raw.positions)
            indices.append(contentsOf: raw.indices.map { $0 + vertexOffset })
        }
        guard !positions.isEmpty, !indices.isEmpty else { throw MergeError.noScansWithMesh }

        let welded = MeshUnifier.weld(
            MeshUnifier.UnifiedMesh(positions: positions, indices: indices), epsilon: weldEpsilon
        )
        let normals = MeshGeometryBuilder.computeFaceNormals(positions: welded.positions, indices: welded.indices)
        return MergedMesh(positions: welded.positions, normals: normals, indices: welded.indices)
    }
}

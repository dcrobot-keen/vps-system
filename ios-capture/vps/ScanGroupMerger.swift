import Foundation
import simd

/// 프로젝트(ScanGroup) 안 스캔들의 `scan.usdz`를 하나의 mesh로 합친다. 스캔들은 각자
/// 따로 찍혀서(세션마다 다른 ARKit 원점) 좌표계가 다르므로, 사용자가 정렬 화면
/// (ScanAlignmentView)에서 맞춘 평면 변환(`ScanAlignment`)을 스캔마다 적용하고 수직은
/// 바닥 높이로 자동으로 맞춘 뒤 vertex/index 버퍼를 이어붙인다 -- 이어붙인 뒤
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

    struct ScanInput {
        let folderURL: URL
        /// 이 스캔을 기준 스캔(첫 번째) 좌표계로 옮기는 평면 변환. 첫 스캔은 identity.
        let alignment: ScanAlignment
    }

    /// 정렬 변환 없이(전부 identity) 합친다 -- 테스트/단순 호출용.
    static func mergeMesh(scanFolderURLs: [URL], weldEpsilon: Float = 0.003) throws -> MergedMesh {
        try mergeMesh(scans: scanFolderURLs.map { ScanInput(folderURL: $0, alignment: .identity) }, weldEpsilon: weldEpsilon)
    }

    /// `scans`: 그룹의 각 scan_<name>/ 폴더 + 사용자가 정렬 화면에서 맞춘 변환. 첫
    /// 스캔이 기준이고, 각 스캔의 수직(Y) 오프셋은 여기서 자동으로 채운다 -- 두 스캔
    /// 다 floorplan.json에 바닥 높이가 있으면 그 차이만큼 올리거나 내려서 바닥면을
    /// 맞춘다(ARKit 원점은 세션 시작 위치라 세션마다 높이가 제각각이지만, 바닥은 같은
    /// 바닥이니까). scan.usdz가 없는 스캔(너무 짧게 찍었거나 sceneReconstruction
    /// 미지원 기기)은 조용히 건너뛴다 -- 하나라도 있으면 합쳐서 반환한다.
    static func mergeMesh(scans: [ScanInput], weldEpsilon: Float = 0.003) throws -> MergedMesh {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        let referenceFloorY = scans.first.flatMap {
            FloorPlanRenderer.PersistedMeta.load(from: $0.folderURL)?.floorHeightMin
        }

        for scan in scans {
            let usdzURL = scan.folderURL.appendingPathComponent("scan.usdz")
            guard let raw = try? MeshUnifier.load(usdzURL: usdzURL) else { continue }

            var yOffset: Float = 0
            if let referenceFloorY,
               let ownFloorY = FloorPlanRenderer.PersistedMeta.load(from: scan.folderURL)?.floorHeightMin {
                yOffset = referenceFloorY - ownFloorY
            }

            let vertexOffset = UInt32(positions.count)
            positions.append(contentsOf: raw.positions.map { p in
                var q = scan.alignment.apply(p)
                q.y += yOffset
                return q
            })
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

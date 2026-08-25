import Foundation
import SceneKit
import simd

/// `scan.usdz`(SceneKit이 world-space로 구운, 색 없는 mesh)를 다시 불러와서 하나의
/// 통합 vertex/index 버퍼로 합치고, ARMeshAnchor 노드 경계에서 위상적으로 안 이어진
/// 근접 중복 정점을 용접한다. `TextureBaker`의 입력 지오메트리를 만드는 단계 —
/// `project_photos_onto_lidar_mesh.py`의 `extract_usdz_mesh` + `weld_vertices`를
/// Swift/CPU로 포팅한 것.
enum MeshUnifier {
    struct UnifiedMesh {
        var positions: [SIMD3<Float>]
        var indices: [UInt32] // 항상 삼각형 리스트, 3개씩 한 face
    }

    enum LoadError: Error {
        case sceneLoadFailed
        case noGeometry
    }

    /// `MeshExporter.export`가 각 ARMeshAnchor를 이미 world-space로 구워서 identity
    /// 변환의 SCNNode로 저장했으므로, 이 함수는 그걸 그대로 신뢰하지 않고 방어적으로
    /// `node.simdWorldTransform`을 다시 적용한다(usdz 왕복 과정에서 SceneKit이 변환을
    /// 바꿔 넣을 가능성을 배제하기 위해 — 비용은 identity 변환이면 사실상 0).
    static func load(usdzURL: URL) throws -> UnifiedMesh {
        guard let scene = try? SCNScene(url: usdzURL, options: nil) else {
            throw LoadError.sceneLoadFailed
        }

        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry,
                  let localPositions = readVec3Source(geometry, semantic: .vertex),
                  let localIndices = readTriangleIndices(geometry)
            else { return }

            let worldTransform = node.simdWorldTransform
            let vertexOffset = UInt32(positions.count)
            positions.reserveCapacity(positions.count + localPositions.count)
            for p in localPositions {
                let world = worldTransform * SIMD4<Float>(p, 1.0)
                positions.append(SIMD3<Float>(world.x, world.y, world.z))
            }
            indices.reserveCapacity(indices.count + localIndices.count)
            for idx in localIndices {
                indices.append(idx + vertexOffset)
            }
        }

        guard !positions.isEmpty, !indices.isEmpty else { throw LoadError.noGeometry }
        return UnifiedMesh(positions: positions, indices: indices)
    }

    // MARK: - SCNGeometrySource 읽기
    //
    // ARKit 원본(ARGeometrySource)은 tightly-packed float3이지만, usdz 왕복 과정에서
    // SceneKit이 stride/offset을 바꿔 넣을 수 있으므로 항상 dataStride/dataOffset을
    // 따라 읽는다 — MeshExporter가 원본을 읽을 때와 같은 원칙(`vertexSource.stride`를
    // 가정하지 않고 매번 따라감).

    private static func readVec3Source(_ geometry: SCNGeometry, semantic: SCNGeometrySource.Semantic) -> [SIMD3<Float>]? {
        guard let source = geometry.sources(for: semantic).first,
              source.componentsPerVector == 3, source.usesFloatComponents
        else { return nil }
        let data = source.data
        var result = [SIMD3<Float>](repeating: .zero, count: source.vectorCount)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<source.vectorCount {
                let base = source.dataOffset + source.dataStride * i
                let x = raw.loadUnaligned(fromByteOffset: base, as: Float.self)
                let y = raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self)
                let z = raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self)
                result[i] = SIMD3<Float>(x, y, z)
            }
        }
        return result
    }

    private static func readTriangleIndices(_ geometry: SCNGeometry) -> [UInt32]? {
        guard let element = geometry.elements.first, element.primitiveType == .triangles else { return nil }
        let indexCount = element.primitiveCount * 3
        guard indexCount > 0 else { return nil }
        let data = element.data
        var result = [UInt32](repeating: 0, count: indexCount)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<indexCount {
                let offset = element.bytesPerIndex * i
                switch element.bytesPerIndex {
                case 2: result[i] = UInt32(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                case 4: result[i] = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                default: break
                }
            }
        }
        return result
    }

    // MARK: - 정점 용접 (uniform spatial hash + union-find)
    //
    // scipy의 cKDTree.query_pairs를 쓴 Python 버전과 달리 이 스택엔 KD-tree 라이브러리가
    // 없으므로, epsilon 크기의 균일 그리드로 버킷팅해서 같은/인접 셀끼리만 비교한다.
    // 27-이웃(3x3x3)을 모든 채워진 셀에서 검사하므로 각 쌍을 최대 두 번(양방향) 보지만,
    // 정확성에는 문제없고 스캔당 한 번만 도는 연산이라 감내할 수 있는 비용이다.

    static func weld(_ mesh: UnifiedMesh, epsilon: Float) -> UnifiedMesh {
        let positions = mesh.positions
        var parent = Array(0..<positions.count)

        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root] }
            var cur = x
            while parent[cur] != root {
                let next = parent[cur]
                parent[cur] = root
                cur = next
            }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        var grid: [SIMD3<Int32>: [Int]] = [:]
        grid.reserveCapacity(positions.count)
        func cell(of p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32(floor(p.x / epsilon)), Int32(floor(p.y / epsilon)), Int32(floor(p.z / epsilon)))
        }
        for (i, p) in positions.enumerated() {
            grid[cell(of: p), default: []].append(i)
        }

        let epsilonSq = epsilon * epsilon
        for (cellCoord, indicesInCell) in grid {
            for dz in Int32(-1)...1 {
                for dy in Int32(-1)...1 {
                    for dx in Int32(-1)...1 {
                        let neighborCell = cellCoord &+ SIMD3<Int32>(dx, dy, dz)
                        guard let neighborIndices = grid[neighborCell] else { continue }
                        for i in indicesInCell {
                            for j in neighborIndices where j > i {
                                if simd_length_squared(positions[i] - positions[j]) <= epsilonSq {
                                    union(i, j)
                                }
                            }
                        }
                    }
                }
            }
        }

        var rootToNewIndex: [Int: Int] = [:]
        var newPositionSums: [SIMD3<Float>] = []
        var newPositionCounts: [Int] = []
        var remap = [Int](repeating: 0, count: positions.count)

        for i in 0..<positions.count {
            let root = find(i)
            if let newIndex = rootToNewIndex[root] {
                remap[i] = newIndex
                newPositionSums[newIndex] += positions[i]
                newPositionCounts[newIndex] += 1
            } else {
                let newIndex = newPositionSums.count
                rootToNewIndex[root] = newIndex
                remap[i] = newIndex
                newPositionSums.append(positions[i])
                newPositionCounts.append(1)
            }
        }
        var newPositions = [SIMD3<Float>](repeating: .zero, count: newPositionSums.count)
        for i in 0..<newPositions.count {
            newPositions[i] = newPositionSums[i] / Float(newPositionCounts[i])
        }

        var newIndices: [UInt32] = []
        newIndices.reserveCapacity(mesh.indices.count)
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = remap[Int(mesh.indices[i])]
            let b = remap[Int(mesh.indices[i + 1])]
            let c = remap[Int(mesh.indices[i + 2])]
            if a != b, b != c, a != c {
                newIndices.append(UInt32(a))
                newIndices.append(UInt32(b))
                newIndices.append(UInt32(c))
            }
            i += 3
        }

        return UnifiedMesh(positions: newPositions, indices: newIndices)
    }

    /// face 0..<faceCount 각각에 대해 이웃 face 목록(edge를 공유하는 face들)을 반환한다.
    /// 홀 채우기(BFS) 단계에서 쓴다.
    static func buildFaceAdjacency(indices: [UInt32]) -> [[Int32]] {
        let faceCount = indices.count / 3
        var edgeToFaces: [UInt64: [Int32]] = [:]
        edgeToFaces.reserveCapacity(faceCount * 3)

        func edgeKey(_ a: UInt32, _ b: UInt32) -> UInt64 {
            (UInt64(max(a, b)) << 32) | UInt64(min(a, b))
        }

        for f in 0..<faceCount {
            let a = indices[f * 3], b = indices[f * 3 + 1], c = indices[f * 3 + 2]
            for edge in [(a, b), (b, c), (c, a)] {
                edgeToFaces[edgeKey(edge.0, edge.1), default: []].append(Int32(f))
            }
        }

        var adjacency = [[Int32]](repeating: [], count: faceCount)
        for faces in edgeToFaces.values where faces.count > 1 {
            for i in faces {
                for j in faces where j != i {
                    adjacency[Int(i)].append(j)
                }
            }
        }
        return adjacency
    }

    /// face 각각의 flat normal(cross product) — welding 후 지오메트리에서 다시 계산한다.
    /// (ARKit이 준 per-vertex normal은 anchor 경계에서 신뢰하기 어렵고, Python 레퍼런스도
    /// pytorch3d가 welded mesh에서 다시 계산한 face normal을 썼다.)
    static func computeFaceNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        let faceCount = indices.count / 3
        var normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 1, 0), count: faceCount)
        for f in 0..<faceCount {
            let a = positions[Int(indices[f * 3])]
            let b = positions[Int(indices[f * 3 + 1])]
            let c = positions[Int(indices[f * 3 + 2])]
            let n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            normals[f] = len > 1e-9 ? n / len : SIMD3<Float>(0, 1, 0)
        }
        return normals
    }
}

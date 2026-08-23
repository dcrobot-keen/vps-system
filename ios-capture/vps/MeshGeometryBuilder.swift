import SceneKit
import simd

/// PLY/PCD/GLB 로더가 공통으로 쓰는 SCNGeometry 조립기. position은 필수, normal/color는
/// 없으면 생략한다(normal이 없는데 삼각형이 있으면 face normal을 계산해서 채운다 —
/// 안 그러면 SceneKit이 기본 조명 아래서 이상하게 밋밋/얼룩덜룩하게 그린다). 삼각형
/// 인덱스가 비어있으면 point cloud로 취급해서 `.point` primitive로 그린다.
enum MeshGeometryBuilder {
    static func build(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>]?,
        colors: [SIMD3<UInt8>]?,
        triangleIndices: [UInt32]
    ) -> SCNGeometry {
        let vertexData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertexStride = MemoryLayout<SIMD3<Float>>.stride
        var sources = [
            SCNGeometrySource(
                data: vertexData, semantic: .vertex, vectorCount: positions.count,
                usesFloatComponents: true, componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: vertexStride
            ),
        ]

        let resolvedNormals = normals ?? (
            triangleIndices.isEmpty ? nil : computeFaceNormals(positions: positions, indices: triangleIndices)
        )
        if let resolvedNormals, resolvedNormals.count == positions.count {
            let normalData = resolvedNormals.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(
                data: normalData, semantic: .normal, vectorCount: resolvedNormals.count,
                usesFloatComponents: true, componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: vertexStride
            ))
        }

        if let colors, colors.count == positions.count {
            let floatColors = colors.map {
                SIMD4<Float>(Float($0.x) / 255, Float($0.y) / 255, Float($0.z) / 255, 1.0)
            }
            let colorData = floatColors.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(
                data: colorData, semantic: .color, vectorCount: colors.count,
                usesFloatComponents: true, componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                dataStride: MemoryLayout<SIMD4<Float>>.stride
            ))
        }

        let element: SCNGeometryElement
        if triangleIndices.isEmpty {
            // point cloud -- 인덱스 없이 정점 순서 그대로 하나씩 점으로 찍는다.
            var pointIndices = [UInt32](repeating: 0, count: positions.count)
            for i in 0..<positions.count { pointIndices[i] = UInt32(i) }
            let indexData = pointIndices.withUnsafeBufferPointer { Data(buffer: $0) }
            element = SCNGeometryElement(
                data: indexData, primitiveType: .point,
                primitiveCount: positions.count, bytesPerIndex: MemoryLayout<UInt32>.size
            )
            element.pointSize = 3
            element.minimumPointScreenSpaceRadius = 1.5
            element.maximumPointScreenSpaceRadius = 4
        } else {
            let indexData = triangleIndices.withUnsafeBufferPointer { Data(buffer: $0) }
            element = SCNGeometryElement(
                data: indexData, primitiveType: .triangles,
                primitiveCount: triangleIndices.count / 3, bytesPerIndex: MemoryLayout<UInt32>.size
            )
        }

        return SCNGeometry(sources: sources, elements: [element])
    }

    /// N각형(주로 삼각형/사각형) face를 삼각형들로 팬 분할한다: [v0,v1,v2,v3] ->
    /// [v0,v1,v2, v0,v2,v3]. PLY의 "property list ... vertex_indices"가 삼각형이
    /// 아닐 수 있어서 필요하다.
    static func fanTriangulate(_ face: [UInt32]) -> [UInt32] {
        guard face.count >= 3 else { return [] }
        var result: [UInt32] = []
        for i in 1..<(face.count - 1) {
            result.append(contentsOf: [face[0], face[i], face[i + 1]])
        }
        return result
    }

    /// 삼각형 인덱스로부터 정점당 face normal을 계산한다. PLY/GLB 둘 다 normal이
    /// 없는 파일을 만날 수 있어서 `build()` 밖에서도(GLBLoader) 재사용한다.
    static func computeFaceNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var i = 0
        while i + 2 < indices.count {
            let i0 = Int(indices[i]), i1 = Int(indices[i + 1]), i2 = Int(indices[i + 2])
            defer { i += 3 }
            guard i0 < positions.count, i1 < positions.count, i2 < positions.count else { continue }
            let faceNormal = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            normals[i0] += faceNormal
            normals[i1] += faceNormal
            normals[i2] += faceNormal
        }
        for i in 0..<normals.count {
            normals[i] = simd_length(normals[i]) > 1e-9 ? simd_normalize(normals[i]) : SIMD3<Float>(0, 1, 0)
        }
        return normals
    }
}

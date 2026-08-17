import ARKit
import SceneKit
import simd

/// ARKit이 스캔 중 실시간으로 만든 LiDAR mesh(ARMeshAnchor)들을 모아서
/// scan-to-map-studio(https://github.com/dcrobot-keen/scan-to-map-studio)의
/// `--usdz` 입력으로 바로 쓸 수 있는 .usdz 파일로 내보낸다.
///
/// rgb/depth/poses와 같은 ARSession에서 나온 mesh라 world 좌표계가 hloc VPS DB와
/// 완전히 동일하다 — 두 스캔을 따로 찍어 ICP로 정합할 필요가 없다. 또한 ARKit의
/// 실시간 mesh fusion은 스로틀링된 depth 프레임을 단순 backproject하는 것보다
/// 구멍이 덜 뚫린(더 매끈한) 메시를 만들어준다.
///
/// ModelIO(MDLAsset/MDLMesh)를 거치는 경로는 실기기에서 계속 실패했다:
/// - `MDLAsset.export(to:)`는 iOS에서 .usdz 확장자를 인식 못 함("Unknown extension on URL")
/// - `SCNScene(mdlAsset:)`, `SCNNode(mdlObject:)`, `SCNGeometry(mdlMesh:)` 전부
///   컴파일 에러("Argument passed to call that takes no arguments") — 이 SDK엔 없는 API
/// 그래서 ModelIO는 아예 쓰지 않고, SceneKit 고유 API(SCNGeometrySource/
/// SCNGeometryElement — SceneKit 초기부터 있던 커스텀 geometry 생성 방식)로 직접
/// SCNGeometry를 만든 뒤 SCNScene.write(to:)로 저장한다.
enum MeshExporter {
    enum ExportError: Error {
        case noValidMeshes
        case writeFailed
    }

    /// meshAnchors를 하나의 .usdz로 합쳐서 저장한다.
    static func export(meshAnchors: [ARMeshAnchor], to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        let scene = SCNScene()
        var addedAny = false
        for anchor in meshAnchors {
            guard let geometry = scnGeometry(for: anchor) else { continue }
            scene.rootNode.addChildNode(SCNNode(geometry: geometry))
            addedAny = true
        }
        guard addedAny else { throw ExportError.noValidMeshes }

        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
            throw ExportError.writeFailed
        }
    }

    /// ARMeshAnchor 하나를 world 좌표계로 변환한 SCNGeometry로 만든다.
    /// vertex/normal은 anchor.transform을 적용해 local -> world로 미리 구워 넣는다
    /// (여러 anchor를 각자 좌표계로 두지 않고, 좌표가 이미 맞춰진 단일 world
    /// 좌표계로 저장하기 위함).
    private static func scnGeometry(for anchor: ARMeshAnchor) -> SCNGeometry? {
        let geometry = anchor.geometry
        let vertexSource = geometry.vertices
        let normalSource = geometry.normals
        let faceElement = geometry.faces

        guard vertexSource.format == .float3, normalSource.format == .float3 else { return nil }
        guard faceElement.primitiveType == .triangle,
              faceElement.bytesPerIndex == MemoryLayout<UInt32>.size
        else { return nil }

        let vertexCount = vertexSource.count
        guard vertexCount > 0, normalSource.count == vertexCount else { return nil }

        // normal은 방향 벡터라 이동(translation) 없이 회전만 적용한다.
        let rotation = simd_float3x3(
            SIMD3(anchor.transform.columns.0.x, anchor.transform.columns.0.y, anchor.transform.columns.0.z),
            SIMD3(anchor.transform.columns.1.x, anchor.transform.columns.1.y, anchor.transform.columns.1.z),
            SIMD3(anchor.transform.columns.2.x, anchor.transform.columns.2.y, anchor.transform.columns.2.z)
        )

        var worldVertices = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        var worldNormals = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        let vertexBuffer = vertexSource.buffer.contents()
        let normalBuffer = normalSource.buffer.contents()
        for i in 0..<vertexCount {
            let vertexBase = vertexBuffer.advanced(by: vertexSource.offset + vertexSource.stride * i)
            let normalBase = normalBuffer.advanced(by: normalSource.offset + normalSource.stride * i)
            // Swift의 SIMD3<Float>는 메모리에서 16바이트(4-float 정렬)로 저장되지만
            // ARKit 버퍼는 12바이트(3-float) 촘촘 포장이라, 곧바로
            // assumingMemoryBound(to: SIMD3<Float>.self)로 읽으면 마지막 원소에서
            // 버퍼 밖을 4바이트 읽게 될 위험이 있다. float 3개를 개별로 읽는다.
            let vx = vertexBase.load(fromByteOffset: 0, as: Float.self)
            let vy = vertexBase.load(fromByteOffset: 4, as: Float.self)
            let vz = vertexBase.load(fromByteOffset: 8, as: Float.self)
            let world = anchor.transform * SIMD4<Float>(vx, vy, vz, 1.0)
            worldVertices[i] = SIMD3<Float>(world.x, world.y, world.z)

            let nx = normalBase.load(fromByteOffset: 0, as: Float.self)
            let ny = normalBase.load(fromByteOffset: 4, as: Float.self)
            let nz = normalBase.load(fromByteOffset: 8, as: Float.self)
            worldNormals[i] = simd_normalize(rotation * SIMD3<Float>(nx, ny, nz))
        }

        let triangleCount = faceElement.count
        let indexCount = triangleCount * 3
        guard indexCount > 0 else { return nil }

        var indices = [UInt32](repeating: 0, count: indexCount)
        let indexBuffer = faceElement.buffer.contents()
        for i in 0..<indexCount {
            let offset = faceElement.bytesPerIndex * i
            indices[i] = indexBuffer.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee
        }

        let vertexData = worldVertices.withUnsafeBufferPointer { Data(buffer: $0) }
        let normalData = worldNormals.withUnsafeBufferPointer { Data(buffer: $0) }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }

        let vertexGeoSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let normalGeoSource = SCNGeometrySource(
            data: normalData,
            semantic: .normal,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: triangleCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        return SCNGeometry(sources: [vertexGeoSource, normalGeoSource], elements: [element])
    }
}

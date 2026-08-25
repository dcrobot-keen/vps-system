import Foundation
import Metal
import MetalKit
import simd

/// 스캔 하나(`scan_<name>/`)의 `scan.usdz` + `rgb/` + `poses/poses.jsonl`을 입력으로
/// 받아, 원본 사진을 mesh에 직접 프로젝션해서 텍스처를 굽고 `textured.glb`로 내보낸다.
/// `dc-vps-digital-twin`의 `project_photos_onto_lidar_mesh.py`(SuGaR/PyTorch3D 기반
/// GPU-서버 버전)와 같은 알고리즘을 Metal로 포팅한 것 — PyTorch3D의 `MeshRasterizer`
/// 대신 표준 "UV 공간 베이킹" 트릭(정점을 카메라가 아니라 그 삼각형의 UV 아틀라스
/// 좌표에 그려서, 렌더 타겟 자체를 텍스처 아틀라스로 쓰는 기법)과 GPU additive
/// blending으로 같은 결과(soft power-weighted best-view 블렌딩)를 얻는다.
///
/// 이 앱엔 기존에 Metal 사용 이력이 전혀 없어서 여기서 처음 MTLDevice를 연다. 이 환경
/// (Windows, Xcode 없음)에서는 컴파일/실행 검증이 불가능했다 — 특히 카메라 투영
/// 행렬 유도와 CPU/GPU 버퍼 레이아웃 일치는 실기기에서 가장 먼저 확인해야 할
/// 부분이다(구조체 레이아웃을 scalar float만으로 짠 이유는 `TextureBakingShaders.metal`
/// 상단 주석 참고).
enum TextureBaker {
    struct Progress {
        var framesProcessed: Int
        var totalFrames: Int
    }

    enum BakeError: Error {
        case deviceUnavailable
        case shaderCompileFailed
        case noPoses
        case pipelineCreationFailed
        case textureExportFailed
    }

    struct Options {
        var maxTextureSize: Int = 2048
        var weldEpsilon: Float = 0.003 // meters, project_photos_onto_lidar_mesh.py 기본값과 동일
        var blendPower: Float = 12.0
        var depthPrepassMaxDimension: Int = 480
        var nearMeters: Float = 0.05
        var farMeters: Float = 20.0
        var occlusionBias: Float = 0.0015
    }

    // MARK: - poses.jsonl

    private struct PoseRecord: Decodable {
        struct Intrinsics: Decodable {
            let fx: Float, fy: Float, cx: Float, cy: Float
            let width: Int, height: Int
        }
        let rgb_path: String
        let camera_transform: [[Float]] // 4x4, row-major, camera-to-world (ARKit convention)
        let intrinsics: Intrinsics
        let tracking_state: String
    }

    private static func loadPoses(_ url: URL) throws -> [PoseRecord] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        var records: [PoseRecord] = []
        for line in text.split(separator: "\n") {
            guard !line.isEmpty,
                  let record = try? decoder.decode(PoseRecord.self, from: Data(line.utf8)),
                  record.tracking_state == "normal"
            else { continue }
            records.append(record)
        }
        return records
    }

    // MARK: - 카메라 행렬
    //
    // `camera_transform`은 ARKit의 OpenGL 스타일 컨벤션(Y-up, 카메라 로컬 -Z가 전방)인
    // camera-to-world다. `intrinsics`(fx,fy,cx,cy)는 표준 CV 픽셀 컨벤션(x-right,y-down,
    // z-forward)을 가정하므로, world -> pixel 변환 전에 GL_TO_CV = diag(1,-1,-1,1) 축
    // 반전을 거쳐야 한다 — dc-vps-digital-twin의 COLMAP 변환 스크립트에서 실측 검증된
    // 컨벤션과 동일(mesh vertex를 투영했을 때 카메라 로컬 z<0인 점만 이미지 범위 안에
    // 정확히 떨어짐, 98.77% 일치로 확인됨).

    private static let glToCv = simd_float4x4(
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, -1, 0, 0),
        SIMD4<Float>(0, 0, -1, 0),
        SIMD4<Float>(0, 0, 0, 1)
    )

    private static func cameraToWorldMatrix(_ rows: [[Float]]) -> simd_float4x4 {
        simd_float4x4(
            SIMD4(rows[0][0], rows[1][0], rows[2][0], rows[3][0]),
            SIMD4(rows[0][1], rows[1][1], rows[2][1], rows[3][1]),
            SIMD4(rows[0][2], rows[1][2], rows[2][2], rows[3][2]),
            SIMD4(rows[0][3], rows[1][3], rows[2][3], rows[3][3])
        )
    }

    private static func flatten(_ m: simd_float4x4) -> [Float] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w,
        ]
    }

    /// CameraUniforms(TextureBakingShaders.metal)와 필드 순서/타입을 정확히 맞춘 43-float
    /// 평탄 배열: viewMatrix(16) + depthProjection(16) + cameraWorldPos(3) + fx,fy,cx,cy(4)
    /// + imageWidth,imageHeight(2) + blendPower(1) + occlusionBias(1).
    private static func buildCameraUniforms(
        pose: PoseRecord, depthWidth: Int, depthHeight: Int, options: Options
    ) -> [Float] {
        let cameraToWorld = cameraToWorldMatrix(pose.camera_transform)
        let worldToCamera = cameraToWorld.inverse
        let viewMatrix = glToCv * worldToCamera

        // depth pre-pass 렌더 타겟은 다운샘플되어 있으므로, fx/fy/cx/cy를 같은 비율로
        // 스케일해서 종횡비가 그대로 유지되게 한다.
        let scale = Float(depthWidth) / Float(pose.intrinsics.width)
        let sFx = pose.intrinsics.fx * scale
        let sFy = pose.intrinsics.fy * scale
        let sCx = pose.intrinsics.cx * scale
        let sCy = pose.intrinsics.cy * scale
        let dW = Float(depthWidth)
        let dH = Float(depthHeight)

        let near = options.nearMeters
        let far = options.farMeters
        let a = -far / (far - near)
        let b = -far * near / (far - near)

        // Metal 클립 좌표(z: 0..1, y-flip 포함) 유도는 TextureBakingShaders.metal 상단
        // 주석 참고. column-major 평탄 배열: index = col*4+row.
        let depthProjection: [Float] = [
            2 * sFx / dW, 0, 0, 0,
            0, -2 * sFy / dH, 0, 0,
            (2 * sCx / dW - 1), -(2 * sCy / dH - 1), a, 1,
            0, 0, b, 0,
        ]

        let camWorldPos = cameraToWorld.columns.3

        var uniforms = flatten(viewMatrix)
        uniforms.append(contentsOf: depthProjection)
        uniforms.append(contentsOf: [camWorldPos.x, camWorldPos.y, camWorldPos.z])
        uniforms.append(contentsOf: [
            pose.intrinsics.fx, pose.intrinsics.fy, pose.intrinsics.cx, pose.intrinsics.cy,
        ])
        uniforms.append(contentsOf: [Float(pose.intrinsics.width), Float(pose.intrinsics.height)])
        uniforms.append(options.blendPower)
        uniforms.append(options.occlusionBias)
        return uniforms
    }

    // MARK: - 메인 진입점

    static func bake(projectURL: URL, outputURL: URL, options: Options = Options(), onProgress: ((Progress) -> Void)? = nil) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else { throw BakeError.deviceUnavailable }
        guard let library = try? device.makeDefaultLibrary(bundle: .main) else { throw BakeError.shaderCompileFailed }

        // 1. mesh 통합 + 용접 + face normal + adjacency (MeshUnifier.swift)
        let usdzURL = projectURL.appendingPathComponent("scan.usdz")
        let rawMesh = try MeshUnifier.load(usdzURL: usdzURL)
        let mesh = MeshUnifier.weld(rawMesh, epsilon: options.weldEpsilon)
        let faceCount = mesh.indices.count / 3
        let faceNormals = MeshUnifier.computeFaceNormals(positions: mesh.positions, indices: mesh.indices)
        let adjacency = MeshUnifier.buildFaceAdjacency(indices: mesh.indices)

        // 2. UV 아틀라스 (UVAtlasBuilder.swift)
        let atlas = UVAtlasBuilder.build(faceCount: faceCount, maxTextureSize: options.maxTextureSize)

        // 3. poses.jsonl
        let poses = try loadPoses(projectURL.appendingPathComponent("poses/poses.jsonl"))
        guard !poses.isEmpty else { throw BakeError.noPoses }

        // 4. 버퍼 준비 — packed_floatN과 바이트 단위로 맞춰야 하므로 SIMD3<Float>(Swift에서
        // stride 16) 대신 평탄 [Float](stride 12/8)로 직접 채운다.
        var depthPositionsFlat = [Float](); depthPositionsFlat.reserveCapacity(mesh.positions.count * 3)
        for p in mesh.positions { depthPositionsFlat.append(contentsOf: [p.x, p.y, p.z]) }

        var atlasPositionsFlat = [Float](); atlasPositionsFlat.reserveCapacity(faceCount * 9)
        var atlasNormalsFlat = [Float](); atlasNormalsFlat.reserveCapacity(faceCount * 9)
        var atlasUVsFlat = [Float](); atlasUVsFlat.reserveCapacity(faceCount * 6)
        for f in 0..<faceCount {
            let n = faceNormals[f]
            for corner in 0..<3 {
                let p = mesh.positions[Int(mesh.indices[f * 3 + corner])]
                atlasPositionsFlat.append(contentsOf: [p.x, p.y, p.z])
                atlasNormalsFlat.append(contentsOf: [n.x, n.y, n.z])
                let uv = atlas.cornerUVs[f * 3 + corner]
                atlasUVsFlat.append(contentsOf: [uv.x, uv.y])
            }
        }

        guard
            let depthPositionsBuffer = device.makeBuffer(bytes: depthPositionsFlat, length: depthPositionsFlat.count * 4),
            let weldedIndexBuffer = device.makeBuffer(bytes: mesh.indices, length: mesh.indices.count * 4),
            let atlasPositionsBuffer = device.makeBuffer(bytes: atlasPositionsFlat, length: atlasPositionsFlat.count * 4),
            let atlasNormalsBuffer = device.makeBuffer(bytes: atlasNormalsFlat, length: atlasNormalsFlat.count * 4),
            let atlasUVsBuffer = device.makeBuffer(bytes: atlasUVsFlat, length: atlasUVsFlat.count * 4)
        else { throw BakeError.deviceUnavailable }

        // 5. 파이프라인
        guard let depthVertexFn = library.makeFunction(name: "depthPrepassVertex"),
              let atlasVertexFn = library.makeFunction(name: "atlasBakeVertex"),
              let atlasFragmentFn = library.makeFunction(name: "atlasBakeFragment"),
              let fullscreenVertexFn = library.makeFunction(name: "fullscreenQuadVertex"),
              let normalizeFragmentFn = library.makeFunction(name: "normalizeAtlasFragment")
        else { throw BakeError.shaderCompileFailed }

        let depthPipelineDesc = MTLRenderPipelineDescriptor()
        depthPipelineDesc.vertexFunction = depthVertexFn
        depthPipelineDesc.depthAttachmentPixelFormat = .depth32Float

        let atlasPipelineDesc = MTLRenderPipelineDescriptor()
        atlasPipelineDesc.vertexFunction = atlasVertexFn
        atlasPipelineDesc.fragmentFunction = atlasFragmentFn
        atlasPipelineDesc.colorAttachments[0].pixelFormat = .rgba16Float
        atlasPipelineDesc.colorAttachments[0].isBlendingEnabled = true
        atlasPipelineDesc.colorAttachments[0].rgbBlendOperation = .add
        atlasPipelineDesc.colorAttachments[0].alphaBlendOperation = .add
        atlasPipelineDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        atlasPipelineDesc.colorAttachments[0].destinationRGBBlendFactor = .one
        atlasPipelineDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        atlasPipelineDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
        atlasPipelineDesc.colorAttachments[1].pixelFormat = .r32Float
        atlasPipelineDesc.colorAttachments[1].isBlendingEnabled = true
        atlasPipelineDesc.colorAttachments[1].rgbBlendOperation = .add
        atlasPipelineDesc.colorAttachments[1].sourceRGBBlendFactor = .one
        atlasPipelineDesc.colorAttachments[1].destinationRGBBlendFactor = .one

        let normalizePipelineDesc = MTLRenderPipelineDescriptor()
        normalizePipelineDesc.vertexFunction = fullscreenVertexFn
        normalizePipelineDesc.fragmentFunction = normalizeFragmentFn
        normalizePipelineDesc.colorAttachments[0].pixelFormat = .rgba8Unorm

        let depthStencilDesc = MTLDepthStencilDescriptor()
        depthStencilDesc.depthCompareFunction = .less
        depthStencilDesc.isDepthWriteEnabled = true

        guard let depthPipeline = try? device.makeRenderPipelineState(descriptor: depthPipelineDesc),
              let atlasPipeline = try? device.makeRenderPipelineState(descriptor: atlasPipelineDesc),
              let normalizePipeline = try? device.makeRenderPipelineState(descriptor: normalizePipelineDesc),
              let depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDesc)
        else { throw BakeError.pipelineCreationFailed }

        // 6. 텍스처들
        let textureSize = atlas.textureSize
        let accumColorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: textureSize, height: textureSize, mipmapped: false)
        accumColorDesc.usage = [.renderTarget, .shaderRead]
        accumColorDesc.storageMode = .private
        let accumWeightDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: textureSize, height: textureSize, mipmapped: false)
        accumWeightDesc.usage = [.renderTarget, .shaderRead]
        accumWeightDesc.storageMode = .private
        guard let accumColorTexture = device.makeTexture(descriptor: accumColorDesc),
              let accumWeightTexture = device.makeTexture(descriptor: accumWeightDesc)
        else { throw BakeError.deviceUnavailable }

        let firstIntrinsics = poses[0].intrinsics
        let depthScale = min(1.0, Float(options.depthPrepassMaxDimension) / Float(max(firstIntrinsics.width, firstIntrinsics.height)))
        let depthWidth = max(1, Int((Float(firstIntrinsics.width) * depthScale).rounded()))
        let depthHeight = max(1, Int((Float(firstIntrinsics.height) * depthScale).rounded()))
        let depthTexDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: depthWidth, height: depthHeight, mipmapped: false)
        depthTexDesc.usage = [.renderTarget, .shaderRead]
        depthTexDesc.storageMode = .private
        guard let depthTexture = device.makeTexture(descriptor: depthTexDesc) else { throw BakeError.deviceUnavailable }

        // accumColor/accumWeight를 한 번 명시적으로 0으로 초기화 — 매 프레임 loadAction을
        // .load로 고정할 수 있게(첫 프레임 로드 실패 등으로 클리어를 못 하는 경우를 방지).
        do {
            let clearPassDesc = MTLRenderPassDescriptor()
            clearPassDesc.colorAttachments[0].texture = accumColorTexture
            clearPassDesc.colorAttachments[0].loadAction = .clear
            clearPassDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            clearPassDesc.colorAttachments[0].storeAction = .store
            clearPassDesc.colorAttachments[1].texture = accumWeightTexture
            clearPassDesc.colorAttachments[1].loadAction = .clear
            clearPassDesc.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 0)
            clearPassDesc.colorAttachments[1].storeAction = .store
            guard let cb = commandQueue.makeCommandBuffer(),
                  let enc = cb.makeRenderCommandEncoder(descriptor: clearPassDesc)
            else { throw BakeError.deviceUnavailable }
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }

        // 7. 카메라별 2-패스 베이킹
        let textureLoader = MTKTextureLoader(device: device)
        let totalFrames = poses.count
        for (i, pose) in poses.enumerated() {
            autoreleasepool {
                let photoURL = projectURL.appendingPathComponent(pose.rgb_path)
                guard let photoTexture = try? textureLoader.newTexture(URL: photoURL, options: [.SRGB: false]) else {
                    onProgress?(Progress(framesProcessed: i + 1, totalFrames: totalFrames))
                    return
                }
                let uniformsFlat = buildCameraUniforms(pose: pose, depthWidth: depthWidth, depthHeight: depthHeight, options: options)
                guard let uniformsBuffer = device.makeBuffer(bytes: uniformsFlat, length: uniformsFlat.count * 4),
                      let commandBuffer = commandQueue.makeCommandBuffer()
                else { return }

                // Pass A: 이 카메라 실시점에서 depth-only 렌더 (occlusion 판정용)
                let depthPassDesc = MTLRenderPassDescriptor()
                depthPassDesc.depthAttachment.texture = depthTexture
                depthPassDesc.depthAttachment.loadAction = .clear
                depthPassDesc.depthAttachment.clearDepth = 1.0
                depthPassDesc.depthAttachment.storeAction = .store
                if let depthEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: depthPassDesc) {
                    depthEncoder.setRenderPipelineState(depthPipeline)
                    depthEncoder.setDepthStencilState(depthStencilState)
                    depthEncoder.setVertexBuffer(depthPositionsBuffer, offset: 0, index: 0)
                    depthEncoder.setVertexBuffer(uniformsBuffer, offset: 0, index: 1)
                    depthEncoder.drawIndexedPrimitives(
                        type: .triangle, indexCount: mesh.indices.count, indexType: .uint32,
                        indexBuffer: weldedIndexBuffer, indexBufferOffset: 0
                    )
                    depthEncoder.endEncoding()
                }

                // Pass B: UV 공간에 이 카메라의 기여를 additive blending으로 누적
                let atlasPassDesc = MTLRenderPassDescriptor()
                atlasPassDesc.colorAttachments[0].texture = accumColorTexture
                atlasPassDesc.colorAttachments[0].loadAction = .load
                atlasPassDesc.colorAttachments[0].storeAction = .store
                atlasPassDesc.colorAttachments[1].texture = accumWeightTexture
                atlasPassDesc.colorAttachments[1].loadAction = .load
                atlasPassDesc.colorAttachments[1].storeAction = .store
                if let atlasEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: atlasPassDesc) {
                    atlasEncoder.setRenderPipelineState(atlasPipeline)
                    atlasEncoder.setVertexBuffer(atlasPositionsBuffer, offset: 0, index: 0)
                    atlasEncoder.setVertexBuffer(atlasNormalsBuffer, offset: 0, index: 1)
                    atlasEncoder.setVertexBuffer(atlasUVsBuffer, offset: 0, index: 2)
                    atlasEncoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
                    atlasEncoder.setFragmentTexture(photoTexture, index: 0)
                    atlasEncoder.setFragmentTexture(depthTexture, index: 1)
                    atlasEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: faceCount * 3)
                    atlasEncoder.endEncoding()
                }

                // 단순함/정확성 우선: 프레임마다 완료를 기다린다(depthTexture를 매 프레임
                // 재사용하므로 겹쳐 실행하면 레이스가 난다). 처리량이 문제가 되면
                // depthTexture를 더블 버퍼링해서 여러 프레임을 동시에 흘려보낼 수 있다 —
                // 실기기에서 정확성부터 확인한 다음에 손볼 지점.
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                onProgress?(Progress(framesProcessed: i + 1, totalFrames: totalFrames))
            }
        }

        // 8. 정규화(accumColor/accumWeight -> 최종 텍스처)
        let finalTexDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: textureSize, height: textureSize, mipmapped: false)
        finalTexDesc.usage = [.renderTarget, .shaderRead]
        finalTexDesc.storageMode = .shared
        guard let finalTexture = device.makeTexture(descriptor: finalTexDesc) else { throw BakeError.deviceUnavailable }

        let normalizePassDesc = MTLRenderPassDescriptor()
        normalizePassDesc.colorAttachments[0].texture = finalTexture
        normalizePassDesc.colorAttachments[0].loadAction = .clear
        normalizePassDesc.colorAttachments[0].storeAction = .store
        guard let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: normalizePassDesc)
        else { throw BakeError.pipelineCreationFailed }
        enc.setRenderPipelineState(normalizePipeline)
        enc.setFragmentTexture(accumColorTexture, index: 0)
        enc.setFragmentTexture(accumWeightTexture, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        var pixelBuffer = [UInt8](repeating: 0, count: textureSize * textureSize * 4)
        let region = MTLRegionMake2D(0, 0, textureSize, textureSize)
        pixelBuffer.withUnsafeMutableBytes { ptr in
            finalTexture.getBytes(ptr.baseAddress!, bytesPerRow: textureSize * 4, from: region, mipmapLevel: 0)
        }

        // 9. 홀 채우기: face의 UV 중심 텍셀을 그 face의 대표색으로 보고(alpha>0이면
        // "보임"), face adjacency로 BFS 전파. 고립된 섬(용접 후에도 위상적으로 안 이어진
        // 조각)은 중간 회색으로 남는다 — project_photos_onto_lidar_mesh.py의
        // fill_holes_by_propagation과 동일한 전략.
        var faceColors = [SIMD3<Float>](repeating: .zero, count: faceCount)
        var seen = [Bool](repeating: false, count: faceCount)
        for f in 0..<faceCount {
            let p = atlas.centroidPixel(face: f)
            let idx = (p.y * textureSize + p.x) * 4
            if pixelBuffer[idx + 3] > 0 {
                seen[f] = true
                faceColors[f] = SIMD3(Float(pixelBuffer[idx]) / 255, Float(pixelBuffer[idx + 1]) / 255, Float(pixelBuffer[idx + 2]) / 255)
            }
        }
        var visited = seen
        var queue = (0..<faceCount).filter { seen[$0] }
        var qi = 0
        while qi < queue.count {
            let f = queue[qi]; qi += 1
            for neighbor32 in adjacency[f] {
                let neighbor = Int(neighbor32)
                if !visited[neighbor] {
                    visited[neighbor] = true
                    faceColors[neighbor] = faceColors[f]
                    queue.append(neighbor)
                }
            }
        }
        for f in 0..<faceCount where !visited[f] {
            faceColors[f] = SIMD3(0.65, 0.65, 0.65)
        }

        for py in 0..<textureSize {
            for px in 0..<textureSize {
                let tileIndex = py * textureSize + px
                let pixelIndex = tileIndex * 4
                guard pixelBuffer[pixelIndex + 3] == 0 else { continue }
                let color = faceColors[Int(atlas.tileToFace[tileIndex])]
                pixelBuffer[pixelIndex] = UInt8(clamping: Int(color.x * 255))
                pixelBuffer[pixelIndex + 1] = UInt8(clamping: Int(color.y * 255))
                pixelBuffer[pixelIndex + 2] = UInt8(clamping: Int(color.z * 255))
                pixelBuffer[pixelIndex + 3] = 255
            }
        }

        // 10. GLB export — atlas-bake 패스와 같은 face-corner-per-vertex 버퍼를 그대로 쓴다
        // (다이아몬드 아틀라스는 face마다 독립된 UV 정사각형을 쓰므로 정점을 공유할 수 없다).
        try GLBWriter.write(
            positions: atlasPositionsFlat, normals: atlasNormalsFlat, uvs: atlasUVsFlat,
            textureRGBA: pixelBuffer, textureWidth: textureSize, textureHeight: textureSize,
            to: outputURL
        )
    }
}

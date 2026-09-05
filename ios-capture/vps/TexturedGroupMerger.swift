import Foundation
import os
import simd

private let logger = Logger(subsystem: "com.dcrobot.keen.scanmesh", category: "TexturedGroupMerger")

/// 스캔별 `textured.glb`(TextureBaker 결과)를 정렬 변환 + 바닥 높이 오프셋 적용해 primitive
/// 여러 개짜리 GLB 하나로 합친다. 텍스처는 스캔별 아틀라스를 그대로 옮겨 담으므로 다시
/// 굽지 않고, 각 방의 텍스처 해상도도 그대로다. 아직 안 구운 스캔은 `bakeMissing`이면 먼저
/// 굽는다(시간/발열이 드는 작업이라 진행 상황을 콜백으로 알린다). scan.usdz가 없는 스캔은
/// 건너뛴다.
///
/// 합친 mesh를 통째로 다시 굽는 방식(모든 스캔의 사진을 한 아틀라스에)은 겹치지 않는
/// 방들에는 이점이 없고 아틀라스 상한(2048)을 나눠 써서 해상도만 떨어지므로 택하지 않았다
/// (PRODUCT-PLAN.md 2026-09-04). ScanGroupMerger(무채색 mesh)와 같은 정렬/높이 규칙을 써서
/// 두 결과가 같은 자리에 놓인다.
enum TexturedGroupMerger {
    enum MergeError: LocalizedError {
        case noTexturedScans

        var errorDescription: String? {
            switch self {
            case .noTexturedScans:
                return "텍스처를 입힐 스캔이 없습니다 (mesh가 있는 스캔이 없거나 텍스처 생성에 실패했습니다)"
            }
        }
    }

    enum Progress {
        /// `scanIndex`번째(0부터) 스캔의 텍스처를 굽는 중. `frames`는 TextureBaker 진행(준비 중이면 nil).
        case baking(scanIndex: Int, scanCount: Int, frames: TextureBaker.Progress?)
        case merging
    }

    struct Summary {
        let texturedScanCount: Int
        let skippedScanCount: Int
    }

    static func merge(
        scans: [ScanGroupMerger.ScanInput], to outputURL: URL, bakeMissing: Bool,
        onProgress: ((Progress) -> Void)? = nil
    ) throws -> Summary {
        let referenceFloorY = ScanGroupMerger.referenceFloorY(of: scans)
        var primitives: [GLBWriter.Primitive] = []
        var skipped = 0
        let fm = FileManager.default

        for (index, scan) in scans.enumerated() {
            let texturedURL = scan.folderURL.appendingPathComponent("textured.glb")
            if !fm.fileExists(atPath: texturedURL.path) {
                guard bakeMissing, fm.fileExists(atPath: scan.folderURL.appendingPathComponent("scan.usdz").path) else {
                    skipped += 1
                    continue
                }
                onProgress?(.baking(scanIndex: index, scanCount: scans.count, frames: nil))
                do {
                    try TextureBaker.bake(projectURL: scan.folderURL, outputURL: texturedURL, onProgress: { frames in
                        onProgress?(.baking(scanIndex: index, scanCount: scans.count, frames: frames))
                    })
                } catch {
                    logger.error("스캔 \(index + 1) 텍스처 생성 실패 -- \(String(describing: error), privacy: .public)")
                    skipped += 1
                    continue
                }
            }

            onProgress?(.merging)
            guard let raws = try? GLBLoader.loadPrimitives(at: texturedURL) else {
                logger.error("스캔 \(index + 1) textured.glb를 읽을 수 없음 -- 건너뜀")
                skipped += 1
                continue
            }
            let yOffset = ScanGroupMerger.verticalOffset(for: scan, referenceFloorY: referenceFloorY)
            for raw in raws {
                primitives.append(transformed(raw, alignment: scan.alignment, yOffset: yOffset))
            }
        }

        guard !primitives.isEmpty else { throw MergeError.noTexturedScans }
        onProgress?(.merging)
        try GLBWriter.write(primitives: primitives, to: outputURL)
        return Summary(texturedScanCount: scans.count - skipped, skippedScanCount: skipped)
    }

    /// 정렬 변환(평면 이동 + yaw)과 바닥 높이 오프셋을 정점에, yaw 회전만 normal에 적용한다.
    /// 텍스처와 UV는 그대로(같은 아틀라스를 그대로 쓰므로).
    static func transformed(_ raw: GLBLoader.RawPrimitive, alignment: ScanAlignment, yOffset: Float) -> GLBWriter.Primitive {
        var positions: [Float] = []
        positions.reserveCapacity(raw.positions.count * 3)
        for p in raw.positions {
            var q = alignment.apply(p)
            q.y += yOffset
            positions.append(contentsOf: [q.x, q.y, q.z])
        }

        let sourceNormals = raw.normals
            ?? MeshGeometryBuilder.computeFaceNormals(positions: raw.positions, indices: raw.triangleIndices)
        var normals: [Float] = []
        normals.reserveCapacity(raw.positions.count * 3)
        for n in sourceNormals {
            let r = alignment.rotateXZ(x: n.x, z: n.z)
            normals.append(contentsOf: [r.x, n.y, r.z])
        }
        if normals.count != positions.count {
            normals = [Float](repeating: 0, count: positions.count)
            for i in stride(from: 1, to: normals.count, by: 3) { normals[i] = 1 }
        }

        var uvs: [Float] = []
        if let rawUVs = raw.uvs, rawUVs.count == raw.positions.count {
            uvs.reserveCapacity(rawUVs.count * 2)
            for uv in rawUVs { uvs.append(contentsOf: [uv.x, uv.y]) }
        } else {
            uvs = [Float](repeating: 0, count: raw.positions.count * 2)
        }

        return GLBWriter.Primitive(
            positions: positions, normals: normals, uvs: uvs, indices: raw.indices,
            imageData: raw.imageData ?? whitePixelPNG,
            imageMimeType: raw.imageData == nil ? "image/png" : (raw.imageMimeType ?? "image/png")
        )
    }

    /// 텍스처가 없는 primitive용 대체(GLBWriter는 primitive마다 텍스처가 필수).
    private static let whitePixelPNG: Data = GLBWriter.encodePNG(rgba: [255, 255, 255, 255], width: 1, height: 1) ?? Data()
}

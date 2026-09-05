import SceneKit
import SwiftUI
import UIKit

/// 프로젝트 안 스캔들을 정렬 변환 적용해 합친 mesh를 내보내기 전에 미리 본다
/// (ScanGroupMerger 결과를 그대로 SceneKit으로). 합치기는 무거울 수 있어 백그라운드
/// 큐에서 하고, 뷰어 자체는 ProjectDetailView의 USDZSceneView와 같은 SCNView 설정
/// (카메라 제스처, 필요할 때만 렌더링)을 쓴다. 툴바의 "텍스처"는 스캔별 textured.glb를
/// (없으면 먼저 굽고) 합쳐서(TexturedGroupMerger) 같은 자리에 텍스처 입힌 장면으로 바꾼다
/// -- 굽는 데 시간이 걸려 회색 mesh를 먼저 보여주고 명시적으로 눌렀을 때만 한다.
struct MergedMeshViewer: View {
    let scans: [ScanGroupMerger.ScanInput]
    let onDismiss: () -> Void

    @State private var scene: SCNScene?
    @State private var errorMessage: String?
    @State private var summary: String?
    @State private var isTexturing = false
    @State private var isTextured = false
    @State private var textureStatus: String?
    @State private var textureError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let scene {
                    MergedSceneView(scene: scene)
                        .ignoresSafeArea()
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    ProgressView("합치는 중…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }

                VStack(spacing: 6) {
                    Spacer()
                    if let textureStatus {
                        Text(textureStatus)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.blue.opacity(0.7), in: Capsule())
                    }
                    if let textureError {
                        Text(textureError)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    if let summary {
                        Text(summary)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.5), in: Capsule())
                    }
                }
                .padding(.bottom, 12)
            }
            .navigationTitle("합친 mesh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기", action: onDismiss)
                        .tint(.white)
                }
                ToolbarItem(placement: .primaryAction) {
                    if isTexturing {
                        ProgressView()
                            .tint(.white)
                    } else if scene != nil, !isTextured {
                        Button {
                            applyTextures()
                        } label: {
                            Label("텍스처", systemImage: "photo.on.rectangle.angled")
                        }
                        .tint(.white)
                    }
                }
            }
            .toolbarBackground(.black.opacity(0.4), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard scene == nil, errorMessage == nil else { return }
        let inputs = scans
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let merged = try ScanGroupMerger.mergeMesh(scans: inputs)
                let geometry = MeshGeometryBuilder.build(
                    positions: merged.positions, normals: merged.normals, colors: nil, triangleIndices: merged.indices
                )
                let material = SCNMaterial()
                material.lightingModel = .physicallyBased
                material.diffuse.contents = UIColor(white: 0.85, alpha: 1)
                material.isDoubleSided = true
                geometry.materials = [material]
                let built = SCNScene()
                built.rootNode.addChildNode(SCNNode(geometry: geometry))
                let text = "정점 \(merged.positions.count) · 삼각형 \(merged.indices.count / 3) · 스캔 \(inputs.count)개"
                DispatchQueue.main.async {
                    scene = built
                    summary = text
                }
            } catch {
                DispatchQueue.main.async { errorMessage = error.localizedDescription }
            }
        }
    }

    /// 스캔별 textured.glb를(없으면 먼저 굽고) 합쳐 텍스처 입힌 장면으로 교체한다.
    /// 결과 GLB는 임시 폴더에 두고 GLBLoader로 다시 읽는다 -- 내보내기(ProjectGroupDetailView)와
    /// 같은 파일 형식이라 미리보기와 내보낸 결과가 같다.
    private func applyTextures() {
        guard !isTexturing else { return }
        isTexturing = true
        textureError = nil
        textureStatus = "텍스처 준비 중…"
        let inputs = scans
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("merged-textured-\(UUID().uuidString).glb")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try TexturedGroupMerger.merge(scans: inputs, to: outputURL, bakeMissing: true) { progress in
                    let text = Self.statusText(for: progress)
                    DispatchQueue.main.async { textureStatus = text }
                }
                let loaded = try GLBLoader.loadScene(at: outputURL)
                DispatchQueue.main.async {
                    scene = loaded
                    isTextured = true
                    isTexturing = false
                    textureStatus = nil
                    var text = "텍스처 입힘 · 스캔 \(result.texturedScanCount)개"
                    if result.skippedScanCount > 0 { text += " · \(result.skippedScanCount)개 건너뜀(mesh 없음)" }
                    summary = text
                }
            } catch {
                DispatchQueue.main.async {
                    isTexturing = false
                    textureStatus = nil
                    textureError = "텍스처 입히기 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    static func statusText(for progress: TexturedGroupMerger.Progress) -> String {
        switch progress {
        case .baking(let index, let count, let frames):
            if let frames {
                return "스캔 \(index + 1)/\(count) 텍스처 생성 중 (\(frames.framesProcessed)/\(frames.totalFrames) 프레임)"
            }
            return "스캔 \(index + 1)/\(count) 텍스처 생성 준비 중…"
        case .merging:
            return "텍스처 합치는 중…"
        }
    }
}

private struct MergedSceneView: UIViewRepresentable {
    let scene: SCNScene

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .black
        view.rendersContinuously = false
        view.preferredFramesPerSecond = 30
        view.scene = scene
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        if uiView.scene !== scene { uiView.scene = scene }
    }
}

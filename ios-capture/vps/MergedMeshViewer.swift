import SceneKit
import SwiftUI
import UIKit

/// 프로젝트 안 스캔들을 정렬 변환 적용해 합친 mesh를 내보내기 전에 미리 본다
/// (ScanGroupMerger 결과를 그대로 SceneKit으로). 합치기는 무거울 수 있어 백그라운드
/// 큐에서 하고, 뷰어 자체는 ProjectDetailView의 USDZSceneView와 같은 SCNView 설정
/// (카메라 제스처, 필요할 때만 렌더링)을 쓴다.
struct MergedMeshViewer: View {
    let scans: [ScanGroupMerger.ScanInput]
    let onDismiss: () -> Void

    @State private var scene: SCNScene?
    @State private var errorMessage: String?
    @State private var summary: String?

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

                if let summary {
                    VStack {
                        Spacer()
                        Text(summary)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.5), in: Capsule())
                            .padding(.bottom, 12)
                    }
                }
            }
            .navigationTitle("합친 mesh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기", action: onDismiss)
                        .tint(.white)
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

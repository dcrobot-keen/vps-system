import SceneKit
import SwiftUI

/// glb/pcd/ply/usdz/obj 파일을 확장자로 구분해서 알맞은 방식으로 불러와 보여준다.
/// usdz/obj는 SceneKit/ModelIO가 iOS에서 기본 지원하는 포맷이라 `SCNScene(url:)`를
/// 그대로 쓴다(다만 이 세션에서 ModelIO 관련 API가 문서와 다르게 동작한 전례가
/// 있어 실기기 검증 전까지는 확신 못 함). glb/pcd/ply는 SceneKit이 아예 못 읽어서
/// `GLBLoader`/`PCDLoader`/`PLYLoader`가 직접 파싱한다.
struct UniversalModelViewer: View {
    let file: ImportedFile

    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            } else {
                ModelSceneView(url: file.url, fileExtension: file.fileExtension) { message in
                    errorMessage = message
                }
                .ignoresSafeArea()
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ModelSceneView: UIViewRepresentable {
    let url: URL
    let fileExtension: String
    let onError: (String) -> Void

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .black
        view.rendersContinuously = false
        view.preferredFramesPerSecond = 30

        DispatchQueue.global(qos: .userInitiated).async {
            let scene: SCNScene?
            do {
                scene = try Self.loadScene(url: url, fileExtension: fileExtension)
            } catch {
                scene = nil
                DispatchQueue.main.async { onError("불러오기 실패: \(error)") }
            }
            DispatchQueue.main.async {
                if let scene {
                    view.scene = scene
                    view.pointOfView = Self.fittedCamera(for: scene)
                }
            }
        }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    private static func loadScene(url: URL, fileExtension: String) throws -> SCNScene {
        switch fileExtension {
        case "usdz", "obj":
            return try SCNScene(url: url, options: nil)
        case "glb":
            return try GLBLoader.loadScene(at: url)
        case "ply":
            let scene = SCNScene()
            scene.rootNode.addChildNode(SCNNode(geometry: try PLYLoader.loadGeometry(at: url)))
            return scene
        case "pcd":
            let scene = SCNScene()
            scene.rootNode.addChildNode(SCNNode(geometry: try PCDLoader.loadGeometry(at: url)))
            return scene
        default:
            throw CocoaError(.fileReadUnsupportedScheme)
        }
    }

    /// bounding box에 맞춰 카메라를 배치한다 — 파일마다 스케일/원점이 제각각이라
    /// (mesh export는 미터 단위 world 좌표, 어떤 도구는 다른 단위를 쓰기도 함)
    /// 고정된 카메라 위치로는 화면 밖으로 나가거나 너무 작게 보이는 경우가 많다.
    private static func fittedCamera(for scene: SCNScene) -> SCNNode {
        let (minVec, maxVec) = scene.rootNode.boundingBox
        let center = SCNVector3(
            (minVec.x + maxVec.x) / 2, (minVec.y + maxVec.y) / 2, (minVec.z + maxVec.z) / 2
        )
        let size = max(maxVec.x - minVec.x, max(maxVec.y - minVec.y, maxVec.z - minVec.z))
        let distance = max(CGFloat(size) * 1.5, 0.5)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(center.x, center.y, center.z + Float(distance))
        cameraNode.look(at: center)
        scene.rootNode.addChildNode(cameraNode)
        return cameraNode
    }
}

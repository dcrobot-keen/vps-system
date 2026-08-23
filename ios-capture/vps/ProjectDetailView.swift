import ImageIO
import SceneKit
import SwiftUI

/// 프로젝트 하나의 내용을 보여주는 화면. scan.usdz가 있으면 SceneKit으로 3D mesh를
/// 바로 볼 수 있고, 캡처된 RGB 사진들을 썸네일 그리드로 훑어볼 수 있다.
///
/// QuickLook 대신 SceneKit(SCNView)을 쓴다 — 앱이 스캔 화면(ScanView)에서 이미
/// ARSCNView/SceneKit을 쓰고 있어서 여기로 전환할 때 추가 프레임워크 초기화 비용이
/// 거의 없다. QuickLook은 처음 쓸 때 초기화 비용이 커서 실기기에서 몇 초 프리징이
/// 확인됐고, 미리 warm-up 시도도 launch 시퀀스와 메인 스레드를 다퉈서 오히려
/// "System gesture gate timed out" 문제를 만들었다 — SceneKit으로 바꾸면 그런
/// 지연/타이밍 문제 자체가 없어진다.
struct ProjectDetailView: View {
    let project: ScanProject

    @State private var isShowingMeshViewer = false
    @State private var rgbURLs: [URL] = []

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 4)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summarySection

                if project.hasUSDZ {
                    Button {
                        isShowingMeshViewer = true
                    } label: {
                        Label("3D mesh 보기", systemImage: "cube.transparent")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if !rgbURLs.isEmpty {
                    Text("캡처된 사진 (\(rgbURLs.count)장)")
                        .font(.headline)

                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(rgbURLs, id: \.self) { url in
                            ThumbnailView(url: url)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(project.id)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadRGBList)
        .fullScreenCover(isPresented: $isShowingMeshViewer) {
            NavigationStack {
                USDZSceneView(url: project.url.appendingPathComponent("scan.usdz"))
                    .ignoresSafeArea()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("닫기") { isShowingMeshViewer = false }
                                .tint(.white)
                        }
                    }
                    .toolbarBackground(.black.opacity(0.4), for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
            }
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let frameCount = project.frameCount {
                Text("\(frameCount) 프레임")
            }
            if let startTime = project.startTime {
                Text(startTime.formatted(date: .abbreviated, time: .shortened))
            }
            Text(project.hasUSDZ ? "scan.usdz 있음" : "scan.usdz 없음")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func loadRGBList() {
        let rgbDir = project.url.appendingPathComponent("rgb")
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: rgbDir, includingPropertiesForKeys: nil
        )) ?? []
        rgbURLs = urls
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// scan.usdz를 SceneKit으로 직접 로드해서 보여준다 (핀치로 확대/축소, 드래그로 회전 —
/// SCNView.allowsCameraControl이 제공하는 기본 제스처).
private struct USDZSceneView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .black
        // 계속 풀프레임으로 다시 그리지 않고, 카메라를 실제로 조작할 때만
        // 다시 그린다 (allowsCameraControl이 알아서 그 시점에 렌더링을 트리거함) —
        // 안 그러면 화면을 안 만지고 있어도 GPU를 계속 태워서 반응이 느려진다.
        view.rendersContinuously = false
        view.preferredFramesPerSecond = 30

        // vertex 수십만 개짜리 usdz(수 MB) 파싱을 메인 스레드에서 동기로 하면 화면
        // 전환 자체가 버벅인다 — 백그라운드에서 로드하고 다 되면 메인 스레드에서
        // scene만 얹는다.
        DispatchQueue.global(qos: .userInitiated).async {
            let scene = try? SCNScene(url: url, options: nil)
            if let scene {
                fixVertexColorMaterials(scene)
            }
            DispatchQueue.main.async {
                view.scene = scene
            }
        }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    /// SceneKit이 scan.usdz를 export할 때, mesh마다 만든 vertex color(primvars:displayColor)
    /// 데이터 자체는 유지하지만 material의 diffuseColor는 그 primvar를 참조하지 않고
    /// 그냥 흰색(1,1,1)으로 고정해서 써버린다(실측 확인) — 그래서 표준 USD material
    /// 그래프로 렌더링하면 색이 하나도 안 보인다. geometry에 남아있는 `.color` semantic
    /// source는 SceneKit의 실시간 렌더링 경로에서 기본 머티리얼에 자동으로 곱해지므로,
    /// 로드 직후 머티리얼을 새 기본 머티리얼로 갈아끼워서 이 경로를 타게 만든다.
    private func fixVertexColorMaterials(_ scene: SCNScene) {
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry, !geometry.sources(for: .color).isEmpty else { return }
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            geometry.materials = [material]
        }
    }
}

/// ImageIO의 썸네일 생성(CGImageSourceCreateThumbnailAtIndex)으로 원본 JPEG를 전부
/// 디코딩하지 않고 축소된 이미지만 비동기로 불러온다 — 사진이 수백 장이어도
/// LazyVGrid가 화면에 보이는 셀만 로드하므로 괜찮다.
private struct ThumbnailView: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
            }
        }
        .frame(width: 90, height: 90)
        .clipped()
        .task {
            image = await Self.loadThumbnail(url: url)
        }
    }

    private static func loadThumbnail(url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 200,
                // false로 둔다: 이 앱은 raw(landscape) 그대로 저장하는 정책이라
                // (poses.jsonl의 intrinsics도 raw 기준, Python 파이프라인도
                // IMREAD_IGNORE_ORIENTATION으로 방향 태그를 무시함) EXIF 방향
                // 태그를 "적용"하면 오히려 다르게(뒤집혀) 보인다.
                kCGImageSourceCreateThumbnailWithTransform: false,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }.value
    }
}

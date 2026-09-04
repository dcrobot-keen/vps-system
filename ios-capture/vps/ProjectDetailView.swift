import ImageIO
import SceneKit
import SwiftUI

/// 프로젝트 하나의 내용을 보여주는 화면. scan.usdz가 있으면 SceneKit으로 3D mesh를
/// 바로 볼 수 있고, "캡처된 사진" 버튼을 누르면 썸네일 그리드가 펼쳐진다. 아무
/// 썸네일이나 탭하면 그 사진부터 전체화면 갤러리(PhotoGalleryView, 핀치줌 지원)가
/// 열린다.
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

    @State private var hasTexturedGLB = false
    @State private var isBaking = false
    @State private var bakeProgress: TextureBaker.Progress?
    @State private var bakeErrorMessage: String?
    @State private var isShowingTexturedViewer = false

    @State private var isUploading = false
    @State private var uploadStatusText: String?
    @State private var uploadSuccessRoomID: String?
    @State private var uploadErrorMessage: String?

    @State private var isShowingLocalizeView = false

    @State private var isShowingPhotoGallery = false
    @State private var selectedPhotoIndex = 0
    @State private var isShowingThumbnailGrid = false

    /// 서버 업로드는 로봇 스택 연동용이라 설정의 "고급 모드"가 켜져 있을 때만
    /// 노출한다 -- 일반 사용자에겐 이 앱이 서버 없이 완결된 스캐너여야 한다.
    @AppStorage(ServerSettingsStore.advancedModeKey) private var isAdvancedModeEnabled = false

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

                    textureBakeSection
                }

                if isAdvancedModeEnabled {
                    vpsUploadSection
                }

                if project.hasWorldMap {
                    Button {
                        isShowingLocalizeView = true
                    } label: {
                        Label("위치 확인 (서버 없이)", systemImage: "location.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if !rgbURLs.isEmpty {
                    Button {
                        withAnimation { isShowingThumbnailGrid.toggle() }
                    } label: {
                        Label("캡처된 사진 (\(rgbURLs.count)장)", systemImage: isShowingThumbnailGrid ? "chevron.down" : "chevron.right")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .font(.headline)

                    if isShowingThumbnailGrid {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(Array(rgbURLs.enumerated()), id: \.offset) { index, url in
                                Button {
                                    selectedPhotoIndex = index
                                    isShowingPhotoGallery = true
                                } label: {
                                    ThumbnailView(url: url)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(project.id)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadRGBList()
            hasTexturedGLB = FileManager.default.fileExists(atPath: texturedGLBURL.path)
        }
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
        .fullScreenCover(isPresented: $isShowingPhotoGallery) {
            PhotoGalleryView(urls: rgbURLs, startIndex: selectedPhotoIndex) {
                isShowingPhotoGallery = false
            }
        }
        .fullScreenCover(isPresented: $isShowingLocalizeView) {
            NavigationStack {
                LocalizeView(project: project)
            }
        }
        .fullScreenCover(isPresented: $isShowingTexturedViewer) {
            NavigationStack {
                GLBSceneView(url: texturedGLBURL)
                    .ignoresSafeArea()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("닫기") { isShowingTexturedViewer = false }
                                .tint(.white)
                        }
                    }
                    .toolbarBackground(.black.opacity(0.4), for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
            }
        }
    }

    private var texturedGLBURL: URL {
        project.url.appendingPathComponent("textured.glb")
    }

    /// 사진을 mesh에 직접 프로젝션해서 텍스처를 굽는다(`TextureBaker`, Metal 기반,
    /// SuGaR/GPU-서버 없이 온디바이스에서 끝남) — `scan.usdz` + `rgb/` + `poses.jsonl`만
    /// 있으면 되므로 mesh 보기와 같은 조건(`project.hasUSDZ`)으로 노출한다.
    private var textureBakeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isBaking {
                VStack(alignment: .leading, spacing: 4) {
                    if let bakeProgress {
                        ProgressView(value: Double(bakeProgress.framesProcessed), total: Double(max(bakeProgress.totalFrames, 1)))
                        Text("\(bakeProgress.framesProcessed) / \(bakeProgress.totalFrames) 프레임")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            } else {
                Button {
                    startBaking()
                } label: {
                    Label(hasTexturedGLB ? "텍스처 다시 생성" : "텍스처 생성", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if hasTexturedGLB {
                    Button {
                        isShowingTexturedViewer = true
                    } label: {
                        Label("텍스처 결과 보기", systemImage: "cube.transparent.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if let bakeErrorMessage {
                Text(bakeErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// 실기기 발열/시간이 꽤 걸릴 수 있는 작업이라 명시적 버튼으로만 트리거한다
    /// (스캔 종료 직후 자동 실행 안 함). `ProjectStore.exportZip`과 같은 패턴 —
    /// 백그라운드 큐에서 돌리고 완료 콜백만 메인 스레드로 되돌린다.
    private func startBaking() {
        isBaking = true
        bakeProgress = nil
        bakeErrorMessage = nil
        let projectURL = project.url
        let outputURL = texturedGLBURL
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try TextureBaker.bake(projectURL: projectURL, outputURL: outputURL) { progress in
                    DispatchQueue.main.async { bakeProgress = progress }
                }
                DispatchQueue.main.async {
                    isBaking = false
                    hasTexturedGLB = true
                }
            } catch {
                DispatchQueue.main.async {
                    isBaking = false
                    bakeErrorMessage = "텍스처 생성 실패: \(error)"
                }
            }
        }
    }

    /// scan.usdz 없이 rgb/depth/poses.jsonl만으로 되는 작업이라(VPS DB 빌드는 usdz를
    /// 안 씀 — pipeline/dc_vps_pipeline/db_build.py 참고) mesh 보기/텍스처 생성과
    /// 달리 `project.hasUSDZ` 조건 없이 항상 노출한다.
    private var vpsUploadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isUploading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView()
                    if let uploadStatusText {
                        Text(uploadStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Button {
                    startUpload()
                } label: {
                    Label("VPS 서버에 업로드", systemImage: "arrow.up.to.line.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if let uploadSuccessRoomID {
                Text("등록 완료 (room: \(uploadSuccessRoomID))")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let uploadErrorMessage {
                Text(uploadErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// scan_<name>/를 zip으로 압축(ZipArchiver, ProjectStore.exportZip과 같은 함수
    /// 재사용) -> VPSUploadClient로 업로드 -> 서버 job이 끝날 때까지 폴링. 업로드
    /// 중에는 앱을 켜둔 상태로 유지해야 한다(백그라운드 세션이 아니라 foreground
    /// URLSession이라 — 이 단계에서는 진짜 백그라운드 전송까지는 범위 밖으로 뒀다).
    private func startUpload() {
        let settingsStore = ServerSettingsStore()
        guard let serverURL = settingsStore.serverURL else {
            uploadErrorMessage = "설정(⚙️)에서 서버 주소를 먼저 입력하세요"
            return
        }
        isUploading = true
        uploadErrorMessage = nil
        uploadSuccessRoomID = nil
        uploadStatusText = "압축 중…"

        let projectURL = project.url
        let scanName = project.id

        DispatchQueue.global(qos: .userInitiated).async {
            let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(scanName)-upload.zip")
            try? FileManager.default.removeItem(at: zipURL)
            do {
                try ZipArchiver.zip(directory: projectURL, to: zipURL)
            } catch {
                DispatchQueue.main.async {
                    isUploading = false
                    uploadErrorMessage = "압축 실패: \(error.localizedDescription)"
                }
                return
            }

            DispatchQueue.main.async {
                uploadStatusText = "업로드 중… 0%"
                VPSUploadClient.upload(
                    zipFileURL: zipURL, scanName: scanName, serverURL: serverURL, replace: true,
                    onProgress: { progress in
                        uploadStatusText = "업로드 중… \(Int(progress * 100))%"
                    },
                    completion: { result in
                        try? FileManager.default.removeItem(at: zipURL)
                        switch result {
                        case .success:
                            uploadStatusText = "서버에서 처리 중…"
                            pollScanStatus(
                                scanName: scanName, serverURL: serverURL,
                                deadline: Date().addingTimeInterval(10 * 60)
                            )
                        case .failure(let error):
                            isUploading = false
                            uploadErrorMessage = "업로드 실패: \(error.localizedDescription)"
                        }
                    }
                )
            }
        }
    }

    /// 3초 간격으로 GET /scans/{scanName}을 재귀 폴링한다. 10분 넘게 안 끝나면
    /// 클라이언트 쪽에서 포기하지만(서버 job 자체는 계속 돎), 네트워크 일시
    /// 오류만으로는 포기하지 않고 다음 폴링에 다시 시도한다 — 업로드는 이미
    /// 서버가 접수했으므로 여기서 성급하게 실패 처리하면 오히려 오해를 준다.
    private func pollScanStatus(scanName: String, serverURL: URL, deadline: Date) {
        guard Date() < deadline else {
            isUploading = false
            uploadErrorMessage = "빌드 상태 확인 시간 초과 — 서버에서는 계속 진행 중일 수 있습니다"
            return
        }
        VPSUploadClient.fetchStatus(scanName: scanName, serverURL: serverURL) { result in
            switch result {
            case .success(let status):
                switch status.status {
                case "done":
                    isUploading = false
                    uploadStatusText = nil
                    uploadSuccessRoomID = status.room_id
                case "failed":
                    isUploading = false
                    uploadErrorMessage = "빌드 실패: \(status.error ?? "알 수 없는 오류")"
                default:
                    uploadStatusText = Self.statusLabel(for: status.status)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        pollScanStatus(scanName: scanName, serverURL: serverURL, deadline: deadline)
                    }
                }
            case .failure:
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    pollScanStatus(scanName: scanName, serverURL: serverURL, deadline: deadline)
                }
            }
        }
    }

    private static func statusLabel(for status: String) -> String {
        switch status {
        case "unzipping": return "압축 해제 중…"
        case "building": return "VPS DB 빌드 중…"
        case "registering": return "등록 중…"
        default: return status
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

/// `TextureBaker`가 구운 `textured.glb`를 보여준다 — SceneKit이 glTF를 못 읽으므로
/// `GLBLoader`로 직접 파싱한다(`USDZSceneView`와 같은 백그라운드 로드 패턴).
private struct GLBSceneView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .black
        view.rendersContinuously = false
        view.preferredFramesPerSecond = 30

        DispatchQueue.global(qos: .userInitiated).async {
            let scene = try? GLBLoader.loadScene(at: url)
            DispatchQueue.main.async {
                view.scene = scene
            }
        }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

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

    /// 탭한 인덱스를 담아 갤러리를 연다. `isShowingPhotoGallery: Bool` +
    /// `selectedPhotoIndex: Int`(2026-09-04 이전 방식)였을 때는 첫 번째 탭에서
    /// 항상 엉뚱한(첫) 사진이 나오고 두 번째부터 제대로 나오는 버그가 있었다 --
    /// `fullScreenCover(isPresented:)`는 매번 같은 하위 뷰 인스턴스/State 저장소를
    /// 재사용하므로, `PhotoGalleryView.init`의 `_currentIndex = State(initialValue:
    /// startIndex)`가 처음 한 번만 적용되고 이후엔 무시돼(전형적인 SwiftUI 함정)
    /// 이전에 열었던 인덱스가 그대로 남아있었다. `fullScreenCover(item:)`으로
    /// 바꾸면 매번 새 `id`(다른 사진을 탭하든 같은 사진을 두 번 탭하든)가 생겨
    /// SwiftUI가 매번 새 State를 만든다 -- `floorPlanShareItem`/`ShareItem`과
    /// 같은 패턴.
    private struct PhotoGalleryItem: Identifiable {
        let id = UUID()
        let startIndex: Int
    }
    @State private var photoGalleryItem: PhotoGalleryItem?
    @State private var isShowingThumbnailGrid = false

    @State private var isShowingFloorPlan = false
    @State private var floorPlanShareItem: ShareItem?

    @State private var projectSizeText: String?

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

                if project.hasFloorPlan {
                    Button {
                        isShowingFloorPlan = true
                    } label: {
                        Label("바닥 평면 보기", systemImage: "square.grid.3x3.topleft.filled")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
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
                                    photoGalleryItem = PhotoGalleryItem(startIndex: index)
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
            loadProjectSize()
            resumeUploadIfNeeded()
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
        .fullScreenCover(item: $photoGalleryItem) { item in
            PhotoGalleryView(urls: rgbURLs, startIndex: item.startIndex) {
                photoGalleryItem = nil
            }
        }
        .fullScreenCover(isPresented: $isShowingLocalizeView) {
            NavigationStack {
                LocalizeView(project: project)
            }
        }
        .fullScreenCover(isPresented: $isShowingFloorPlan) {
            FloorPlanViewerView(
                url: floorPlanURL,
                onDismiss: { isShowingFloorPlan = false },
                onShare: { floorPlanShareItem = ShareItem(url: floorPlanURL) }
            )
        }
        .sheet(item: $floorPlanShareItem) { item in
            ShareSheet(activityItems: [item.url])
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

    private var floorPlanURL: URL {
        project.url.appendingPathComponent("floorplan.png")
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
                try TextureBaker.bake(
                    projectURL: projectURL, outputURL: outputURL,
                    onProgress: { progress in
                        DispatchQueue.main.async { bakeProgress = progress }
                    },
                    onBakedFaceColors: { positions, indices, faceColors in
                        recolorFloorPlan(projectURL: projectURL, positions: positions, indices: indices, faceColors: faceColors)
                    }
                )
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

    /// 텍스처 베이킹이 끝난 뒤, 그 결과(face별 평균 색)로 floorplan.png의 바닥 색을
    /// 실제 사진 색으로 다시 칠한다 -- "텍스처 결과 보기의 바닥 색이 floorplan.png에도
    /// 입혀졌으면 좋겠다"는 요청(2026-09-04, PRODUCT-PLAN.md). floorplan.png/
    /// floorplan.json이 없거나(구버전 스캔) 바닥 높이 정보가 없으면(classification
    /// 미지원 기기에서 바닥 삼각형이 하나도 안 잡힌 경우) 조용히 건너뛴다 -- 부가
    /// 기능이라 실패해도 텍스처 베이킹 자체(hasTexturedGLB)에 영향을 주면 안 된다.
    /// `TextureBaker`의 백그라운드 큐에서 그대로 불리므로 여기서도 파일 I/O만 하고
    /// 메인 스레드로 넘기지 않는다.
    private func recolorFloorPlan(
        projectURL: URL, positions: [SIMD3<Float>], indices: [UInt32], faceColors: [SIMD3<Float>]
    ) {
        let floorplanURL = projectURL.appendingPathComponent("floorplan.png")
        guard let meta = FloorPlanRenderer.PersistedMeta.load(from: projectURL),
              let floorHeightMin = meta.floorHeightMin, let floorHeightMax = meta.floorHeightMax,
              let baseImage = UIImage(contentsOfFile: floorplanURL.path)
        else { return }

        let patches = FloorPlanRenderer.floorPatches(
            positions: positions, indices: indices, faceColors: faceColors,
            floorHeightMin: floorHeightMin, floorHeightMax: floorHeightMax
        )
        guard !patches.isEmpty else { return }

        let scanPathXZ = FloorPlanRenderer.loadScanPathXZ(from: projectURL)
        let recolored = FloorPlanRenderer.recolorFloor(
            baseImage: baseImage, floorPatches: patches,
            resolutionMetersPerPixel: meta.resolutionMetersPerPixel,
            originX: meta.originX, originTopZ: meta.originTopZ,
            scanPathXZ: scanPathXZ
        )
        guard let pngData = recolored.pngData() else { return }
        try? pngData.write(to: floorplanURL)
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

    /// 이 화면이 마지막으로 떠 있는 동안(또는 앱이 통째로 재시작되는 동안) 백그라운드
    /// 업로드가 끝났으면 `VPSUploadClient`가 `upload_status.json`에 결과를 남겨둔다 --
    /// 화면이 다시 열릴 때마다 확인해서, "접수됨"이면 빌드 상태 폴링을 이어서 시작하고
    /// "실패"면 에러를 보여준다. 둘 다 아니면(파일 자체가 없으면) 조용히 넘어간다.
    private func resumeUploadIfNeeded() {
        guard let outcome = VPSUploadClient.loadPersistedUploadOutcome(projectURL: project.url) else { return }
        VPSUploadClient.clearPersistedUploadOutcome(projectURL: project.url)

        switch outcome.status {
        case "accepted":
            guard let serverURL = ServerSettingsStore().serverURL else { return }
            isUploading = true
            uploadErrorMessage = nil
            uploadStatusText = "서버에서 처리 중…"
            pollScanStatus(scanName: project.id, serverURL: serverURL, deadline: Date().addingTimeInterval(10 * 60))
        case "failed":
            uploadErrorMessage = "업로드 실패: \(outcome.errorMessage ?? "알 수 없는 오류")"
        default:
            break
        }
    }

    /// scan_<name>/를 zip으로 압축(ZipArchiver, ProjectStore.exportZip과 같은 함수
    /// 재사용) -> VPSUploadClient로 업로드(진짜 백그라운드 URLSession, 앱이 백그라운드로
    /// 가거나 종료돼도 전송이 이어짐) -> 서버 job이 끝날 때까지 폴링. 폴링 자체는
    /// foreground라 앱이 완전히 꺼지면 멈추지만, 업로드가 이미 서버에 도착한 뒤라면
    /// 다음에 이 화면을 열 때 `resumeUploadIfNeeded`가 이어서 폴링을 다시 시작한다.
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
            if let projectSizeText {
                // 보간 있는 리터럴이라 String Catalog 추출 대상이지만, 정확한 %@ 키
                // 형식은 맥 빌드 시 Xcode 자동 추출기가 채우도록 둔다(기존 방침).
                Text("이 프로젝트 용량: \(projectSizeText)")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    /// 파일이 수백~수천 개일 수 있어(rgb/depth 프레임마다 2~3개) 백그라운드 큐에서
    /// 잰다 -- 저장 공간 표시/경고 기능의 "프로젝트 용량 표시" 부분(PRODUCT-PLAN.md).
    private func loadProjectSize() {
        let url = project.url
        DispatchQueue.global(qos: .utility).async {
            let bytes = DeviceStorage.directorySizeBytes(at: url)
            let text = DeviceStorage.formatted(bytes)
            DispatchQueue.main.async {
                projectSizeText = text
            }
        }
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

/// FloorPlanRenderer가 만든 floorplan.png를 핀치줌으로 보여준다 (PhotoGalleryView의
/// ZoomableImageView 재사용). 사진 갤러리와 달리 한 장뿐이라 페이지 넘김 없이 닫기/
/// 공유 버튼만 얹는다.
private struct FloorPlanViewerView: View {
    let url: URL
    let onDismiss: () -> Void
    let onShare: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            ZoomableImageView(url: url)
                .ignoresSafeArea()

            HStack {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                }
                Spacer()
                Button(action: onShare) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                }
            }
            .padding()
        }
        .statusBarHidden()
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
                // false로 둔다: 이 파일엔 EXIF 방향 태그 자체가 없으므로(raw(landscape)
                // 그대로 저장하는 정책 -- poses.jsonl의 intrinsics도 raw 기준, Python
                // 파이프라인도 IMREAD_IGNORE_ORIENTATION으로 읽음) 여기서 트랜스폼을
                // 걸어도 아무 효과가 없다. 화면 표시용 회전은 아래
                // forCapturedPhotoDisplay가 따로(디스크 바이트는 안 건드리고) 건다 --
                // 2026-09-04 실기 확인: 이게 없으면 세로로 들고 찍은 사진이 90도
                // 누워 보임(PhotoGalleryView.swift의 UIImage.forCapturedPhotoDisplay
                // 주석 참고).
                kCGImageSourceCreateThumbnailWithTransform: false,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return UIImage.forCapturedPhotoDisplay(cgImage: cgImage, orientation: .right)
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

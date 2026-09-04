import SwiftUI
import UIKit

extension UIImage {
    /// 캡처된 사진(`rgb/*.jpg`)은 ARKit `capturedImage`의 raw(landscape) 버퍼를
    /// 그대로 저장한다 -- Python 파이프라인이 `IMREAD_IGNORE_ORIENTATION`으로 읽는
    /// 원본 픽셀과 완전히 일치해야 해서 디스크의 바이트 자체에는 회전/EXIF 보정을
    /// 걸지 않는다(`FaceRedactor.swift` 상단 주석 참고). 문제는 이 앱이 세로로 들고
    /// 스캔하는 게 일반적인 사용법이라서(`UIDevice.orientation`을 추적하는 코드가
    /// 없어 실제 촬영 방향을 앱이 스스로는 모름 -- `FaceRedactor`가 그래서 얼굴
    /// 검출을 두 orientation으로 다 시도하는 것과 같은 근본 원인), 화면에 그대로
    /// 보여주면 사진이 90도 누워 보인다(2026-09-04 실기 확인).
    ///
    /// 디스크의 원본 바이트/픽셀은 전혀 건드리지 않고, "화면에 보여줄 때만"
    /// `UIImage.imageOrientation` 메타데이터로 회전을 걸어(재인코딩 없음, `.size`도
    /// 자동으로 회전 반영된 값을 돌려줌) 세워서 보여준다. 호출부가 `.right`(세로로
    /// 들고 찍었을 때 보정 방향, `FaceRedactor`가 우선 시도하는 것과 같은 가정 --
    /// 가로로 들고 스캔한 경우는 여전히 틀어져 보일 수 있음, 이 앱이 실제 촬영
    /// 방향을 모르는 한 근본적인 한계)를 넘긴다.
    static func forCapturedPhotoDisplay(cgImage: CGImage, orientation: UIImage.Orientation, scale: CGFloat = 1) -> UIImage {
        UIImage(cgImage: cgImage, scale: scale, orientation: orientation)
    }
}

/// 캡처된 사진을 전체화면으로 스와이프해서 넘겨보고, 각 사진은 핀치/더블탭으로
/// 확대해서 볼 수 있다. `ProjectDetailView`의 "캡처된 사진 보기" 버튼으로 연다 —
/// 얼굴 모자이크(deface, FaceRedactor)가 실제로 적용됐는지 확대해서 확인하기
/// 위한 용도로 추가됨.
struct PhotoGalleryView: View {
    let urls: [URL]
    let startIndex: Int
    let onDismiss: () -> Void

    @State private var currentIndex: Int

    init(urls: [URL], startIndex: Int, onDismiss: @escaping () -> Void) {
        self.urls = urls
        self.startIndex = startIndex
        self.onDismiss = onDismiss
        _currentIndex = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    // .right: 캡처된 사진(rgb/*.jpg)은 raw(landscape) 그대로 저장돼
                    // 있어 화면 표시용으로만 회전 보정이 필요하다 -- forCapturedPhotoDisplay
                    // 주석 참고. floorplan.png 같은 일반 이미지는 이 보정이 필요 없다
                    // (FloorPlanViewerView는 기본값 .up으로 ZoomableImageView를 씀).
                    ZoomableImageView(url: url, displayOrientation: .right)
                        .ignoresSafeArea()
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                }
                Spacer()
                if !urls.isEmpty {
                    Text("\(currentIndex + 1) / \(urls.count)")
                        .foregroundStyle(.white)
                        .font(.footnote.monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: Capsule())
                }
            }
            .padding()
        }
        .statusBarHidden()
    }
}

/// UIScrollView 기반 확대/축소 이미지 뷰. SwiftUI의 MagnificationGesture를 직접
/// 조합하는 대신 UIScrollView의 네이티브 핀치줌(관성/경계 튕김 포함, 더블탭 확대도
/// 표준 동작)을 쓴다 — 훨씬 적은 코드로 훨씬 자연스러운 결과를 얻는다.
struct ZoomableImageView: UIViewRepresentable {
    let url: URL
    /// 화면 표시용 회전 보정(디스크 바이트는 안 건드림). 캡처된 사진(rgb/*.jpg)은
    /// `.right`(PhotoGalleryView 참고), floorplan.png처럼 원래부터 똑바른 일반
    /// 이미지는 기본값 `.up`(보정 없음)을 쓴다.
    var displayOrientation: UIImage.Orientation = .up

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = ZoomScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .black
        scrollView.bouncesZoom = true

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        // 원본 해상도 JPEG 디코딩을 메인 스레드에서 하지 않는다.
        DispatchQueue.global(qos: .userInitiated).async {
            let image = UIImage(contentsOfFile: url.path).flatMap { raw in
                raw.cgImage.map {
                    UIImage.forCapturedPhotoDisplay(cgImage: $0, orientation: displayOrientation, scale: raw.scale)
                }
            }
            DispatchQueue.main.async {
                guard let image else { return }
                imageView.image = image
                imageView.frame = CGRect(origin: .zero, size: image.size)
                scrollView.contentSize = image.size
                context.coordinator.centerImage()
            }
        }

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

        /// 스크롤뷰 크기(회전/최초 레이아웃)에 맞춰 최소 줌(전체 보기)을 다시 계산하고
        /// 이미지를 가운데 정렬한다. `ZoomScrollView.layoutSubviews()`가 호출한다.
        func centerImage() {
            guard let scrollView, let imageView, let image = imageView.image,
                  image.size.width > 0, image.size.height > 0
            else { return }

            let scale = min(scrollView.bounds.width / image.size.width, scrollView.bounds.height / image.size.height)
            if scale > 0, scrollView.minimumZoomScale != scale {
                scrollView.minimumZoomScale = scale
                scrollView.zoomScale = scale
            }

            let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
            let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
            imageView.center = CGPoint(
                x: scrollView.contentSize.width / 2 + offsetX,
                y: scrollView.contentSize.height / 2 + offsetY
            )
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }
            let point = gesture.location(in: imageView)
            let targetScale = min(scrollView.minimumZoomScale * 3, scrollView.maximumZoomScale)
            let size = CGSize(width: scrollView.bounds.width / targetScale, height: scrollView.bounds.height / targetScale)
            let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
            scrollView.zoom(to: CGRect(origin: origin, size: size), animated: true)
        }
    }
}

/// `layoutSubviews()`를 오버라이드해야 스크롤뷰 크기가 확정되는 시점(최초 표시,
/// 회전)에 맞춰 `centerImage()`를 다시 부를 수 있다 -- `UIViewRepresentable`의
/// `updateUIView`만으로는 이 타이밍을 못 잡는다.
private final class ZoomScrollView: UIScrollView {
    override func layoutSubviews() {
        super.layoutSubviews()
        (delegate as? ZoomableImageView.Coordinator)?.centerImage()
    }
}

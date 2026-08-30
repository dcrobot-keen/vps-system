import SwiftUI
import UIKit

/// 캡처된 사진을 전체화면으로 스와이프해서 넘겨보고, 각 사진은 핀치/더블탭으로
/// 확대해서 볼 수 있다. 썸네일 그리드는 90pt짜리라 얼굴 모자이크(deface,
/// FaceRedactor)가 실제로 적용됐는지 확인하기엔 너무 작아서 추가됨.
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
                    ZoomableImageView(url: url)
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

        // ThumbnailView와 같은 배경 로드 패턴 -- 원본 해상도 JPEG 디코딩을 메인
        // 스레드에서 하지 않는다.
        DispatchQueue.global(qos: .userInitiated).async {
            let image = UIImage(contentsOfFile: url.path)
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

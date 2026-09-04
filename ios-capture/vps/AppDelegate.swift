import UIKit

/// 순수 SwiftUI 라이프사이클(`@main App`)엔 백그라운드 URLSession 이벤트를 받을 방법이
/// 없다 -- `application(_:handleEventsForBackgroundURLSession:completionHandler:)`는
/// `UIApplicationDelegate`에만 있는 콜백이다. 이 앱 유일의 AppDelegate라 이 파일 하나로
/// 충분하고, `DCVPSCaptureApp`이 `@UIApplicationDelegateAdaptor`로 붙인다.
///
/// 이 콜백은 VPS 업로드(`VPSUploadClient`, 백그라운드 세션)가 앱이 종료된 채로도
/// 이어지다 완료/실패했을 때 iOS가 앱을 잠깐 다시 띄우면서 불러준다.
/// completionHandler를 곧바로 실행하면 안 되고, `VPSUploadClient`의 세션 델리게이트가
/// 그 세션의 모든 이벤트를 다 받은 뒤(`urlSessionDidFinishEvents(forBackgroundURLSession:)`)
/// 호출해야 한다(Apple 권장 순서) -- 그래서 클로저 자체를 `VPSUploadClient`에 넘겨서
/// 보관하게 한다.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        VPSUploadClient.backgroundSessionCompletionHandler = completionHandler
        // 세션(lazy static)을 지금 강제로 만들어야 iOS가 앱이 죽어있는 동안 끝난
        // 태스크들의 델리게이트 이벤트를 실제로 흘려보내 준다 -- reconnectBackgroundSessionIfNeeded
        // 주석 참고.
        VPSUploadClient.reconnectBackgroundSessionIfNeeded()
    }
}

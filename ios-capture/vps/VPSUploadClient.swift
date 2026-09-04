import Foundation
import os

private let logger = Logger(subsystem: "com.dcrobot.scanmesh", category: "VPSUploadClient")

/// scan_<name>/ 폴더를 압축한 zip을 VPS 서버의 `POST /scans`에 올리고, `GET
/// /scans/{scan_name}`으로 완료까지 폴링한다. 이 앱의 첫 네트워킹 코드 -- 별도
/// 라이브러리 없이 URLSession만 쓴다.
///
/// **업로드는 진짜 백그라운드 URLSession**(`URLSessionConfiguration.background`)을
/// 쓴다 -- 스캔이 1~2GB일 수 있어 업로드에 몇 분씩 걸리는데, 이 세션이 아니면 앱을
/// 백그라운드로 보내는 순간(또는 iOS가 앱을 종료하는 순간) 전송이 끊긴다. 백그라운드
/// 세션은 completion handler 기반 API를 아예 못 쓰게 막혀 있어서(델리게이트로만 결과를
/// 받을 수 있음), 이 부분만 델리게이트 기반으로 짜고 나머지(상태 폴링, `fetchStatus`)는
/// 기존처럼 완료 콜백 기반 foreground 세션을 그대로 쓴다 -- 배경 세션은 애초에
/// dataTask를 지원하지 않는다(업로드/다운로드 태스크만 됨).
///
/// **이 환경(Windows, Xcode/실기기 없음)에서 검증 못 한 부분**: 앱을 실제로
/// 백그라운드로 보내거나 종료한 뒤 iOS가 `handleEventsForBackgroundURLSession`으로
/// 다시 깨우는 전체 흐름 자체. 컴파일과 정적 로직(델리게이트 라우팅, 결과 영속화)은
/// CI로 확인되지만, 실제 OS 레벨 백그라운드 동작은 실기기 확인이 필요하다
/// (PRODUCT-PLAN.md 참고).
enum VPSUploadClient {
    enum ClientError: LocalizedError {
        case invalidServerURL
        case invalidResponse
        case serverError(String)
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidServerURL: return "서버 주소가 올바르지 않습니다. 설정에서 확인해주세요."
            case .invalidResponse: return "서버 응답을 이해할 수 없습니다."
            case .serverError(let message): return message
            case .decodingFailed: return "서버 응답을 해석할 수 없습니다."
            }
        }
    }

    struct JobStatus: Decodable {
        let scan_name: String
        let status: String
        let room_id: String?
        let error: String?
    }

    /// 앱이 재시작돼도(백그라운드 세션이 다시 이 식별자로 이벤트를 붙여준다) 같은
    /// 세션으로 인식되도록 고정 문자열을 쓴다.
    private static let backgroundSessionIdentifier = "com.dcrobot.scanmesh.upload"

    /// `AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`가
    /// 여기 저장해두면, 백그라운드 세션의 모든 이벤트를 다 받은 뒤
    /// (`urlSessionDidFinishEvents(forBackgroundURLSession:)`) 호출한다. Apple이 권장하는
    /// 순서 -- 곧바로 호출하면 델리게이트 콜백이 아직 안 끝났는데 iOS가 백그라운드
    /// 실행 시간을 회수해갈 수 있다.
    static var backgroundSessionCompletionHandler: (() -> Void)?

    private static let delegate = UploadSessionDelegate()

    /// `AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`가
    /// 반드시 곧바로 호출해야 한다 -- `uploadSession`은 lazy static이라 그냥 두면
    /// completionHandler만 저장될 뿐 세션 자체는 재구성되지 않고, 그러면 앱이 죽어있는
    /// 동안 끝난 백그라운드 태스크들의 델리게이트 이벤트(그리고 그걸 다 받았다는
    /// `urlSessionDidFinishEvents`)가 영영 전달되지 않을 수 있다. Apple 문서가 권장하는
    /// "같은 식별자로 세션을 다시 만든다"를 이 한 줄로 강제한다.
    static func reconnectBackgroundSessionIfNeeded() {
        _ = uploadSession
    }

    /// 업로드 전용. 반드시 `uploadTask(with:fromFile:)`만 쓴다 -- 백그라운드 세션은
    /// completion handler가 있는 태스크 생성 메서드 자체를 지원하지 않는다.
    private static let uploadSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: backgroundSessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false // 사용자가 직접 누른 업로드라 미루지 않고 바로 시작
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    /// 상태 폴링 전용(짧은 GET, 배경에서 이어질 필요 없음) -- 배경 세션은 dataTask를
    /// 지원하지 않아 이쪽은 그대로 foreground 세션으로 둔다.
    private static let pollingSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        return URLSession(configuration: config)
    }()

    /// zip 파일을 서버에 업로드한다. 완료 콜백은 메인 스레드에서 호출된다 -- 단, 앱이
    /// 업로드 도중 종료됐다가 백그라운드 세션 이벤트로 다시 켜진 경우엔 이 클로저
    /// 자체가 이미 메모리에서 사라진 뒤라 호출되지 않는다. 그 경우 결과는
    /// `upload_status.json`(scan_<name>/ 안, `loadPersistedUploadOutcome` 참고)에
    /// 남는다 -- 호출부(ProjectDetailView)가 다음에 이 화면을 열 때 그걸 보고 이어받는다.
    static func upload(
        zipFileURL: URL, scanName: String, serverURL: URL, replace: Bool,
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard var components = URLComponents(url: serverURL.appendingPathComponent("scans"), resolvingAgainstBaseURL: false) else {
            DispatchQueue.main.async { completion(.failure(ClientError.invalidServerURL)) }
            return
        }
        components.queryItems = [
            URLQueryItem(name: "scan_name", value: scanName),
            URLQueryItem(name: "replace", value: replace ? "true" : "false"),
        ]
        guard let url = components.url else {
            DispatchQueue.main.async { completion(.failure(ClientError.invalidServerURL)) }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")

        let task = uploadSession.uploadTask(with: request, fromFile: zipFileURL)
        // taskDescription은 URLSession이 시스템 레벨로 들고 있어서, 앱이 통째로 재시작돼도
        // (in-memory 딕셔너리는 다 날아가도) 살아남는다 -- didCompleteWithError에서
        // 이 scanName으로 upload_status.json 경로를 찾는다.
        task.taskDescription = scanName
        delegate.register(task: task, onProgress: onProgress, completion: completion)
        task.resume()
    }

    /// job 상태를 한 번 조회한다. 폴링은 호출하는 쪽(ProjectDetailView)이
    /// 타이머/asyncAfter로 반복한다. 완료 콜백은 메인 스레드에서 호출된다.
    static func fetchStatus(
        scanName: String, serverURL: URL, completion: @escaping (Result<JobStatus, Error>) -> Void
    ) {
        let url = serverURL.appendingPathComponent("scans").appendingPathComponent(scanName)
        pollingSession.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                do {
                    let data = data ?? Data()
                    try checkStatus(data: data, response: response, expected: 200)
                    let status = try JSONDecoder().decode(JobStatus.self, from: data)
                    completion(.success(status))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    private static func checkStatus(data: Data, response: URLResponse?, expected: Int) throws {
        guard let httpResponse = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard httpResponse.statusCode == expected else {
            struct ErrorBody: Decodable { let detail: String }
            if let body = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                throw ClientError.serverError(body.detail)
            }
            throw ClientError.serverError("서버 오류 (HTTP \(httpResponse.statusCode))")
        }
    }

    // MARK: - 업로드 결과 영속화(앱이 재시작된 경우를 위함)

    struct PersistedUploadOutcome {
        /// "accepted"(서버가 202로 접수, 빌드 폴링을 이어서 해야 함) 또는
        /// "failed"(업로드 자체가 실패).
        let status: String
        let errorMessage: String?
    }

    private static func persistedUploadOutcomeURL(projectURL: URL) -> URL {
        projectURL.appendingPathComponent("upload_status.json")
    }

    /// `fileprivate` -- `UploadSessionDelegate`(같은 파일, 다른 타입)가 완료 콜백이
    /// 이미 사라진 경우(앱 재시작)에 호출해야 해서 `private`로는 안 된다(Swift의
    /// `private`는 같은 타입/그 확장에서만 보임, 같은 파일의 다른 타입에서는 안 보임).
    fileprivate static func persistUploadOutcome(scanName: String, result: Result<Void, Error>) {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let projectURL = documentsDir.appendingPathComponent("scan_\(scanName)")
        var dict: [String: Any] = [:]
        switch result {
        case .success:
            dict["status"] = "accepted"
        case .failure(let error):
            dict["status"] = "failed"
            dict["error"] = error.localizedDescription
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: persistedUploadOutcomeURL(projectURL: projectURL))
        logger.notice("백그라운드 업로드 결과 영속화됨: \(scanName, privacy: .public) -> \(dict["status"] as? String ?? "?", privacy: .public)")
    }

    /// `ProjectDetailView.onAppear`가 호출해서, 이 화면이 꺼져 있는 동안(또는 앱이
    /// 재시작되는 동안) 업로드가 끝났는지 확인한다. 있으면 반드시 `clearPersistedUploadOutcome`로
    /// 지워야 다음에 또 같은 걸로 오해하지 않는다.
    static func loadPersistedUploadOutcome(projectURL: URL) -> PersistedUploadOutcome? {
        guard let data = try? Data(contentsOf: persistedUploadOutcomeURL(projectURL: projectURL)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String
        else { return nil }
        return PersistedUploadOutcome(status: status, errorMessage: json["error"] as? String)
    }

    static func clearPersistedUploadOutcome(projectURL: URL) {
        try? FileManager.default.removeItem(at: persistedUploadOutcomeURL(projectURL: projectURL))
    }
}

/// 백그라운드 업로드 세션의 진행률/완료를 처리한다. 완료 시점에 앱이 계속 살아있었으면
/// (in-memory 클로저가 아직 등록돼 있으면) 그걸 그대로 부르고, 앱이 그 사이 재시작된
/// 경우(클로저가 없음)에는 `task.taskDescription`(scanName)으로 결과를 디스크에 남긴다.
private final class UploadSessionDelegate: NSObject, URLSessionDataDelegate {
    private struct PendingUpload {
        var onProgress: ((Double) -> Void)?
        var completion: ((Result<Void, Error>) -> Void)?
        var responseData = Data()
    }

    private var pending: [Int: PendingUpload] = [:]
    private let lock = NSLock()

    func register(task: URLSessionTask, onProgress: @escaping (Double) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock()
        pending[task.taskIdentifier] = PendingUpload(onProgress: onProgress, completion: completion)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        lock.lock()
        let onProgress = pending[task.taskIdentifier]?.onProgress
        lock.unlock()
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        DispatchQueue.main.async { onProgress?(fraction) }
    }

    /// 업로드 태스크의 응답 본문(성공 시엔 안 쓰지만, 실패 시 서버가 돌려주는
    /// {"detail": "..."} 에러 메시지를 읽으려면 필요)도 배경 세션에서는 completion
    /// handler가 아니라 이 델리게이트로만 온다.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        pending[dataTask.taskIdentifier]?.responseData.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let entry = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        let result = Self.result(for: task, error: error, responseData: entry?.responseData ?? Data())

        if let completion = entry?.completion {
            DispatchQueue.main.async { completion(result) }
        } else if let scanName = task.taskDescription {
            // 앱이 재시작된 경우 -- 원래 completion 클로저는 이미 사라졌다.
            VPSUploadClient.persistUploadOutcome(scanName: scanName, result: result)
        }
    }

    /// 이 세션에 대한 모든 델리게이트 이벤트가 끝났다는 뜻 -- Apple 문서 권장대로,
    /// AppDelegate가 보관해둔 completion handler를 이제서야 호출한다(너무 일찍
    /// 부르면 위 콜백들이 아직 안 끝났는데 iOS가 백그라운드 실행 시간을 회수해갈 수
    /// 있다).
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            VPSUploadClient.backgroundSessionCompletionHandler?()
            VPSUploadClient.backgroundSessionCompletionHandler = nil
        }
    }

    private static func result(for task: URLSessionTask, error: Error?, responseData: Data) -> Result<Void, Error> {
        if let error {
            return .failure(error)
        }
        guard let httpResponse = task.response as? HTTPURLResponse else {
            return .failure(VPSUploadClient.ClientError.invalidResponse)
        }
        guard httpResponse.statusCode == 202 else {
            struct ErrorBody: Decodable { let detail: String }
            if let body = try? JSONDecoder().decode(ErrorBody.self, from: responseData) {
                return .failure(VPSUploadClient.ClientError.serverError(body.detail))
            }
            return .failure(VPSUploadClient.ClientError.serverError("서버 오류 (HTTP \(httpResponse.statusCode))"))
        }
        return .success(())
    }
}

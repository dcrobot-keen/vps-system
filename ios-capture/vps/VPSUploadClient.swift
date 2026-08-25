import Foundation

/// scan_<name>/ 폴더를 압축한 zip을 VPS 서버의 `POST /scans`에 올리고, `GET
/// /scans/{scan_name}`으로 완료까지 폴링한다. 이 앱의 첫 네트워킹 코드 -- 별도
/// 라이브러리 없이 URLSession만 쓴다.
///
/// completion-handler 기반 API로 짠다(async/await 아님) -- 이 앱의 다른 백그라운드
/// 작업(TextureBaker.bake, ProjectStore.exportZip)이 전부 DispatchQueue.global +
/// DispatchQueue.main.async 조합이라, 같은 관용구를 쓰는 호출부(ProjectDetailView)와
/// 자연스럽게 맞물리고 actor-isolation 관련 불확실성도 없다(이 환경에서 컴파일
/// 검증이 안 되므로 검증된 패턴을 그대로 따르는 쪽이 안전하다).
///
/// multipart가 아니라 raw body(Content-Type: application/zip)로 올린다 -- 서버도
/// 그렇게 받게 만들었다(server/app/main.py). 스캔이 1~2GB일 수 있어서
/// `uploadTask(with:fromFile:)`로 디스크에서 바로 스트리밍하고(메모리에 전체를 안
/// 올림), 첫 네트워크 호출을 멀티파트 손구현으로 시작하는 위험도 피한다.
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

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // 업로드가 몇 분씩 걸릴 수 있어서(1~2GB, Wi-Fi/Tailscale) 여유 있게 잡는다.
        // timeoutIntervalForResource는 기본값(7일)이 이미 충분히 넉넉해서 안 건드림.
        config.timeoutIntervalForRequest = 120
        return URLSession(configuration: config, delegate: ProgressForwarder.shared, delegateQueue: nil)
    }()

    /// zip 파일을 서버에 업로드한다. 완료 콜백은 메인 스레드에서 호출된다. 202를
    /// 받으면 서버가 빌드를 시작한 것 -- 완료 여부는 `fetchStatus`로 따로 폴링해야
    /// 한다. `onProgress`도 메인 스레드에서 0...1 값으로 호출된다.
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

        let task = session.uploadTask(with: request, fromFile: zipFileURL) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                do {
                    try checkStatus(data: data ?? Data(), response: response, expected: 202)
                    completion(.success(()))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        ProgressForwarder.shared.register(task: task, onProgress: onProgress)
        task.resume()
    }

    /// job 상태를 한 번 조회한다. 폴링은 호출하는 쪽(ProjectDetailView)이
    /// 타이머/asyncAfter로 반복한다. 완료 콜백은 메인 스레드에서 호출된다.
    static func fetchStatus(
        scanName: String, serverURL: URL, completion: @escaping (Result<JobStatus, Error>) -> Void
    ) {
        let url = serverURL.appendingPathComponent("scans").appendingPathComponent(scanName)
        session.dataTask(with: url) { data, response, error in
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
}

/// 업로드 진행률(didSendBodyData)만 뽑아서 등록된 콜백으로 넘겨주는 세션 델리게이트.
/// 세션 하나를 여러 업로드에 재사용하므로(한 번에 하나만 업로드한다는 서버 쪽
/// 설계와도 맞음) task별로 콜백을 매핑해둔다.
private final class ProgressForwarder: NSObject, URLSessionTaskDelegate {
    static let shared = ProgressForwarder()

    private var callbacks: [Int: (Double) -> Void] = [:]
    private let lock = NSLock()

    func register(task: URLSessionTask, onProgress: @escaping (Double) -> Void) {
        lock.lock()
        callbacks[task.taskIdentifier] = onProgress
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        lock.lock()
        let callback = callbacks[task.taskIdentifier]
        lock.unlock()
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        DispatchQueue.main.async { callback?(fraction) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        callbacks.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
    }
}

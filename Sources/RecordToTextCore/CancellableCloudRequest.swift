import Foundation

/// Owns the concrete task until completion or cancellation. The continuation
/// has a single winner even when URLProtocol/provider callbacks arrive late.
final class CancellableCloudRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var result: Result<(Data, URLResponse), Error>?

    func run(session: URLSession, request: URLRequest, fileURL: URL?) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let prior = lock.withLock { () -> Result<(Data, URLResponse), Error>? in
                    if let result { return result }
                    self.continuation = continuation
                    return nil
                }
                if let prior { continuation.resume(with: prior); return }
                let callback: @Sendable (Data?, URLResponse?, Error?) -> Void = { [self] data, response, error in
                    if let error { finish(.failure(error)) }
                    else if let response { finish(.success((data ?? Data(), response))) }
                    else { finish(.failure(URLError(.badServerResponse))) }
                }
                let task: URLSessionTask
                if let fileURL { task = session.uploadTask(with: request, fromFile: fileURL, completionHandler: callback) }
                else { task = session.dataTask(with: request, completionHandler: callback) }
                let cancelled = lock.withLock { () -> Bool in
                    guard result == nil else { return true }
                    self.task = task
                    return false
                }
                if cancelled { task.cancel() }
                else { task.resume() }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()), cancel: true)
        }
    }
    private func finish(_ value: Result<(Data, URLResponse), Error>, cancel: Bool = false) {
        let pending = lock.withLock { () -> (URLSessionTask?, CheckedContinuation<(Data, URLResponse), Error>?) in
            guard result == nil else { return (nil, nil) }
            result = value
            let pending = (task, continuation)
            task = nil; continuation = nil
            return pending
        }
        if cancel { pending.0?.cancel() }
        pending.1?.resume(with: value)
    }
}

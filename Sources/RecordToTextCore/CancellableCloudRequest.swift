import Foundation

/// Owns the concrete task until completion or cancellation. The continuation
/// has a single winner even when URLProtocol/provider callbacks arrive late.
final class CancellableCloudRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var result: Result<(Data, URLResponse), Error>?
    private var connectivity: CloudConnectivityDelegate?

    func run(session: URLSession, request: URLRequest, fileURL: URL?, attempts: CloudRequestAttempts? = nil) async throws -> (Data, URLResponse) {
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
                let delegate: CloudConnectivityDelegate?
                if let context = CloudNetworkContext.current, session.configuration.waitsForConnectivity {
                    delegate = CloudConnectivityDelegate(context: context) { [weak self] error in
                        self?.finish(.failure(error), cancel: true)
                    }
                    task.delegate = delegate
                } else { delegate = nil }
                let cancelled = lock.withLock { () -> Bool in
                    guard result == nil else { return true }
                    self.task = task
                    self.connectivity = delegate
                    return false
                }
                if cancelled { task.cancel() }
                else {
                    let stage: CloudDiagnosticStage = request.url?.absoluteString.contains("generateContent") == true
                        ? .generation : CloudBudgetContext.current.flatMap { .init(rawValue: $0.stage) } ?? .upload
                    do {
                        try Task.checkCancellation()
                        if let attempts { try attempts.claim() }
                        else if stage == .generation { try CloudNetworkContext.generation?.claim() }
                    } catch { task.cancel(); finish(.failure(error)); return }
                    CloudDiagnosticContext.current?.requestStarted(stage: stage)
                    task.resume()
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()), cancel: true)
        }
    }
    private func finish(_ value: Result<(Data, URLResponse), Error>, cancel: Bool = false) {
        let pending = lock.withLock { () -> (URLSessionTask?, CheckedContinuation<(Data, URLResponse), Error>?, CloudConnectivityDelegate?) in
            guard result == nil else { return (nil, nil, nil) }
            result = value
            let pending = (task, continuation, connectivity)
            task = nil; continuation = nil; connectivity = nil
            return pending
        }
        if cancel { pending.0?.cancel() }
        pending.2?.stop()
        pending.1?.resume(with: value)
    }
}

final class CloudConnectivityDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let context: CloudNetworkRecoveryContext
    private let fail: @Sendable (Error) -> Void
    private let lock = NSRecursiveLock()
    private var waitID: UUID?
    private var monitor: Task<Void, Never>?
    private var stopped = false
    init(context: CloudNetworkRecoveryContext, fail: @escaping @Sendable (Error) -> Void) {
        self.context = context; self.fail = fail
    }
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        lock.withLock {
            guard !stopped, waitID == nil else { return }
            waitID = context.beginWait()
            context.publish(.waiting)
            monitor = Task { [weak self] in
                while let self, !Task.isCancelled {
                    do {
                        try self.context.check()
                        self.context.publish(.waiting)
                        try await Task.sleep(for: .milliseconds(100))
                    } catch is CancellationError { return }
                    catch { self.fail(error); return }
                }
            }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesSent > 0 { stop(connected: true) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        stop()
    }
    func stop(connected: Bool = false) {
        let pending = lock.withLock { () -> (UUID?, Task<Void, Never>?) in
            stopped = true
            let result = (waitID, monitor)
            waitID = nil; monitor = nil
            return result
        }
        pending.1?.cancel()
        if let id = pending.0 {
            context.endWait(id)
            if connected { context.publish(.resolved) }
        }
    }
}

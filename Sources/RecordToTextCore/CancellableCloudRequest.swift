import Foundation

/// Owns the concrete task until completion or cancellation. The continuation
/// has a single winner even when URLProtocol/provider callbacks arrive late.
final class CancellableCloudRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var result: Result<(Data, URLResponse), Error>?
    private var delegate: CloudRequestTaskDelegate?

    func run(
        session: URLSession,
        request: URLRequest,
        fileURL: URL?,
        stage: CloudDiagnosticStage? = nil,
        responseMode: CloudResponseMode = .unaryJSON,
        streamingLimits: GeminiStreamingLimits = .default,
        attempts: CloudRequestAttempts? = nil
    ) async throws -> (Data, URLResponse) {
        let resolvedStage: CloudDiagnosticStage
        if let stage {
            resolvedStage = stage
        } else if request.url?.absoluteString.lowercased().contains("generatecontent") == true {
            resolvedStage = .generation
        } else {
            resolvedStage = CloudBudgetContext.current.flatMap { .init(rawValue: $0.stage) } ?? .upload
        }
        let networkContext = CloudNetworkContext.current
        let diagnosticCollector = CloudDiagnosticContext.current
        let generationQuota = CloudNetworkContext.generation

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let prior = lock.withLock { () -> Result<(Data, URLResponse), Error>? in
                    if let result { return result }
                    self.continuation = continuation
                    return nil
                }
                if let prior { continuation.resume(with: prior); return }

                let task: URLSessionTask
                if let fileURL {
                    task = session.uploadTask(with: request, fromFile: fileURL)
                } else {
                    task = session.dataTask(with: request)
                }

                let taskDelegate = CloudRequestTaskDelegate(
                    stage: resolvedStage,
                    responseMode: responseMode,
                    streamingLimits: streamingLimits,
                    context: networkContext,
                    collector: diagnosticCollector,
                    trackConnectivityWait: session.configuration.waitsForConnectivity
                ) { [weak self] outcome, cancelTask in
                    self?.finish(outcome, cancel: cancelTask)
                }
                task.delegate = taskDelegate

                let cancelled = lock.withLock { () -> Bool in
                    guard result == nil else { return true }
                    self.task = task
                    self.delegate = taskDelegate
                    return false
                }
                if cancelled {
                    task.cancel()
                    taskDelegate.stop()
                } else {
                    let activeQuota = attempts ?? (resolvedStage == .generation ? generationQuota : nil)
                    let sendSequence: Int?
                    do {
                        try Task.checkCancellation()
                        if let activeQuota {
                            try activeQuota.claim()
                            sendSequence = activeQuota.count
                        } else {
                            sendSequence = nil
                        }
                    } catch {
                        task.cancel()
                        finish(.failure(error))
                        return
                    }
                    networkContext?.setReceivingResponse(false)
                    diagnosticCollector?.requestStarted(
                        stage: resolvedStage,
                        responseMode: responseMode,
                        sendSequence: sendSequence
                    )
                    task.resume()
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()), cancel: true)
        }
    }

    private func finish(_ value: Result<(Data, URLResponse), Error>, cancel: Bool = false) {
        let pending = lock.withLock { () -> (URLSessionTask?, CheckedContinuation<(Data, URLResponse), Error>?, CloudRequestTaskDelegate?) in
            guard result == nil else { return (nil, nil, nil) }
            result = value
            let pending = (task, continuation, delegate)
            task = nil; continuation = nil; delegate = nil
            return pending
        }
        if cancel { pending.0?.cancel() }
        pending.2?.stop(cancelled: cancel)
        pending.1?.resume(with: value)
    }
}

final class CloudRequestTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let stage: CloudDiagnosticStage
    private let responseMode: CloudResponseMode
    private let streamingLimits: GeminiStreamingLimits
    private let context: CloudNetworkRecoveryContext?
    private let collector: CloudDiagnosticCollector?
    private let trackConnectivityWait: Bool
    private let onComplete: @Sendable (Result<(Data, URLResponse), Error>, Bool) -> Void
    private let lock = NSRecursiveLock()
    private let startedAt: ContinuousClock.Instant

    private var waitID: UUID?
    private var monitor: Task<Void, Never>?
    private var connectivityStopped = false
    private var finished = false

    private var receivedResponse: URLResponse?
    private var rawData = Data()
    private var accumulator: GeminiStreamingResponseAccumulator?

    private var uploadCompletedSeconds: Double?
    private var firstResponseByteSeconds: Double?
    private var firstTextDeltaSeconds: Double?
    private var completedSeconds: Double?
    private var receivedByteCount = 0
    private var networkProtocol: String?
    private var usedProxy: Bool?

    convenience init(context: CloudNetworkRecoveryContext, fail: @escaping @Sendable (Error) -> Void) {
        self.init(
            stage: .generation,
            responseMode: .unaryJSON,
            streamingLimits: .default,
            context: context,
            collector: nil,
            trackConnectivityWait: true
        ) { outcome, _ in
            if case let .failure(error) = outcome {
                fail(error)
            }
        }
    }

    init(
        stage: CloudDiagnosticStage,
        responseMode: CloudResponseMode,
        streamingLimits: GeminiStreamingLimits,
        context: CloudNetworkRecoveryContext?,
        collector: CloudDiagnosticCollector?,
        trackConnectivityWait: Bool,
        onComplete: @escaping @Sendable (Result<(Data, URLResponse), Error>, Bool) -> Void
    ) {
        self.stage = stage
        self.responseMode = responseMode
        self.streamingLimits = streamingLimits
        self.context = context
        self.collector = collector
        self.trackConnectivityWait = trackConnectivityWait
        self.onComplete = onComplete
        self.startedAt = context?.environment.now() ?? .now
        super.init()
        if responseMode == .geminiSSE {
            self.accumulator = GeminiStreamingResponseAccumulator(limits: streamingLimits) { [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    if self.firstTextDeltaSeconds == nil {
                        self.firstTextDeltaSeconds = self.elapsedSeconds()
                    }
                }
            }
        }
    }

    private func now() -> ContinuousClock.Instant {
        context?.environment.now() ?? .now
    }

    private func elapsedSeconds() -> Double {
        max(0, startedAt.duration(to: now()).secondsValue)
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        guard trackConnectivityWait, let context else { return }
        lock.withLock {
            guard !connectivityStopped, !finished, waitID == nil else { return }
            waitID = context.beginWait()
            context.publish(.waiting)
            monitor = Task { [weak self] in
                while let self, !Task.isCancelled {
                    do {
                        try context.check()
                        context.publish(.waiting)
                        try await Task.sleep(for: .milliseconds(100))
                    } catch is CancellationError { return }
                    catch {
                        self.flushDiagnostics(completed: true)
                        self.onComplete(.failure(error), true)
                        return
                    }
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        if totalBytesSent > 0 {
            stopConnectivityWait(connected: true)
        }
        lock.withLock {
            guard !finished else { return }
            if totalBytesExpectedToSend > 0, totalBytesSent >= totalBytesExpectedToSend {
                uploadCompletedSeconds = elapsedSeconds()
            } else if uploadCompletedSeconds == nil, totalBytesSent > 0 {
                uploadCompletedSeconds = elapsedSeconds()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        stopConnectivityWait(connected: true)
        lock.withLock {
            guard !finished else { return }
            receivedResponse = response
            if let http = response as? HTTPURLResponse {
                collector?.updateCurrentAttempt(httpStatus: http.statusCode)
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stopConnectivityWait(connected: true)
        let failureToReport: Error? = lock.withLock {
            guard !finished else { return nil }
            if receivedResponse == nil {
                receivedResponse = dataTask.response
            }
            if !data.isEmpty {
                receivedByteCount += data.count
                if firstResponseByteSeconds == nil {
                    firstResponseByteSeconds = elapsedSeconds()
                    if stage == .generation {
                        context?.setReceivingResponse(true)
                    }
                }
            }

            let httpStatus = (receivedResponse as? HTTPURLResponse)?.statusCode ?? 200
            if responseMode == .geminiSSE, (200..<300).contains(httpStatus) {
                do {
                    try accumulator?.append(data)
                    return nil
                } catch var streamError as GeminiStreamServerError {
                    streamError.httpResponse = receivedResponse as? HTTPURLResponse
                    completedSeconds = elapsedSeconds()
                    flushDiagnosticsLocked()
                    finished = true
                    accumulator = nil
                    rawData.removeAll(keepingCapacity: false)
                    return streamError
                } catch {
                    completedSeconds = elapsedSeconds()
                    flushDiagnosticsLocked()
                    finished = true
                    accumulator = nil
                    rawData.removeAll(keepingCapacity: false)
                    return error
                }
            } else {
                if responseMode != .rawData, receivedByteCount > streamingLimits.maxTotalResponseBytes {
                    let limitError = GeminiSSEError.totalResponseTooLarge(
                        limitBytes: streamingLimits.maxTotalResponseBytes
                    )
                    completedSeconds = elapsedSeconds()
                    flushDiagnosticsLocked()
                    finished = true
                    rawData.removeAll(keepingCapacity: false)
                    return limitError
                }
                rawData.append(data)
                return nil
            }
        }

        if let failureToReport {
            context?.setReceivingResponse(false)
            onComplete(.failure(failureToReport), true)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        stopConnectivityWait()
        lock.withLock {
            if let lastTx = metrics.transactionMetrics.last {
                if let proto = lastTx.networkProtocolName, !proto.isEmpty {
                    networkProtocol = proto
                }
                usedProxy = lastTx.isProxyConnection
            }
            collector?.updateCurrentAttempt(
                networkProtocol: networkProtocol,
                usedProxy: usedProxy
            )
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stopConnectivityWait()
        context?.setReceivingResponse(false)
        let outcome: Result<(Data, URLResponse), Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            if receivedResponse == nil {
                receivedResponse = task.response
            }
            completedSeconds = elapsedSeconds()

            if let error {
                flushDiagnosticsLocked()
                accumulator = nil
                rawData.removeAll(keepingCapacity: false)
                return .failure(error)
            }

            guard let response = receivedResponse else {
                flushDiagnosticsLocked()
                accumulator = nil
                rawData.removeAll(keepingCapacity: false)
                return .failure(URLError(.badServerResponse))
            }

            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 200
            if responseMode == .geminiSSE, (200..<300).contains(httpStatus) {
                guard let currentAccumulator = accumulator else {
                    flushDiagnosticsLocked()
                    return .failure(CloudIncompleteStreamError())
                }
                do {
                    let finalData = try currentAccumulator.finishData(httpStatusCode: httpStatus)
                    flushDiagnosticsLocked()
                    accumulator = nil
                    return .success((finalData, response))
                } catch var streamError as GeminiStreamServerError {
                    streamError.httpResponse = response as? HTTPURLResponse
                    flushDiagnosticsLocked()
                    accumulator = nil
                    return .failure(streamError)
                } catch {
                    flushDiagnosticsLocked()
                    accumulator = nil
                    return .failure(error)
                }
            } else {
                let data = rawData
                flushDiagnosticsLocked()
                rawData.removeAll(keepingCapacity: false)
                accumulator = nil
                return .success((data, response))
            }
        }

        if let outcome {
            onComplete(outcome, false)
        }
    }

    func stop(connected: Bool = false, cancelled: Bool = false) {
        stopConnectivityWait(connected: connected)
        context?.setReceivingResponse(false)
        lock.withLock {
            if cancelled, !finished {
                completedSeconds = elapsedSeconds()
                flushDiagnosticsLocked()
            }
            finished = true
            accumulator = nil
            rawData.removeAll(keepingCapacity: false)
        }
    }

    private func flushDiagnostics(completed: Bool = false) {
        lock.withLock {
            if completed, completedSeconds == nil {
                completedSeconds = elapsedSeconds()
            }
            flushDiagnosticsLocked()
        }
    }

    private func flushDiagnosticsLocked() {
        let httpStatus = (receivedResponse as? HTTPURLResponse)?.statusCode
        let sseEvents = responseMode == .geminiSSE ? (accumulator?.sseEventCount ?? 0) : nil
        let finishReason = accumulator?.finishReason
        collector?.updateCurrentAttempt(
            httpStatus: httpStatus,
            finishReason: finishReason,
            uploadCompletedSeconds: uploadCompletedSeconds,
            firstResponseByteSeconds: firstResponseByteSeconds,
            firstTextDeltaSeconds: firstTextDeltaSeconds,
            completedSeconds: completedSeconds,
            receivedByteCount: receivedByteCount,
            sseEventCount: sseEvents,
            networkProtocol: networkProtocol,
            usedProxy: usedProxy
        )
    }

    private func stopConnectivityWait(connected: Bool = false) {
        let pending = lock.withLock { () -> (UUID?, Task<Void, Never>?) in
            connectivityStopped = true
            let result = (waitID, monitor)
            waitID = nil; monitor = nil
            return result
        }
        pending.1?.cancel()
        if let id = pending.0, let context {
            context.endWait(id)
            if connected { context.publish(.resolved) }
        }
    }
}

typealias CloudConnectivityDelegate = CloudRequestTaskDelegate

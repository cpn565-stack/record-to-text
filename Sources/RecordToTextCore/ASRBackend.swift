import Foundation

public enum HelperInactivityPolicy {
    public static let warningTimeout: TimeInterval = 30

    public static func hardTimeout(for request: ASRRequest) -> TimeInterval {
        let modelMultiplier: Double
        if request.modelID.contains("1.7B-bf16") {
            modelMultiplier = 5
        } else if request.modelID.contains("1.7B") {
            modelMultiplier = 4
        } else {
            modelMultiplier = 3
        }
        return min(
            max(5 * 60, request.chunkDurationSeconds * modelMultiplier),
            20 * 60
        )
    }
}

public struct ASRRequest: Codable, Equatable, Sendable {
    /// Internal MLX generate() window inside each coordinator segment. Dense
    /// meetings can fill 16k tokens in a few minutes; the helper also
    /// auto-splits further when a chunk hits the token cap.
    public static let defaultChunkDurationSeconds: Double = 120
    public static let defaultMaximumTokens = 16_384

    public let jobID: String
    public let audioPath: String
    public let outputPath: String
    public let modelID: String
    public let modelRevision: String?
    public let language: String
    public let prompt: String
    public let terms: [String]
    public let modelCacheDirectory: String
    public let offline: Bool
    public let allowMissingPrompt: Bool
    public let maximumTokens: Int
    public let chunkDurationSeconds: Double
    public let segmentIndex: Int
    public let segmentCount: Int
    public let chunkCheckpointDirectory: String?
    /// Start of this segment in the original recording (optional for older requests).
    public let timeOffsetSeconds: Double?
    /// v2 checkpoint coordinates. A single optional block keeps the contract
    /// all-or-nothing: a helper either gets every coordinate or none, so it can
    /// never half-adopt v2 and fall back to guessing.
    public let checkpointV2: ASRCheckpointV2?

    public init(
        jobID: String,
        audioPath: String,
        outputPath: String,
        modelID: String,
        modelRevision: String? = nil,
        language: String,
        prompt: String,
        terms: [String],
        modelCacheDirectory: String,
        offline: Bool,
        allowMissingPrompt: Bool = false,
        maximumTokens: Int = ASRRequest.defaultMaximumTokens,
        chunkDurationSeconds: Double = ASRRequest.defaultChunkDurationSeconds,
        segmentIndex: Int = 1,
        segmentCount: Int = 1,
        chunkCheckpointDirectory: String? = nil,
        timeOffsetSeconds: Double? = nil,
        checkpointV2: ASRCheckpointV2? = nil
    ) {
        self.jobID = jobID
        self.audioPath = audioPath
        self.outputPath = outputPath
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.language = language
        self.prompt = prompt
        self.terms = terms
        self.modelCacheDirectory = modelCacheDirectory
        self.offline = offline
        self.allowMissingPrompt = allowMissingPrompt
        self.maximumTokens = maximumTokens
        self.chunkDurationSeconds = chunkDurationSeconds
        self.segmentIndex = segmentIndex
        self.segmentCount = segmentCount
        self.chunkCheckpointDirectory = chunkCheckpointDirectory
        self.timeOffsetSeconds = timeOffsetSeconds
        self.checkpointV2 = checkpointV2
    }
}

/// Coordinates binding one helper invocation to a frozen v2 checkpoint plan.
///
/// All sample values are absolute indices in *original recording* space at
/// `sampleRate`, so a display timestamp is simply `sample / sampleRate` with no
/// offset — `timeOffsetSeconds` must never be used for that, since it also
/// carries the per-segment offset. The helper converts to array indices with
/// `absoluteSample - audioStartSample` and never re-derives boundaries from
/// `segmentIndex`.
public struct ASRCheckpointV2: Codable, Equatable, Sendable {
    public let directory: String
    public let rootID: String
    public let planID: String
    public let identityDigest: String
    public let sampleRate: Int64
    public let audioStartSample: Int64
    public let workStartSample: Int64
    public let workEndSample: Int64
    /// The channel the frozen identity says the prompt travelled in. The helper
    /// recomputes it from the loaded model and refuses to run on a mismatch, so
    /// glossary and no-glossary results are never mixed in one checkpoint.
    public let promptChannel: String

    public init(
        directory: String,
        rootID: String,
        planID: String,
        identityDigest: String,
        sampleRate: Int64,
        audioStartSample: Int64,
        workStartSample: Int64,
        workEndSample: Int64,
        promptChannel: String
    ) {
        self.directory = directory
        self.rootID = rootID
        self.planID = planID
        self.identityDigest = identityDigest
        self.sampleRate = sampleRate
        self.audioStartSample = audioStartSample
        self.workStartSample = workStartSample
        self.workEndSample = workEndSample
        self.promptChannel = promptChannel
    }
}

/// Prompt-channel names shared with the helper's `ALLOWED_PROMPT_CHANNELS`.
public enum LocalPromptChannel {
    public static let systemPrompt = "system_prompt"
    public static let context = "context"
    public static let none = "none"

    /// Mirrors `resolve_prompt_channel` in the helper, so the value Swift freezes
    /// is the one the helper will independently confirm.
    public static func resolve(
        prompt: String,
        capability: ASRCapability
    ) -> String {
        if !prompt.isEmpty, capability.supportsSystemPrompt {
            return systemPrompt
        }
        if !prompt.isEmpty, capability.supportsContext {
            return context
        }
        return none
    }
}

/// What the helper reports about the interpreter it is about to run in.
///
/// These fields are part of the frozen inference identity and cannot be derived
/// on the Swift side: the prompt channels come from reading the installed model
/// source, and the versions from the helper's own package metadata.
public struct ASRRuntimeReport: Equatable, Sendable {
    public let asrContractVersion: String
    public let supportsSystemPrompt: Bool
    public let supportsContext: Bool
    public let mlxVersion: String?
    public let mlxAudioVersion: String?

    public init(
        asrContractVersion: String,
        supportsSystemPrompt: Bool,
        supportsContext: Bool,
        mlxVersion: String?,
        mlxAudioVersion: String?
    ) {
        self.asrContractVersion = asrContractVersion
        self.supportsSystemPrompt = supportsSystemPrompt
        self.supportsContext = supportsContext
        self.mlxVersion = mlxVersion
        self.mlxAudioVersion = mlxAudioVersion
    }

    public var capability: ASRCapability {
        ASRCapability(
            supportsSystemPrompt: supportsSystemPrompt,
            supportsContext: supportsContext
        )
    }
}

private struct ASRRuntimeEventPayload: Decodable {
    let type: String
    let asrContractVersion: String?
    let supportsSystemPrompt: Bool?
    let supportsContext: Bool?
    let mlxVersion: String?
    let mlxAudioVersion: String?
    let message: String?
    let code: String?
}

public struct ASRCapability: Equatable, Sendable {
    public let supportsSystemPrompt: Bool
    public let supportsContext: Bool

    public init(supportsSystemPrompt: Bool, supportsContext: Bool) {
        self.supportsSystemPrompt = supportsSystemPrompt
        self.supportsContext = supportsContext
    }

    public var supportsGlossaryPrompt: Bool {
        supportsSystemPrompt || supportsContext
    }
}

public enum ASRBackendError: LocalizedError {
    case malformedEvent(String)
    case helperFailed(status: Int32, message: String, technicalDetails: String)
    case helperReported(message: String, code: String)
    case completedEventMissing
    case completedEventCount(Int)
    case completedPathMismatch(expected: String, actual: String)
    case outputMissing(String)
    case outputEmpty(String)
    case outputInvalidUTF8(String)
    case glossaryPromptUnsupported
    case helperTimedOut(timeout: TimeInterval)
    case runtimeReportFailed(String)
    case runtimeContractMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case let .malformedEvent(line):
            return "ASR Helper 回傳了無效事件：\(line)"
        case let .helperFailed(status, message, technicalDetails):
            let details = technicalDetails.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(message)（結束碼 \(status)）\(details.isEmpty ? "" : "：\(details)")"
        case let .helperReported(message, code):
            return "\(message)（錯誤碼 \(code)）"
        case .completedEventMissing:
            return "ASR Helper 未回報完成事件，結果不可信。"
        case let .completedEventCount(count):
            return "ASR Helper 回報了 \(count) 次完成事件，協定狀態不可信。"
        case let .completedPathMismatch(expected, actual):
            return "ASR Helper 回報了非預期輸出路徑。預期：\(expected)；收到：\(actual)"
        case let .outputMissing(path):
            return "ASR Helper 回報完成，但找不到原始逐字稿：\(path)"
        case let .outputEmpty(path):
            return "ASR Helper 已結束，但沒有辨識出可輸出的文字：\(path)"
        case let .outputInvalidUTF8(path):
            return "ASR Helper 產生的逐字稿不是有效的 UTF-8：\(path)"
        case .glossaryPromptUnsupported:
            return "目前後端不支援專有名詞提示。"
        case let .helperTimedOut(timeout):
            return "ASR Helper 已超過 \(String(format: "%.0f 分鐘", timeout / 60)) 沒有回報活動，已停止以避免工作無限卡住。"
        case let .runtimeReportFailed(underlying):
            return "無法取得本機 ASR runtime 身分，已停止（不建立 v2 checkpoint）：\(underlying)"
        case let .runtimeContractMismatch(expected, actual):
            return "本機 ASR Helper 的協定版本為 \(actual)，App 預期 \(expected)；請更新其中之一後再試。"
        }
    }
}

public struct ASRTranscriptionResult: Equatable, Sendable {
    public let capability: ASRCapability
    public let containsSkippedAudio: Bool

    public init(capability: ASRCapability, containsSkippedAudio: Bool) {
        self.capability = capability
        self.containsSkippedAudio = containsSkippedAudio
    }
}

private final class HelperEventState: @unchecked Sendable {
    private let lock = NSLock()
    private var completedPath: String?
    private var completedCount = 0
    private var errorMessage: String?
    private var errorCode: String?
    private var containsSkippedAudio = false
    private var capability: ASRCapability?

    func observe(_ event: HelperEvent) {
        lock.lock()
        defer { lock.unlock() }

        switch event.type {
        case "completed":
            completedPath = event.outputPath
            completedCount += 1
            containsSkippedAudio = event.containsSkippedAudio ?? false
        case "error":
            errorMessage = event.message
            errorCode = event.code
        case "capability":
            capability = ASRCapability(
                supportsSystemPrompt: event.supportsSystemPrompt ?? false,
                supportsContext: event.supportsContext ?? false
            )
        default:
            break
        }
    }

    func snapshot() -> (
        completedPath: String?,
        completedCount: Int,
        errorMessage: String?,
        errorCode: String?,
        containsSkippedAudio: Bool,
        capability: ASRCapability?
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            completedPath,
            completedCount,
            errorMessage,
            errorCode,
            containsSkippedAudio,
            capability
        )
    }
}

private final class PersistentASRHelperSession: @unchecked Sendable {
    private let runtime: ResolvedRuntime
    private let environment: [String: String]
    private let lock = NSLock()
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var requestContinuation: CheckedContinuation<Void, Error>?
    private var stdoutLineHandler: ((String) -> Bool)?
    private var stderrLineHandler: ((String) -> Void)?

    init(runtime: ResolvedRuntime, environment: [String: String]) {
        self.runtime = runtime
        self.environment = environment
    }

    /// Persistent sessions freeze the helper environment (HF cache, offline
    /// flags) at first use; a settings change must recycle the session.
    func matchesEnvironment(_ other: [String: String]) -> Bool {
        environment == other
    }

    deinit {
        stop()
    }

    func send(
        requestData: Data,
        inactivityTimeout: TimeInterval,
        stdoutLineHandler: @escaping (String) -> Bool,
        stderrLineHandler: @escaping (String) -> Void
    ) async throws {
        try startIfNeeded()

        let activity = HelperLivenessMonitor()
        let watchdogTask = Task { [weak self, weak activity] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                } catch {
                    return
                }
                guard let self, let activity else {
                    return
                }
                if activity.isInactive(timeout: inactivityTimeout) {
                    self.failActiveRequest(timeout: inactivityTimeout)
                    return
                }
            }
        }
        defer {
            watchdogTask.cancel()
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let acquired: Bool = lock.withLock {
                    guard requestContinuation == nil else {
                        return false
                    }
                    requestContinuation = continuation
                    self.stdoutLineHandler = { line in
                        activity.recordActivity()
                        return stdoutLineHandler(line)
                    }
                    self.stderrLineHandler = { line in
                        activity.recordActivity()
                        stderrLineHandler(line)
                    }
                    return true
                }

                guard acquired else {
                    // Reject this caller only; the in-flight request keeps its
                    // own continuation untouched.
                    continuation.resume(
                        throwing: ASRBackendError.helperFailed(
                            status: -1,
                            message: "ASR Helper 同時只能處理一個請求。",
                            technicalDetails: ""
                        )
                    )
                    return
                }

                let input: FileHandle? = lock.withLock { inputPipe?.fileHandleForWriting }
                guard let input else {
                    finishRequest(
                        with: ASRBackendError.helperFailed(
                            status: -1,
                            message: "ASR Helper 程序已結束，無法寫入請求。",
                            technicalDetails: ""
                        )
                    )
                    return
                }

                do {
                    try input.write(contentsOf: requestData)
                    try input.write(contentsOf: Data([0x0A]))
                } catch {
                    finishRequest(with: error)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let currentProcess = lock.withLock { process }
        guard let currentProcess, currentProcess.isRunning else {
            return
        }
        ProcessTreeTermination.begin(currentProcess)
    }

    func stop() {
        let currentProcess = lock.withLock { () -> Process? in
            let current = process
            process = nil
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            errorPipe?.fileHandleForReading.readabilityHandler = nil
            inputPipe = nil
            outputPipe = nil
            errorPipe = nil
            outputBuffer.removeAll()
            stdoutLineHandler = nil
            stderrLineHandler = nil
            return current
        }
        finishRequest(with: CancellationError())
        guard let currentProcess, currentProcess.isRunning else {
            return
        }
        ProcessTreeTermination.begin(currentProcess)
    }

    private func startIfNeeded() throws {
        let shouldStart = lock.withLock { self.process == nil }
        guard shouldStart else {
            return
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = runtime.python
        process.arguments = [runtime.helper.path, "--server", "--events-jsonl", "-"]
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.currentDirectoryURL = runtime.helper.deletingLastPathComponent()

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.readOutput(handle)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.readError(handle)
        }
        process.terminationHandler = { [weak self] terminated in
            self?.handleTermination(terminated)
        }

        let didRegister = lock.withLock {
            guard self.process == nil else {
                return false
            }
            self.process = process
            self.inputPipe = inputPipe
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
            return true
        }
        guard didRegister else {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            return
        }

        do {
            try process.run()
            let pid = process.processIdentifier
            if pid > 0 {
                _ = setpgid(pid, 0)
            }
        } catch {
            lock.withLock {
                if self.process === process {
                    self.process = nil
                }
            }
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw ProcessRunnerError.couldNotLaunch(
                executable: runtime.python.path,
                underlying: error
            )
        }
    }

    private func readOutput(_ handle: FileHandle) {
        let data = handle.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            return
        }

        let lines: [String] = lock.withLock {
            outputBuffer.append(data)
            var lines: [String] = []
            while let newline = outputBuffer.firstIndex(of: 0x0A) {
                var line = Data(outputBuffer[..<newline])
                if line.last == 0x0D {
                    line.removeLast()
                }
                outputBuffer.removeSubrange(...newline)
                lines.append(String(decoding: line, as: UTF8.self))
            }
            return lines
        }

        for line in lines {
            let handler = lock.withLock { stdoutLineHandler }
            let shouldFinish = handler?(line) ?? false
            if shouldFinish {
                finishRequest(with: nil)
                return
            }
        }
    }

    private func readError(_ handle: FileHandle) {
        let data = handle.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            return
        }
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        for line in lines {
            let handler = lock.withLock { stderrLineHandler }
            handler?(line)
        }
    }

    private func finishRequest(with error: Error?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            let continuation = requestContinuation
            requestContinuation = nil
            stdoutLineHandler = nil
            stderrLineHandler = nil
            return continuation
        }
        guard let continuation else {
            return
        }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func failActiveRequest(timeout: TimeInterval) {
        let currentProcess = lock.withLock { () -> Process? in
            guard requestContinuation != nil else {
                return nil
            }
            return process
        }
        guard let currentProcess else {
            return
        }
        finishRequest(
            with: ASRBackendError.helperTimedOut(
                timeout: timeout
            )
        )
        ProcessTreeTermination.begin(currentProcess)
    }

    private func handleTermination(_ terminated: Process) {
        let isCurrent = lock.withLock { process === terminated }
        guard isCurrent else {
            return
        }
        finishRequest(
            with: ASRBackendError.helperFailed(
                status: terminated.terminationStatus,
                message: "ASR Helper 持久程序意外結束。",
                technicalDetails: ""
            )
        )
        lock.withLock {
            if process === terminated {
                process = nil
                // A partial JSONL line from the crashed helper must not leak
                // into the next request's event stream.
                outputBuffer.removeAll()
                outputPipe?.fileHandleForReading.readabilityHandler = nil
                errorPipe?.fileHandleForReading.readabilityHandler = nil
                inputPipe = nil
                outputPipe = nil
                errorPipe = nil
            }
        }
    }
}

public final class HelperASRBackend {
    /// The v2 checkpoint store emits one `checkpointCommitted` per durable leaf
    /// write, so it is part of the shipped contract, not an unknown event.
    /// It is neither `completed` nor `error`, so it never terminates the stream.
    private static let allowedEventTypes: Set<String> = [
        "capability",
        "stage",
        "progress",
        "log",
        "warning",
        "heartbeat",
        "checkpointCommitted",
        "completed",
        "error"
    ]

    private let runtime: ResolvedRuntime
    private let paths: ApplicationPaths
    private let runner: ProcessRunner
    private let decoder = JSONDecoder()
    private let sessionLock = NSLock()
    private var persistentSession: PersistentASRHelperSession?

    public init(
        runtime: ResolvedRuntime,
        paths: ApplicationPaths,
        runner: ProcessRunner
    ) {
        self.runtime = runtime
        self.paths = paths
        self.runner = runner
    }

    deinit {
        persistentSession?.stop()
    }

    public func transcribe(
        request: ASRRequest,
        requestURL: URL,
        eventHandler: @escaping (HelperEvent) -> Void
    ) async throws -> ASRTranscriptionResult {
        let maximumAttempts = usesPersistentSession ? 2 : 1
        for attempt in 1...maximumAttempts {
            do {
                return try await transcribeOnce(
                    request: request,
                    requestURL: requestURL,
                    eventHandler: eventHandler
                )
            } catch let error as ASRBackendError {
                guard attempt < maximumAttempts,
                      case .helperTimedOut = error
                else {
                    throw error
                }
                recyclePersistentSession()
                eventHandler(
                    HelperEvent(
                        type: "warning",
                        message: "ASR Helper 長時間未回報，已重啟並嘗試從已完成的內部 chunk checkpoint 接續。",
                        code: "helper_restarted_from_chunk_checkpoint",
                        recoverable: true
                    )
                )
            }
        }
        throw ASRBackendError.completedEventMissing
    }

    private func transcribeOnce(
        request: ASRRequest,
        requestURL: URL,
        eventHandler: @escaping (HelperEvent) -> Void
    ) async throws -> ASRTranscriptionResult {
        let encoder = JSONEncoder()
        // The persistent helper reads stdin as JSONL: one complete JSON object
        // per line. Pretty-printed JSON would send the opening brace alone and
        // make the server fail with a JSONDecodeError. Keep request files
        // readable in one-shot mode, but always use compact JSON for the
        // long-lived session.
        encoder.outputFormatting = usesPersistentSession
            ? [.sortedKeys, .withoutEscapingSlashes]
            : [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let requestData = try encoder.encode(request)
        try AtomicFileWriter.write(requestData, to: requestURL)

        let state = HelperEventState()
        let stdoutLineHandler: (String) -> Bool = { [decoder] line in
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            guard
                let data = line.data(using: .utf8),
                let event = try? decoder.decode(HelperEvent.self, from: data),
                Self.allowedEventTypes.contains(event.type)
            else {
                let malformed = HelperEvent(
                    type: "error",
                    message: ASRBackendError.malformedEvent(line).localizedDescription,
                    code: "invalid_jsonl",
                    recoverable: false
                )
                state.observe(malformed)
                eventHandler(malformed)
                return true
            }
            state.observe(event)
            eventHandler(event)
            return event.type == "completed" || event.type == "error"
        }
        let stderrLineHandler: (String) -> Void = { line in
            eventHandler(
                HelperEvent(type: "log", level: "technical", message: line)
            )
        }

        let terminationStatus: Int32
        let technicalDetails: String
        let inactivityTimeout = HelperInactivityPolicy.hardTimeout(for: request)
        if usesPersistentSession {
            let session = persistentSessionForRequest(request)
            try await session.send(
                requestData: requestData,
                inactivityTimeout: inactivityTimeout,
                stdoutLineHandler: stdoutLineHandler,
                stderrLineHandler: stderrLineHandler
            )
            terminationStatus = 0
            technicalDetails = ""
        } else {
            let result = try await runner.run(
                executableURL: runtime.python,
                arguments: [
                    runtime.helper.path,
                    "--request-json", requestURL.path,
                    "--events-jsonl", "-"
                ],
                environment: helperEnvironment(request: request),
                requireSuccess: false,
                inactivityTimeout: inactivityTimeout,
                stdoutLineHandler: { line in
                    _ = stdoutLineHandler(line)
                },
                stderrLineHandler: stderrLineHandler
            )
            terminationStatus = result.terminationStatus
            technicalDetails = result.standardErrorText
        }

        return try validateResult(
            state: state,
            request: request,
            terminationStatus: terminationStatus,
            technicalDetails: technicalDetails
        )
    }

    private func recyclePersistentSession() {
        let oldSession = sessionLock.withLock { () -> PersistentASRHelperSession? in
            let current = persistentSession
            persistentSession = nil
            return current
        }
        oldSession?.stop()
    }

    private var usesPersistentSession: Bool {
        runtime.helper.lastPathComponent == "qwen_asr_mlx_runner.py"
    }

    private func persistentSessionForRequest(
        _ request: ASRRequest
    ) -> PersistentASRHelperSession {
        let desiredEnvironment = helperEnvironment(request: request)
        return sessionLock.withLock {
            if let existing = persistentSession {
                if existing.matchesEnvironment(desiredEnvironment) {
                    return existing
                }
                // Offline flag or model cache changed; the frozen environment
                // inside the old session would silently misapply settings.
                existing.stop()
                persistentSession = nil
            }
            let session = PersistentASRHelperSession(
                runtime: runtime,
                environment: desiredEnvironment
            )
            persistentSession = session
            return session
        }
    }

    private func validateResult(
        state: HelperEventState,
        request: ASRRequest,
        terminationStatus: Int32,
        technicalDetails: String
    ) throws -> ASRTranscriptionResult {

        let snapshot = state.snapshot()
        if snapshot.errorCode == "glossary_not_supported" {
            throw ASRBackendError.glossaryPromptUnsupported
        }
        if let errorCode = snapshot.errorCode {
            if terminationStatus == 0 {
                throw ASRBackendError.helperReported(
                    message: snapshot.errorMessage ?? "ASR Helper 回報錯誤。",
                    code: errorCode
                )
            }
            throw ASRBackendError.helperFailed(
                status: terminationStatus,
                message: snapshot.errorMessage ?? "ASR Helper 回報錯誤：\(errorCode)",
                technicalDetails: technicalDetails
            )
        }
        guard terminationStatus == 0 else {
            throw ASRBackendError.helperFailed(
                status: terminationStatus,
                message: snapshot.errorMessage ?? "語音辨識失敗。",
                technicalDetails: technicalDetails
            )
        }
        guard snapshot.completedCount == 1 else {
            if snapshot.completedCount == 0 {
                throw ASRBackendError.completedEventMissing
            }
            throw ASRBackendError.completedEventCount(snapshot.completedCount)
        }
        guard let completedPath = snapshot.completedPath else {
            throw ASRBackendError.completedEventMissing
        }
        let expectedURL = URL(fileURLWithPath: request.outputPath).standardizedFileURL
        let completedURL = URL(fileURLWithPath: completedPath).standardizedFileURL
        guard expectedURL.path == completedURL.path else {
            throw ASRBackendError.completedPathMismatch(
                expected: expectedURL.path,
                actual: completedURL.path
            )
        }
        do {
            if let checkpoint = request.checkpointV2 {
                try OutputContractValidator.readLocalTranscript(at: expectedURL, checkpoint: checkpoint, prompt: request.prompt)
            } else {
                try TextFileValidator.readNonEmptyUTF8(at: expectedURL)
            }
        } catch TextFileValidationError.missing {
            throw ASRBackendError.outputMissing(expectedURL.path)
        } catch TextFileValidationError.empty {
            throw ASRBackendError.outputEmpty(expectedURL.path)
        } catch TextFileValidationError.invalidUTF8 {
            throw ASRBackendError.outputInvalidUTF8(expectedURL.path)
        }

        let capability = snapshot.capability ?? ASRCapability(
            supportsSystemPrompt: false,
            supportsContext: false
        )
        if !request.terms.isEmpty,
           !request.allowMissingPrompt,
           !capability.supportsGlossaryPrompt
        {
            throw ASRBackendError.glossaryPromptUnsupported
        }
        return ASRTranscriptionResult(
            capability: capability,
            containsSkippedAudio: snapshot.containsSkippedAudio
        )
    }

    public func cancelCurrentJob() {
        persistentSession?.cancel()
        runner.cancelCurrent()
    }

    /// Ask the helper what it will actually run with, before any identity freezes.
    ///
    /// Always a fresh one-shot process. The persistent session exists to keep a
    /// loaded model warm, so probing through it would either disturb that model
    /// or report the environment of a job that is already running.
    public func reportRuntime(
        modelCacheDirectory: String,
        offline: Bool
    ) async throws -> ASRRuntimeReport {
        let result = try await runner.run(
            executableURL: runtime.python,
            arguments: [
                runtime.helper.path,
                "--report-runtime",
                "--events-jsonl", "-"
            ],
            environment: helperEnvironment(
                modelCacheDirectory: modelCacheDirectory,
                offline: offline
            ),
            requireSuccess: false,
            timeout: 120,
            inactivityTimeout: 60
        )

        var report: ASRRuntimeReport?
        var failure: String?
        for line in result.standardOutputText.split(separator: "\n") {
            guard
                let data = String(line).data(using: .utf8),
                let payload = try? decoder.decode(ASRRuntimeEventPayload.self, from: data)
            else {
                continue
            }
            switch payload.type {
            case "runtime":
                guard
                    let version = payload.asrContractVersion,
                    let systemPrompt = payload.supportsSystemPrompt,
                    let context = payload.supportsContext
                else {
                    failure = "runtime 事件缺少 asrContractVersion 或 capability 欄位。"
                    continue
                }
                report = ASRRuntimeReport(
                    asrContractVersion: version,
                    supportsSystemPrompt: systemPrompt,
                    supportsContext: context,
                    mlxVersion: payload.mlxVersion,
                    mlxAudioVersion: payload.mlxAudioVersion
                )
            case "error":
                failure = payload.message
                    ?? "ASR Helper 回報錯誤（\(payload.code ?? "unknown")）。"
            default:
                continue
            }
        }

        if let failure {
            throw ASRBackendError.runtimeReportFailed(failure)
        }
        guard result.terminationStatus == 0 else {
            throw ASRBackendError.runtimeReportFailed(
                "ASR Helper 以結束碼 \(result.terminationStatus) 結束："
                    + result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard let report else {
            throw ASRBackendError.runtimeReportFailed("ASR Helper 未回報 runtime 事件。")
        }
        guard report.asrContractVersion == LocalCheckpointSchema.asrContractVersion else {
            throw ASRBackendError.runtimeContractMismatch(
                expected: LocalCheckpointSchema.asrContractVersion,
                actual: report.asrContractVersion
            )
        }
        return report
    }

    private func helperEnvironment(request: ASRRequest) -> [String: String] {
        helperEnvironment(
            modelCacheDirectory: request.modelCacheDirectory,
            offline: request.offline
        )
    }

    private func helperEnvironment(
        modelCacheDirectory: String,
        offline: Bool
    ) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in [
            "HOME",
            "TMPDIR",
            "LANG",
            "LC_ALL",
            "TZ",
            "SSL_CERT_FILE",
            "SSL_CERT_DIR"
        ] {
            if let value = inherited[key], !value.isEmpty {
                environment[key] = value
            }
        }
        environment["PATH"] = [
            runtime.python.deletingLastPathComponent().path,
            runtime.ffmpeg.deletingLastPathComponent().path,
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")
        environment["HF_HOME"] = modelCacheDirectory
        environment["HF_HUB_CACHE"] = URL(
            fileURLWithPath: modelCacheDirectory,
            isDirectory: true
        ).appendingPathComponent("hub", isDirectory: true).path
        // Bundled imports must not add .pyc files to the signed App resources.
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUTF8"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        if offline {
            environment["HF_HUB_OFFLINE"] = "1"
            environment["TRANSFORMERS_OFFLINE"] = "1"
        } else {
            environment.removeValue(forKey: "HF_HUB_OFFLINE")
            environment.removeValue(forKey: "TRANSFORMERS_OFFLINE")
        }
        return environment
    }
}

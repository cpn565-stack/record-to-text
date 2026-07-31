import Foundation

public struct ASRRequest: Codable, Equatable, Sendable {
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
        maximumTokens: Int = 16_384,
        chunkDurationSeconds: Double = 1_200,
        segmentIndex: Int = 1,
        segmentCount: Int = 1
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
    }
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
    case completedEventMissing
    case completedEventCount(Int)
    case completedPathMismatch(expected: String, actual: String)
    case outputMissing(String)
    case outputEmpty(String)
    case outputInvalidUTF8(String)
    case glossaryPromptUnsupported

    public var errorDescription: String? {
        switch self {
        case let .malformedEvent(line):
            return "ASR Helper 回傳了無效事件：\(line)"
        case let .helperFailed(status, message, technicalDetails):
            let details = technicalDetails.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(message)（結束碼 \(status)）\(details.isEmpty ? "" : "：\(details)")"
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
        }
    }
}

private final class HelperEventState: @unchecked Sendable {
    private let lock = NSLock()
    private var completedPath: String?
    private var completedCount = 0
    private var errorMessage: String?
    private var errorCode: String?
    private var capability: ASRCapability?

    func observe(_ event: HelperEvent) {
        lock.lock()
        defer { lock.unlock() }

        switch event.type {
        case "completed":
            completedPath = event.outputPath
            completedCount += 1
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
        capability: ASRCapability?
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (completedPath, completedCount, errorMessage, errorCode, capability)
    }
}

public final class HelperASRBackend {
    private static let allowedEventTypes: Set<String> = [
        "capability",
        "stage",
        "progress",
        "log",
        "warning",
        "heartbeat",
        "completed",
        "error"
    ]

    private let runtime: ResolvedRuntime
    private let paths: ApplicationPaths
    private let runner: ProcessRunner
    private let decoder = JSONDecoder()

    public init(
        runtime: ResolvedRuntime,
        paths: ApplicationPaths,
        runner: ProcessRunner
    ) {
        self.runtime = runtime
        self.paths = paths
        self.runner = runner
    }

    public func transcribe(
        request: ASRRequest,
        requestURL: URL,
        eventHandler: @escaping (HelperEvent) -> Void
    ) async throws -> ASRCapability {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFileWriter.write(try encoder.encode(request), to: requestURL)

        let state = HelperEventState()
        let result = try await runner.run(
            executableURL: runtime.python,
            arguments: [
                runtime.helper.path,
                "--request-json", requestURL.path,
                "--events-jsonl", "-"
            ],
            environment: helperEnvironment(request: request),
            requireSuccess: false,
            stdoutLineHandler: { [decoder] line in
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
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
                    return
                }
                state.observe(event)
                eventHandler(event)
            },
            stderrLineHandler: { line in
                eventHandler(
                    HelperEvent(type: "log", level: "technical", message: line)
                )
            }
        )

        let snapshot = state.snapshot()
        if snapshot.errorCode == "glossary_not_supported" {
            throw ASRBackendError.glossaryPromptUnsupported
        }
        if let errorCode = snapshot.errorCode {
            throw ASRBackendError.helperFailed(
                status: result.terminationStatus,
                message: snapshot.errorMessage ?? "ASR Helper 回報錯誤：\(errorCode)",
                technicalDetails: result.standardErrorText
            )
        }
        guard result.terminationStatus == 0 else {
            throw ASRBackendError.helperFailed(
                status: result.terminationStatus,
                message: snapshot.errorMessage ?? "語音辨識失敗。",
                technicalDetails: result.standardErrorText
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
            try TextFileValidator.readNonEmptyUTF8(at: expectedURL)
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
        return capability
    }

    public func cancelCurrentJob() {
        runner.cancelCurrent()
    }

    private func helperEnvironment(request: ASRRequest) -> [String: String] {
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
        environment["HF_HOME"] = request.modelCacheDirectory
        environment["HF_HUB_CACHE"] = URL(
            fileURLWithPath: request.modelCacheDirectory,
            isDirectory: true
        ).appendingPathComponent("hub", isDirectory: true).path
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUTF8"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        if request.offline {
            environment["HF_HUB_OFFLINE"] = "1"
            environment["TRANSFORMERS_OFFLINE"] = "1"
        } else {
            environment.removeValue(forKey: "HF_HUB_OFFLINE")
            environment.removeValue(forKey: "TRANSFORMERS_OFFLINE")
        }
        return environment
    }
}

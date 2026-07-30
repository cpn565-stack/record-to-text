import Darwin
import Foundation

public struct ProcessResult: Equatable, Sendable {
    public let terminationStatus: Int32
    public let terminationReason: Process.TerminationReason
    public let standardOutput: Data
    public let standardError: Data

    public init(
        terminationStatus: Int32,
        terminationReason: Process.TerminationReason,
        standardOutput: Data,
        standardError: Data
    ) {
        self.terminationStatus = terminationStatus
        self.terminationReason = terminationReason
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var standardOutputText: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    public var standardErrorText: String {
        String(decoding: standardError, as: UTF8.self)
    }
}

public enum ProcessRunnerError: LocalizedError {
    case alreadyRunning
    case couldNotLaunch(executable: String, underlying: Error)
    case nonZeroExit(executable: String, status: Int32, standardError: String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "目前已有外部程序正在執行。"
        case let .couldNotLaunch(executable, underlying):
            return "無法啟動 \(executable)：\(underlying.localizedDescription)"
        case let .nonZeroExit(executable, status, standardError):
            let details = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(executable) 結束碼為 \(status)。\(details)"
        }
    }
}

private final class ProcessCapture: @unchecked Sendable {
    private static let maximumCapturedBytes = 5 * 1_024 * 1_024
    private static let maximumRemainderBytes = 1 * 1_024 * 1_024
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutRemainder = Data()
    private var stderrRemainder = Data()
    private let stdoutLineHandler: ((String) -> Void)?
    private let stderrLineHandler: ((String) -> Void)?

    init(
        stdoutLineHandler: ((String) -> Void)?,
        stderrLineHandler: ((String) -> Void)?
    ) {
        self.stdoutLineHandler = stdoutLineHandler
        self.stderrLineHandler = stderrLineHandler
    }

    func appendStdout(_ data: Data) {
        append(
            data,
            destination: &stdoutData,
            remainder: &stdoutRemainder,
            lineHandler: stdoutLineHandler
        )
    }

    func appendStderr(_ data: Data) {
        append(
            data,
            destination: &stderrData,
            remainder: &stderrRemainder,
            lineHandler: stderrLineHandler
        )
    }

    func finish() -> (stdout: Data, stderr: Data) {
        lock.lock()
        let stdoutTail = stdoutRemainder
        let stderrTail = stderrRemainder
        stdoutRemainder.removeAll()
        stderrRemainder.removeAll()
        let stdout = stdoutData
        let stderr = stderrData
        lock.unlock()

        emitTail(stdoutTail, handler: stdoutLineHandler)
        emitTail(stderrTail, handler: stderrLineHandler)
        return (stdout, stderr)
    }

    private func append(
        _ data: Data,
        destination: inout Data,
        remainder: inout Data,
        lineHandler: ((String) -> Void)?
    ) {
        guard !data.isEmpty else {
            return
        }

        lock.lock()
        destination.append(data)
        if destination.count > Self.maximumCapturedBytes {
            destination.removeFirst(destination.count - Self.maximumCapturedBytes)
        }
        remainder.append(data)
        if remainder.count > Self.maximumRemainderBytes {
            remainder.removeFirst(remainder.count - Self.maximumRemainderBytes)
        }

        var lines: [Data] = []
        while let newline = remainder.firstIndex(of: 0x0A) {
            var line = Data(remainder[..<newline])
            if line.last == 0x0D {
                line.removeLast()
            }
            remainder.removeSubrange(...newline)
            lines.append(line)
        }
        lock.unlock()

        for line in lines {
            lineHandler?(String(decoding: line, as: UTF8.self))
        }
    }

    private func emitTail(_ data: Data, handler: ((String) -> Void)?) {
        guard !data.isEmpty else {
            return
        }
        handler?(String(decoding: data, as: UTF8.self))
    }
}

public final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var currentProcess: Process?

    public init() {}

    public var isRunning: Bool {
        lock.withLock {
            currentProcess?.isRunning == true
        }
    }

    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        requireSuccess: Bool = true,
        stdoutLineHandler: ((String) -> Void)? = nil,
        stderrLineHandler: ((String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let capture = ProcessCapture(
            stdoutLineHandler: stdoutLineHandler,
            stderrLineHandler: stderrLineHandler
        )

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.currentDirectoryURL = currentDirectoryURL
        if let environment {
            process.environment = environment
        }

        let didRegister = lock.withLock {
            guard currentProcess == nil else {
                return false
            }
            currentProcess = process
            return true
        }
        guard didRegister else {
            throw ProcessRunnerError.alreadyRunning
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            capture.appendStdout(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            capture.appendStderr(handle.availableData)
        }

        let result: ProcessResult
        do {
            result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { [weak self] terminated in
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil

                        capture.appendStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        capture.appendStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        let captured = capture.finish()

                        self?.clear(process)
                        continuation.resume(
                            returning: ProcessResult(
                                terminationStatus: terminated.terminationStatus,
                                terminationReason: terminated.terminationReason,
                                standardOutput: captured.stdout,
                                standardError: captured.stderr
                            )
                        )
                    }

                    do {
                        try process.run()
                    } catch {
                        self.clear(process)
                        continuation.resume(
                            throwing: ProcessRunnerError.couldNotLaunch(
                                executable: executableURL.path,
                                underlying: error
                            )
                        )
                    }
                }
            } onCancel: { [weak self] in
                self?.cancelCurrent()
            }
        } catch {
            clear(process)
            throw error
        }

        if requireSuccess, result.terminationStatus != 0 {
            throw ProcessRunnerError.nonZeroExit(
                executable: executableURL.path,
                status: result.terminationStatus,
                standardError: result.standardErrorText
            )
        }
        return result
    }

    public func cancelCurrent() {
        let process = lock.withLock { currentProcess }

        guard let process, process.isRunning else {
            return
        }

        Darwin.kill(process.processIdentifier, SIGINT)

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
            guard process.isRunning else {
                return
            }
            Darwin.kill(process.processIdentifier, SIGTERM)

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                guard process.isRunning else {
                    return
                }
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private func clear(_ process: Process) {
        lock.withLock {
            if currentProcess === process {
                currentProcess = nil
            }
        }
    }
}

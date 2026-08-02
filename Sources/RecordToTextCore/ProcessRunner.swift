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
    case cancelledBeforeLaunch(executable: String)
    case timedOut(executable: String, timeout: TimeInterval)
    case inactive(executable: String, timeout: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "目前已有外部程序正在執行。"
        case let .couldNotLaunch(executable, underlying):
            return "無法啟動 \(executable)：\(underlying.localizedDescription)"
        case let .nonZeroExit(executable, status, standardError):
            let details = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(executable) 結束碼為 \(status)。\(details)"
        case let .cancelledBeforeLaunch(executable):
            return "\(executable) 在啟動前已取消。"
        case let .timedOut(executable, timeout):
            return "\(executable) 執行超過 \(Self.format(timeout))，已停止以避免工作無限卡住。"
        case let .inactive(executable, timeout):
            return "\(executable) 已超過 \(Self.format(timeout)) 沒有任何輸出，已停止以避免工作無限卡住。"
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        if seconds >= 60 {
            return String(format: "%.0f 分鐘", seconds / 60)
        }
        return String(format: "%.0f 秒", seconds)
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
    private let activityHandler: (() -> Void)?

    init(
        stdoutLineHandler: ((String) -> Void)?,
        stderrLineHandler: ((String) -> Void)?,
        activityHandler: (() -> Void)?
    ) {
        self.stdoutLineHandler = stdoutLineHandler
        self.stderrLineHandler = stderrLineHandler
        self.activityHandler = activityHandler
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
        activityHandler?()

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
    private var startedAt: Date?
    private var lastActivityAt: Date?
    private var watchdogTask: Task<Void, Never>?
    private var forcedError: ProcessRunnerError?
    /// Set by `cancelCurrent()`; checked before/after launch so cancel
    /// before `process.run()` cannot leave an orphan process.
    private var cancelRequested = false

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
        timeout: TimeInterval? = nil,
        inactivityTimeout: TimeInterval? = nil,
        stdoutLineHandler: ((String) -> Void)? = nil,
        stderrLineHandler: ((String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let capture = ProcessCapture(
            stdoutLineHandler: stdoutLineHandler,
            stderrLineHandler: stderrLineHandler,
            activityHandler: { [weak self, weak process] in
                guard let process else {
                    return
                }
                self?.recordActivity(for: process)
            }
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
            // Fresh run: clear prior cancel so a new job can start after cancel.
            cancelRequested = false
            forcedError = nil
            startedAt = nil
            lastActivityAt = nil
            currentProcess = process
            return true
        }
        guard didRegister else {
            throw ProcessRunnerError.alreadyRunning
        }

        // Cancel may arrive after registration but before launch.
        if lock.withLock({ cancelRequested }) || Task.isCancelled {
            clear(process)
            throw CancellationError()
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
                    var resumed = false
                    let resumeLock = NSLock()
                    func resumeOnce(_ body: () -> Void) {
                        resumeLock.lock()
                        defer { resumeLock.unlock() }
                        guard !resumed else {
                            return
                        }
                        resumed = true
                        body()
                    }

                    process.terminationHandler = { [weak self] terminated in
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil

                        capture.appendStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        capture.appendStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        let captured = capture.finish()

                        self?.clear(process)
                        resumeOnce {
                            continuation.resume(
                                returning: ProcessResult(
                                    terminationStatus: terminated.terminationStatus,
                                    terminationReason: terminated.terminationReason,
                                    standardOutput: captured.stdout,
                                    standardError: captured.stderr
                                )
                            )
                        }
                    }

                    do {
                        // Abort if cancelled while setting up handlers.
                        if self.lock.withLock({ self.cancelRequested }) || Task.isCancelled {
                            self.clear(process)
                            resumeOnce {
                                continuation.resume(throwing: CancellationError())
                            }
                            return
                        }

                        try process.run()

                        // Become process-group leader so cancel can signal the tree.
                        let pid = process.processIdentifier
                        if pid > 0 {
                            _ = setpgid(pid, 0)
                        }
                        self.startWatchdog(
                            for: process,
                            timeout: timeout,
                            inactivityTimeout: inactivityTimeout
                        )

                        // Cancel raced in between run() and setpgid — kill now.
                        if self.lock.withLock({ self.cancelRequested }) || Task.isCancelled {
                            self.terminateProcessTree(process)
                        }
                    } catch {
                        self.clear(process)
                        resumeOnce {
                            continuation.resume(
                                throwing: ProcessRunnerError.couldNotLaunch(
                                    executable: executableURL.path,
                                    underlying: error
                                )
                            )
                        }
                    }
                }
            } onCancel: { [weak self] in
                self?.cancelCurrent()
            }
        } catch {
            clear(process)
            throw error
        }

        // If we were cancelled, surface CancellationError even when the process
        // exited with a non-zero status from SIGINT/SIGTERM/SIGKILL.
        if lock.withLock({ cancelRequested }) || Task.isCancelled {
            throw CancellationError()
        }

        if let forcedError = lock.withLock({ forcedError }) {
            throw forcedError
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
        let process = lock.withLock { () -> Process? in
            cancelRequested = true
            return currentProcess
        }

        guard let process else {
            return
        }

        // Even if not yet isRunning (pre-launch), mark cancel; run() aborts.
        // If already running, escalate signals across the process group.
        if process.isRunning {
            terminateProcessTree(process)
        }
    }

    private func recordActivity(for process: Process) {
        lock.withLock {
            guard currentProcess === process else {
                return
            }
            lastActivityAt = Date()
        }
    }

    private func startWatchdog(
        for process: Process,
        timeout: TimeInterval?,
        inactivityTimeout: TimeInterval?
    ) {
        let validTimeouts = [timeout, inactivityTimeout]
            .compactMap { $0 }
            .filter { $0.isFinite && $0 > 0 }
        guard !validTimeouts.isEmpty else {
            return
        }

        let interval = max(min(validTimeouts.min()! / 4, 5), 0.25)
        let registered = lock.withLock { () -> Bool in
            guard currentProcess === process else {
                return false
            }
            let now = Date()
            startedAt = now
            lastActivityAt = now
            return true
        }
        guard registered else {
            return
        }

        let task = Task { [weak self, weak process] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(interval * 1_000_000_000)
                    )
                } catch {
                    return
                }

                guard let self, let process, process.isRunning else {
                    return
                }
                let snapshot = self.lock.withLock {
                    (
                        isCurrent: self.currentProcess === process,
                        startedAt: self.startedAt,
                        lastActivityAt: self.lastActivityAt
                    )
                }
                guard snapshot.isCurrent else {
                    return
                }
                let now = Date()
                if let timeout,
                   timeout.isFinite,
                   timeout > 0,
                   let startedAt = snapshot.startedAt,
                   now.timeIntervalSince(startedAt) >= timeout
                {
                    self.fail(
                        process,
                        with: .timedOut(
                            executable: process.executableURL?.path ?? "外部程序",
                            timeout: timeout
                        )
                    )
                    return
                }
                if let inactivityTimeout,
                   inactivityTimeout.isFinite,
                   inactivityTimeout > 0,
                   let lastActivityAt = snapshot.lastActivityAt,
                   now.timeIntervalSince(lastActivityAt) >= inactivityTimeout
                {
                    self.fail(
                        process,
                        with: .inactive(
                            executable: process.executableURL?.path ?? "外部程序",
                            timeout: inactivityTimeout
                        )
                    )
                    return
                }
            }
        }
        lock.withLock {
            if currentProcess === process {
                watchdogTask = task
            } else {
                task.cancel()
            }
        }
    }

    private func fail(_ process: Process, with error: ProcessRunnerError) {
        let shouldTerminate = lock.withLock { () -> Bool in
            guard currentProcess === process, process.isRunning else {
                return false
            }
            forcedError = error
            return true
        }
        if shouldTerminate {
            terminateProcessTree(process)
        }
    }

    /// SIGINT → SIGTERM → SIGKILL against the process group (negative PID)
    /// so helper children (e.g. Python → MLX workers) are included when
    /// `setpgid` succeeded after launch.
    private func terminateProcessTree(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else {
            return
        }

        // Negative PID = process group. Also interrupt the Process handle.
        _ = Darwin.kill(-pid, SIGINT)
        if process.isRunning {
            process.interrupt()
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
            guard process.isRunning else {
                return
            }
            _ = Darwin.kill(-pid, SIGTERM)
            process.terminate()

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                guard process.isRunning else {
                    return
                }
                _ = Darwin.kill(-pid, SIGKILL)
                // Fallback: direct PID if group kill failed.
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
    }

    private func clear(_ process: Process) {
        let watchdog = lock.withLock { () -> Task<Void, Never>? in
            if currentProcess === process {
                currentProcess = nil
                startedAt = nil
                lastActivityAt = nil
                let task = watchdogTask
                watchdogTask = nil
                return task
            }
            return nil
        }
        watchdog?.cancel()
    }
}

import AppKit
import Foundation
import IOKit.pwr_mgt
import OSLog
import RecordToTextCore
import SwiftUI

enum SystemSleepService {
    struct Failure: LocalizedError {
        let code: IOReturn
        var errorDescription: String? { "系統拒絕休眠要求（\(code)）。" }
    }
    static func request() throws {
        let connection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard connection != 0 else { throw Failure(code: kIOReturnNotOpen) }
        defer { IOServiceClose(connection) }
        let result = IOPMSleepSystem(connection)
        guard result == kIOReturnSuccess else { throw Failure(code: result) }
    }
}

/// Fixed, non-identifying events. A successful request and a system notification
/// are separate evidence; neither claims the machine has finished sleeping.
enum QueueSleepEvent: Equatable {
    case requestAccepted, requestRejected(IOReturn?), systemWillSleep, systemDidWake

    func log() {
        let logger = Logger(subsystem: "com.specifique.record-to-text", category: "QueueCompletionSleep")
        switch self {
        case .requestAccepted: logger.info("Sleep request accepted")
        case let .requestRejected(code): logger.error("Sleep request rejected; IOKit code: \(code.map(String.init) ?? "unavailable", privacy: .public)")
        case .systemWillSleep: logger.info("Received system will-sleep notification")
        case .systemDidWake: logger.info("Received system did-wake notification")
        }
    }
}

/// Tracks logical work independently of the prunable job history. No armed
/// state survives an App launch, and the final check/request share MainActor.
@MainActor
final class QueueCompletionSleepCoordinator: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var countdownUntil: Date?
    @Published private(set) var message: String?
    private enum Outcome { case pending, succeeded, failed }
    private var outcomes: [UUID: Outcome] = [:]
    private var knownJobs = Set<UUID>()
    private var started = false
    private var blocked = true
    private var generation = UUID()
    private var countdown: Task<Void, Never>?
    private let delay: Duration
    private let wait: @Sendable (Duration) async throws -> Void
    private let requestSleep: () throws -> Void
    private let logEvent: (QueueSleepEvent) -> Void
    private let notificationCenter: NotificationCenter
    private let activity = SleepPreventionService()
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    var prepare: (() async throws -> Bool)?

    init(delay: Duration = .seconds(30),
         wait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         requestSleep: @escaping () throws -> Void = { try SystemSleepService.request() },
         notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         logEvent: @escaping (QueueSleepEvent) -> Void = { $0.log() }) {
        self.delay = delay; self.wait = wait; self.requestSleep = requestSleep
        self.notificationCenter = notificationCenter; self.logEvent = logEvent
        sleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.setEnabled(false, jobs: [])
                    self.logEvent(.systemWillSleep)
                    self.message = "已收到系統即將休眠通知。"
                }
            }
        wakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.setEnabled(false, jobs: [])
                    self.logEvent(.systemDidWake)
                }
            }
    }
    deinit {
        countdown?.cancel()
        if let sleepObserver { notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { notificationCenter.removeObserver(wakeObserver) }
    }
    func setEnabled(_ enabled: Bool, jobs: [TranscriptionJob]) {
        invalidateCountdown()
        isEnabled = enabled; message = nil
        outcomes.removeAll(); knownJobs = Set(jobs.map(\.id)); started = false
        if enabled {
            for job in jobs where !job.stage.isTerminal || job.isCloudRecoveryPaused {
                outcomes[job.id] = .pending
                started = started || job.startedAt != nil
            }
        }
    }
    func cancelWork(_ id: UUID) {
        if outcomes[id] != nil { setEnabled(false, jobs: []) }
    }
    func refresh(jobs: [TranscriptionJob], blocked: Bool) {
        self.blocked = blocked
        guard isEnabled else { return }
        for job in jobs {
            if let parent = job.continuationParentJobID, outcomes[parent] != nil {
                outcomes.removeValue(forKey: parent)
                outcomes[job.id] = .pending
            }
            if !knownJobs.contains(job.id), !job.stage.isTerminal { outcomes[job.id] = .pending }
            knownJobs.insert(job.id)
            guard outcomes[job.id] != nil else { continue }
            if job.stage == .cancelled { setEnabled(false, jobs: []); return }
            started = started || job.startedAt != nil
            outcomes[job.id] = job.stage == .completed && job.resolvedOutputCompleteness == .complete
                ? .succeeded : job.stage.isTerminal ? .failed : .pending
        }
        let present = Set(jobs.map(\.id))
        if outcomes.contains(where: { !present.contains($0.key) && $0.value != .succeeded }) {
            setEnabled(false, jobs: []); return
        }
        guard eligible else { invalidateCountdown(); return }
        guard countdown == nil else { return }
        activity.begin()
        let token = generation
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        countdownUntil = Date().addingTimeInterval(seconds)
        countdown = Task { [weak self, wait, delay] in
            do {
                try await wait(delay)
                try Task.checkCancellation()
                guard let self, self.generation == token, self.eligible else { return }
                let prepared = try await self.prepare?() ?? false
                guard self.generation == token, self.eligible, prepared else {
                    if self.generation == token { self.invalidateCountdown() }
                    return
                }
                // No await between the final gate, consuming the one-shot and
                // issuing the public system request.
                self.setEnabled(false, jobs: [])
                do {
                    try self.requestSleep()
                    self.logEvent(.requestAccepted)
                    self.message = "已送出休眠要求。"
                } catch {
                    self.logEvent(.requestRejected((error as? SystemSleepService.Failure)?.code))
                    self.message = "轉檔已完成，但無法讓電腦休眠：\(error.localizedDescription)"
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == token else { return }
                self.setEnabled(false, jobs: [])
                self.message = "工作紀錄尚未保存，已取消自動休眠：\(error.localizedDescription)"
            }
        }
    }
    private var eligible: Bool {
        isEnabled && started && !blocked && !outcomes.isEmpty && outcomes.values.allSatisfy { $0 == .succeeded }
    }
    private func invalidateCountdown() {
        generation = UUID(); countdown?.cancel(); countdown = nil
        countdownUntil = nil; activity.end()
    }
}

struct QueueSleepControls: View {
    @ObservedObject var coordinator: QueueCompletionSleepCoordinator
    let setEnabled: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("本次全部轉檔成功後讓電腦休眠", isOn: Binding(
                get: { coordinator.isEnabled }, set: setEnabled))
                .toggleStyle(.checkbox)
            Text("僅本次有效；有失敗、缺口或暫停時不會自動休眠。")
                .font(.caption).foregroundStyle(.secondary)
            if let until = coordinator.countdownUntil {
                HStack {
                    Text("轉檔已全部成功，") + Text(until, style: .timer) + Text(" 後休眠")
                    Button("取消休眠") { setEnabled(false) }.buttonStyle(.link)
                }
                .font(.caption)
            }
            if let message = coordinator.message { Text(message).font(.caption).textSelection(.enabled) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

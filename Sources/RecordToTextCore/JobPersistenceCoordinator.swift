import Foundation

public struct PersistenceSnapshot: Codable, Sendable {
    public var schemaVersion = 1
    public let revision: UInt64
    public var jobs: [TranscriptionJob]
    public var recentJobs: [RecentJobSummary]
    public let recentHistoryLimit: Int
    public var timestamp = Date()
    public init(revision: UInt64, jobs: [TranscriptionJob], recentJobs: [RecentJobSummary], recentHistoryLimit: Int) {
        self.revision = revision; self.jobs = jobs; self.recentJobs = recentJobs
        self.recentHistoryLimit = recentHistoryLimit
    }
    public func canonical() -> Self {
        var copy = self
        let terminal = jobs.filter { $0.stage.isTerminal }.map(RecentJobSummary.init(job:))
        let ids = Set(terminal.map(\.id))
        copy.recentJobs = JobRetentionPolicy.recentSummaries(
            recentJobs.filter { !ids.contains($0.id) } + terminal, limit: recentHistoryLimit)
        copy.jobs = JobRetentionPolicy.ledgerJobs(jobs, terminalHistoryLimit: recentHistoryLimit)
        return copy
    }
}

/// Called only on the coordinator's serial I/O queue (or once during startup).
/// The journal is authoritative; the two original files are repairable views.
public final class JobPersistenceStore: @unchecked Sendable {
    public let journalURL: URL
    private let previousURL: URL
    private let ledgerURL: URL
    private let recentURL: URL
    private let checkpoint: ((String) throws -> Void)?
    public init(ledgerURL: URL, recentURL: URL, checkpoint: ((String) throws -> Void)? = nil) {
        self.ledgerURL = ledgerURL; self.recentURL = recentURL
        journalURL = ledgerURL.deletingLastPathComponent().appendingPathComponent("job-journal.json")
        previousURL = ledgerURL.deletingLastPathComponent().appendingPathComponent("job-journal.previous.json")
        self.checkpoint = checkpoint
    }
    public func write(_ input: PersistenceSnapshot) throws {
        let snapshot = input.canonical()
        try checkpoint?("beforeJournal")
        if let data = try? Data(contentsOf: journalURL) {
            try AtomicFileWriter.write(data, to: previousURL)
        }
        try JSONRepository<PersistenceSnapshot>(url: journalURL).save(snapshot) { stage in
            try self.checkpoint?("journal-\(stage)")
        }
        try checkpoint?("afterJournal")
        try materialize(snapshot)
    }
    private func materialize(_ snapshot: PersistenceSnapshot) throws {
        var ledger = JobLedgerCollection(schemaVersion: 2, jobs: snapshot.jobs)
        ledger.revision = snapshot.revision
        var recent = RecentJobCollection(schemaVersion: 2, jobs: snapshot.recentJobs)
        recent.revision = snapshot.revision
        try JSONRepository<JobLedgerCollection>(url: ledgerURL).save(ledger)
        try checkpoint?("afterLedger")
        try JSONRepository<RecentJobCollection>(url: recentURL).save(recent)
        try checkpoint?("afterRecent")
    }
    public func recover(repairOutputs: Bool = true) throws -> PersistenceSnapshot? {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
        // Never silently accept mixed legacy outputs when a journal exists.
        let snapshot = try JSONRepository<PersistenceSnapshot>(url: journalURL).load(
            default: PersistenceSnapshot(revision: 0, jobs: [], recentJobs: [], recentHistoryLimit: 0))
        // Even if compatibility output repair fails (e.g. disk full), callers
        // must load the complete journal, never a mixture of the old views.
        if repairOutputs { try? materialize(snapshot) }
        return snapshot
    }
}

public actor JobPersistenceCoordinator {
    public enum Urgency: Sendable { case coalescible, critical }
    public struct DurableReceipt: Sendable { public let revision: UInt64 }
    public struct Status: Sendable {
        public let lastDurableRevision: UInt64
        public let pendingRevision: UInt64?
        public let error: String?
    }
    private let queue = DispatchQueue(label: "record-to-text.job-persistence", qos: .utility)
    private let writer: @Sendable (PersistenceSnapshot) throws -> Void
    private var pending: PersistenceSnapshot?
    private var writingRevision: UInt64?
    private var lastDurableRevision: UInt64
    private var lastError: String?
    private var scheduled: Task<Void, Never>?
    private var firstPendingAt: ContinuousClock.Instant?
    private var failures = 0
    private var waiters: [(revision: UInt64, continuation: CheckedContinuation<Void, Error>, id: UUID)] = []
    private let observer: (@Sendable (Status) -> Void)?
    public init(initialRevision: UInt64 = 0, writer: @escaping @Sendable (PersistenceSnapshot) throws -> Void,
                observer: (@Sendable (Status) -> Void)? = nil) {
        lastDurableRevision = initialRevision; self.writer = writer; self.observer = observer
    }
    public var status: Status {
        Status(lastDurableRevision: lastDurableRevision, pendingRevision: pending?.revision ?? writingRevision, error: lastError)
    }
    public func submit(_ snapshot: PersistenceSnapshot, urgency: Urgency) {
        guard snapshot.revision > lastDurableRevision,
              snapshot.revision > (writingRevision ?? 0),
              snapshot.revision >= (pending?.revision ?? 0) else { return }
        pending = snapshot
        if firstPendingAt == nil { firstPendingAt = .now }
        if urgency == .critical { scheduled?.cancel(); scheduled = nil; startWrite() }
        else if writingRevision == nil {
            scheduled?.cancel()
            let delay = min(Duration.milliseconds(250), max(.zero, ContinuousClock.now.duration(to: firstPendingAt!.advanced(by: .seconds(1)))))
            schedule(after: delay)
        }
    }
    public func submitCritical(_ snapshot: PersistenceSnapshot) async throws -> DurableReceipt {
        submit(snapshot, urgency: .critical)
        try await flush(throughRevision: snapshot.revision)
        return DurableReceipt(revision: lastDurableRevision)
    }
    public func flush(throughRevision revision: UInt64) async throws {
        if lastDurableRevision >= revision { return }
        scheduled?.cancel(); scheduled = nil
        failures = 0
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((revision, continuation, id))
                startWrite()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func schedule(after delay: Duration) {
        scheduled = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            self.startWrite()
        }
    }
    private func startWrite() {
        guard writingRevision == nil, let snapshot = pending else { return }
        pending = nil; firstPendingAt = nil; writingRevision = snapshot.revision
        let writer = writer
        queue.async {
            let result = Result { try writer(snapshot) }
            Task { await self.finished(snapshot, result: result) }
        }
    }
    private func finished(_ snapshot: PersistenceSnapshot, result: Result<Void, Error>) {
        writingRevision = nil
        switch result {
        case .success:
            lastDurableRevision = snapshot.revision; lastError = nil; failures = 0
            let ready = waiters.filter { $0.0 <= lastDurableRevision }
            waiters.removeAll { $0.0 <= lastDurableRevision }
            ready.forEach { $0.1.resume() }
            observer?(status)
            startWrite()
        case let .failure(error):
            if pending == nil { pending = snapshot }
            lastError = error.localizedDescription
            failures += 1
            observer?(status)
            if failures <= 3 { schedule(after: .seconds(1 << (failures - 1))) }
            else {
                let failed = waiters; waiters.removeAll()
                failed.forEach { $0.1.resume(throwing: error) }
            }
        }
    }
}

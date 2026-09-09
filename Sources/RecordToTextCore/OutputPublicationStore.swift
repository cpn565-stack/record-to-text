import CryptoKit
import Foundation

/// An intent is durable before the exclusive atomic TXT publication. Recovery
/// requires both the expected bytes and an already-known job, so a leftover
/// intent can neither promote a partial file nor resurrect a deleted job.
public struct OutputPublicationIntent: Codable, Sendable {
    public let jobID: UUID
    public let sourcePath: String
    public let result: PipelineResult
    public let sha256: String
    public let completedAt: Date
}

public struct OutputPublicationStore: Sendable {
    private let directory: URL
    public init(paths: ApplicationPaths) {
        directory = paths.root.appendingPathComponent("Publication-Receipts", isDirectory: true)
    }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
    public func prepare(job: TranscriptionJob, result: PipelineResult, text: String) throws {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.unicodeScalars.first?.value == 0xFEFF { normalized.removeFirst() }
        let intent = OutputPublicationIntent(jobID: job.id, sourcePath: job.sourcePath,
            result: result, sha256: Self.digest(Data(normalized.utf8)), completedAt: Date())
        try JSONRepository<OutputPublicationIntent>(url: url(job.id)).save(intent)
    }
    public func recover(job: TranscriptionJob) throws -> TranscriptionJob? {
        guard !job.stage.isTerminal || job.stage == .interrupted,
              FileManager.default.fileExists(atPath: url(job.id).path) else { return nil }
        let data = try Data(contentsOf: url(job.id))
        // Repository uses ISO dates; default value is never used for an existing intent.
        let repository = JSONRepository<OutputPublicationIntent>(url: url(job.id))
        let fallback = OutputPublicationIntent(jobID: job.id, sourcePath: "", result: .init(outputURL: url(job.id), rawOutputURL: nil, duration: 0), sha256: "", completedAt: .distantPast)
        guard !data.isEmpty else { return nil }
        let intent = try repository.load(default: fallback)
        guard intent.jobID == job.id, intent.sourcePath == job.sourcePath,
              let output = try? Data(contentsOf: intent.result.outputURL),
              !output.isEmpty, Self.digest(output) == intent.sha256 else { return nil }
        var recovered = job
        recovered.stage = .completed
        recovered.outputPath = intent.result.outputURL.path
        recovered.rawOutputPath = intent.result.rawOutputURL?.path
        recovered.completedAt = intent.completedAt
        recovered.progressCurrent = nil; recovered.progressTotal = nil; recovered.progressUnit = nil
        recovered.cloudSegmentMetadata = intent.result.cloudSegmentMetadata
        recovered.failure = nil
        if intent.result.containsSkippedAudio {
            recovered.failure = JobFailure(stage: .completed,
                userMessage: "已找回完成稿；稿件含未完成音訊的缺口標記。",
                technicalDetails: "Recovered publication with audio gaps.", recoverable: intent.result.recoveryDirectory != nil,
                recoveryDirectory: intent.result.recoveryDirectory?.path, partialTranscriptPath: nil)
        }
        recovered.logLines.append("已核對輸出雜湊，找回上次完成但尚未保存工作紀錄的正式稿。")
        return recovered
    }
    public func recoverKnownJobs(_ jobs: [TranscriptionJob]) throws -> [TranscriptionJob] {
        try jobs.map { try recover(job: $0) ?? $0 }
    }
    /// Run on the writer queue only after a journal commit. Pending known jobs
    /// retain their intents; completed/deleted jobs no longer need them.
    public func prune(after snapshot: PersistenceSnapshot) {
        let pending = Set(snapshot.jobs.filter { !$0.stage.isTerminal || $0.stage == .interrupted }.map(\.id))
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.pathExtension == "json" {
            guard let id = UUID(uuidString: entry.deletingPathExtension().lastPathComponent), !pending.contains(id) else { continue }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("record-to-text", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
            do {
                if FileManager.default.fileExists(atPath: work.path) { try FileManager.default.removeItem(at: work) }
                try FileManager.default.removeItem(at: entry)
            } catch { /* Keep the intent so a later durable snapshot can retry cleanup. */ }
        }
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

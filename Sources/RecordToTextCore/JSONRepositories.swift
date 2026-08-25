import Foundation

private let repositoryISO8601Fractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let repositoryISO8601Standard: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

public final class JSONRepository<Value: Codable> {
    public let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(repositoryISO8601Fractional.string(from: date))
        }
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = repositoryISO8601Fractional.date(from: value) {
                return date
            }

            if let date = repositoryISO8601Standard.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
        self.decoder = decoder
    }

    public func load(default defaultValue: @autoclosure () -> Value) throws -> Value {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return defaultValue()
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        let data = try encoder.encode(value)
        try AtomicFileWriter.write(data, to: url)
    }
}

/// Outcome of a lenient collection load.
public struct LenientLoadOutcome<Collection> {
    public let value: Collection
    /// Records that failed to decode and were skipped.
    public let skippedRecordCount: Int
    /// Non-nil when the stored file was unusable or partially damaged. The
    /// original file has been quarantined (renamed) so a future save cannot
    /// silently destroy the only copy of that data.
    public let diagnosticMessage: String?
}

/// A single record inside a collection file; decoding failures are contained
/// per record instead of failing the whole collection.
private struct LossyRecord<Record: Decodable>: Decodable {
    let record: Record?

    init(from decoder: Decoder) throws {
        record = try? Record(from: decoder)
    }
}

public enum LenientCollectionLoader {
    /// Renames an unreadable/damaged store next to itself so the data is
    /// preserved for manual inspection; a subsequent save then starts fresh.
    public static func quarantine(
        url: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> String? {
        let stamp = repositoryISO8601Standard.string(from: now)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        var target = URL(fileURLWithPath: url.path + ".corrupt-\(stamp)")
        var attempt = 0
        while fileManager.fileExists(atPath: target.path) {
            attempt += 1
            target = URL(fileURLWithPath: "\(url.path).corrupt-\(stamp)-\(attempt)")
        }
        do {
            try fileManager.moveItem(at: url, to: target)
            return target.lastPathComponent
        } catch {
            // Best effort only; never block startup on quarantine failure.
            return nil
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = repositoryISO8601Fractional.date(from: value) {
                return date
            }
            if let date = repositoryISO8601Standard.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
        return decoder
    }

    /// Loads the job ledger without letting one incompatible record destroy
    /// every other entry. A fully unreadable or partially salvaged file is
    /// quarantined first so later saves cannot overwrite the evidence.
    public static func loadJobLedger(
        at url: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> LenientLoadOutcome<JobLedgerCollection> {
        struct LedgerShape: Decodable {
            let jobs: [LossyRecord<TranscriptionJob>]
            enum CodingKeys: String, CodingKey { case jobs }
            init(from decoder: Decoder) throws {
                jobs = try decoder.container(keyedBy: CodingKeys.self)
                    .decode([LossyRecord<TranscriptionJob>].self, forKey: .jobs)
            }
        }

        guard fileManager.fileExists(atPath: url.path) else {
            return LenientLoadOutcome(
                value: JobLedgerCollection(),
                skippedRecordCount: 0,
                diagnosticMessage: nil
            )
        }
        guard let data = try? Data(contentsOf: url) else {
            // Unreadable now; a later save will fail loudly rather than
            // silently replacing it, so leave the file untouched.
            return LenientLoadOutcome(
                value: JobLedgerCollection(),
                skippedRecordCount: 0,
                diagnosticMessage: "未完成工作記錄無法讀取（檔案保留未動）。"
            )
        }

        let decoder = makeDecoder()
        if let intact = try? decoder.decode(JobLedgerCollection.self, from: data) {
            return LenientLoadOutcome(value: intact, skippedRecordCount: 0, diagnosticMessage: nil)
        }

        let quarantinedName = quarantine(url: url, fileManager: fileManager, now: now)
        let quarantineNote = quarantinedName.map { "原始檔已改名為 \($0) 保留。" } ?? ""

        if let shape = try? decoder.decode(LedgerShape.self, from: data) {
            let jobs = shape.jobs.compactMap(\.record)
            let skipped = shape.jobs.count - jobs.count
            let message: String?
            if skipped > 0 {
                message = "未完成工作記錄有 \(skipped) 筆無法解讀，已跳過這些紀錄。\(quarantineNote)"
            } else {
                message = "未完成工作記錄格式無法辨識，已重建空白清單。\(quarantineNote)"
            }
            return LenientLoadOutcome(
                value: JobLedgerCollection(jobs: jobs),
                skippedRecordCount: skipped,
                diagnosticMessage: message
            )
        }

        return LenientLoadOutcome(
            value: JobLedgerCollection(),
            skippedRecordCount: 0,
            diagnosticMessage: "未完成工作記錄無法解析，已重建空白清單。\(quarantineNote)"
        )
    }

    /// Same containment policy for the recent-jobs summary file.
    public static func loadRecentJobs(
        at url: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> LenientLoadOutcome<RecentJobCollection> {
        struct RecentShape: Decodable {
            let jobs: [LossyRecord<RecentJobSummary>]
            enum CodingKeys: String, CodingKey { case jobs }
            init(from decoder: Decoder) throws {
                jobs = try decoder.container(keyedBy: CodingKeys.self)
                    .decode([LossyRecord<RecentJobSummary>].self, forKey: .jobs)
            }
        }

        guard fileManager.fileExists(atPath: url.path) else {
            return LenientLoadOutcome(
                value: RecentJobCollection(),
                skippedRecordCount: 0,
                diagnosticMessage: nil
            )
        }
        guard let data = try? Data(contentsOf: url) else {
            return LenientLoadOutcome(
                value: RecentJobCollection(),
                skippedRecordCount: 0,
                diagnosticMessage: "最近工作無法讀取（檔案保留未動）。"
            )
        }

        let decoder = makeDecoder()
        if let intact = try? decoder.decode(RecentJobCollection.self, from: data) {
            return LenientLoadOutcome(value: intact, skippedRecordCount: 0, diagnosticMessage: nil)
        }

        let quarantinedName = quarantine(url: url, fileManager: fileManager, now: now)
        let quarantineNote = quarantinedName.map { "原始檔已改名為 \($0) 保留。" } ?? ""

        if let shape = try? decoder.decode(RecentShape.self, from: data) {
            let jobs = shape.jobs.compactMap(\.record)
            let skipped = shape.jobs.count - jobs.count
            let message: String?
            if skipped > 0 {
                message = "最近工作有 \(skipped) 筆無法解讀，已跳過這些紀錄。\(quarantineNote)"
            } else {
                message = "最近工作格式無法辨識，已重建空白清單。\(quarantineNote)"
            }
            return LenientLoadOutcome(
                value: RecentJobCollection(jobs: jobs),
                skippedRecordCount: skipped,
                diagnosticMessage: message
            )
        }

        return LenientLoadOutcome(
            value: RecentJobCollection(),
            skippedRecordCount: 0,
            diagnosticMessage: "最近工作無法解析，已重建空白清單。\(quarantineNote)"
        )
    }
}

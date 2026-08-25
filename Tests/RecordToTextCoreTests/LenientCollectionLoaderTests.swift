import XCTest
@testable import RecordToTextCore

final class LenientCollectionLoaderTests: XCTestCase {
    private func makeSnapshot() -> JobSnapshot {
        JobSnapshot(
            modelID: "mlx-community/Qwen3-ASR-1.7B-8bit",
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "請忠實轉錄。",
            outputLocationMode: .sameAsSource,
            outputDirectory: "/tmp/output",
            keepRawTranscript: false
        )
    }

    private func makeISO8601Encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    func testIntactLedgerLoadsWithoutMessages() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("job-ledger.json")

        let job = TranscriptionJob(sourcePath: "/tmp/audio.m4a", snapshot: makeSnapshot())
        try makeISO8601Encoder()
            .encode(JobLedgerCollection(jobs: [job]))
            .write(to: url)

        let outcome = LenientCollectionLoader.loadJobLedger(at: url)

        XCTAssertNil(outcome.diagnosticMessage)
        XCTAssertEqual(outcome.skippedRecordCount, 0)
        XCTAssertEqual(outcome.value.jobs.count, 1)
        XCTAssertEqual(outcome.value.jobs.first?.id, job.id)
    }

    func testOneIncompatibleRecordIsSkippedWithoutLosingTheRest() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("job-ledger.json")

        let goodJob = TranscriptionJob(sourcePath: "/tmp/audio.m4a", snapshot: makeSnapshot())
        let encoded = try makeISO8601Encoder()
            .encode(JobLedgerCollection(jobs: [goodJob]))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let jobObject = try XCTUnwrap((object["jobs"] as? [[String: Any]])?.first)
        // A wrong-typed field inside one record must not destroy the others.
        object["jobs"] = [["sourcePath": 42], jobObject]
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let outcome = LenientCollectionLoader.loadJobLedger(at: url)

        XCTAssertEqual(outcome.skippedRecordCount, 1)
        XCTAssertEqual(outcome.value.jobs.map(\.id), [goodJob.id])
        XCTAssertNotNil(outcome.diagnosticMessage)

        // The damaged original must be preserved instead of being overwritten.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(
            siblings.contains { $0.hasPrefix("job-ledger.json.corrupt-") },
            "siblings: \(siblings)"
        )
    }

    func testUnparsableLedgerIsQuarantinedAndReplacedWithEmptyCollection() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("job-ledger.json")
        try Data("這不是 JSON".utf8).write(to: url)

        let outcome = LenientCollectionLoader.loadJobLedger(at: url)

        XCTAssertEqual(outcome.value.jobs.count, 0)
        XCTAssertNotNil(outcome.diagnosticMessage)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(
            siblings.contains { $0.hasPrefix("job-ledger.json.corrupt-") },
            "siblings: \(siblings)"
        )

        // A follow-up save recreates a usable store without touching backups.
        let repository = JSONRepository<JobLedgerCollection>(url: url)
        try repository.save(JobLedgerCollection())
        XCTAssertEqual(try repository.load(default: JobLedgerCollection()), JobLedgerCollection())
    }

    func testRecentJobsSkipBrokenSummaryAndQuarantine() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recent-jobs.json")

        let summary = RecentJobSummary(
            id: UUID(),
            sourcePath: "/tmp/audio.m4a",
            outputPath: "/tmp/audio_逐字稿.txt",
            stage: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_600),
            modelID: "gemini-3.7-flash",
            glossaryName: nil
        )
        var object: [String: Any] = [
            "schemaVersion": 1,
            "jobs": [["stage": 999], ["id": summary.id.uuidString]]
        ]
        // The second entry lacks required fields too, so only the first broken
        // shape matters here; rebuild with one valid entry plus one broken.
        let encodedSummary = try makeISO8601Encoder().encode([summary])
        let validEntry = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: encodedSummary) as? [[String: Any]])?.first
        )
        object["jobs"] = [["stage": 999], validEntry]
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let outcome = LenientCollectionLoader.loadRecentJobs(at: url)

        XCTAssertEqual(outcome.skippedRecordCount, 1)
        XCTAssertEqual(outcome.value.jobs.map(\.id), [summary.id])
        XCTAssertNotNil(outcome.diagnosticMessage)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(
            siblings.contains { $0.hasPrefix("recent-jobs.json.corrupt-") },
            "siblings: \(siblings)"
        )
    }
}

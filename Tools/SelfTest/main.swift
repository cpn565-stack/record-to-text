import Darwin
import Foundation
import RecordToTextCore

private struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class SelfTestRunner {
    private var passed = 0
    private var failed = 0

    func check(
        _ condition: @autoclosure () throws -> Bool,
        _ name: String
    ) {
        do {
            if try condition() {
                passed += 1
                print("PASS \(name)")
            } else {
                throw SelfTestFailure(description: "assertion returned false")
            }
        } catch {
            failed += 1
            print("FAIL \(name): \(error)")
        }
    }

    func finish() -> Never {
        print("\n\(passed) passed, \(failed) failed")
        Darwin.exit(failed == 0 ? 0 : 1)
    }
}

private final class AsyncResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.withLock {
            self.result = result
        }
    }

    func load() throws -> Value {
        try lock.withLock {
            guard let result else {
                throw SelfTestFailure(description: "async operation did not return")
            }
            return try result.get()
        }
    }
}

private func blockingAwait<Value>(
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let box = AsyncResultBox<Value>()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            box.store(.success(try await operation()))
        } catch {
            box.store(.failure(error))
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.load()
}

private let tests = SelfTestRunner()

tests.check(
    TermParser.parse(" OGSTM，五大構面、OGSTM； One Company One Mission\n江總 ")
        == ["OGSTM", "五大構面", "One Company One Mission", "江總"],
    "TermParser separators, trim, order and exact dedupe"
)

tests.check(
    TermParser.parse("Specifique,specifique") == ["Specifique", "specifique"],
    "TermParser preserves case-sensitive distinct terms"
)

tests.check(
    try PromptBuilder.build(
        commonTerms: ["SPECIFIQUE"],
        glossaryTerms: ["OGSTM"],
        temporaryTerms: ["江總"]
    ).terms == ["SPECIFIQUE", "OGSTM", "江總"],
    "PromptBuilder merge order"
)

tests.check(
    try {
        let result = try PromptBuilder.build(
            commonTerms: [],
            glossaryTerms: [],
            temporaryTerms: []
        )
        return result.terms.isEmpty && result.prompt.contains("忠實轉錄")
    }(),
    "PromptBuilder empty glossary still preserves fidelity instruction"
)

tests.check(
    OutputNameBuilder.sanitizedStem(
        for: URL(fileURLWithPath: "/tmp/會議.final.m4a")
    ) == "會議.final",
    "OutputNameBuilder keeps inner extension"
)

tests.check(
    {
        let directory = URL(fileURLWithPath: "/tmp")
        let url = OutputNameBuilder.availableOutputURL(
            sourceURL: URL(fileURLWithPath: "/tmp/會議.m4a"),
            directory: directory,
            fileExists: { $0.hasSuffix("會議_逐字稿.txt") }
        )
        return url.lastPathComponent == "會議_逐字稿_2.txt"
    }(),
    "OutputNameBuilder increments without overwrite"
)

tests.check(
    try {
        var parser = JSONLStreamParser()
        let first = Data("{\"type\":\"stage\",\"value\":\"trans".utf8)
        let second = Data("cribing\"}\n{\"type\":\"heartbeat\"}".utf8)
        let events = try parser.append(first) + parser.append(second) + parser.finish()
        return events == [
            HelperEvent(type: "stage", value: "transcribing"),
            HelperEvent(type: "heartbeat")
        ]
    }(),
    "JSONLStreamParser handles split Unicode-safe final line"
)

tests.check(
    try {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text-self-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("nested/output.txt")
        try AtomicFileWriter.writeText("\u{FEFF}第一行\r\n第二行\r第三行", to: file)
        let data = try Data(contentsOf: file)
        let text = String(decoding: data, as: UTF8.self)
        return text == "第一行\n第二行\n第三行" && !data.starts(with: [0xEF, 0xBB, 0xBF])
    }(),
    "AtomicFileWriter normalizes LF and strips BOM"
)

tests.check(
    try {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text-repository-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = JSONRepository<GlossaryCollection>(
            url: root.appendingPathComponent("glossaries.json")
        )
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let expected = GlossaryCollection(
            commonTerms: ["SPECIFIQUE"],
            glossaries: [
                GlossaryPreset(
                    name: "測試",
                    terms: ["OGSTM"],
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            ]
        )
        try repository.save(expected)
        return try repository.load(default: GlossaryCollection()) == expected
    }(),
    "JSONRepository round trip"
)

tests.check(
    JobStateMachine.canTransition(from: .queued, to: .validating)
        && !JobStateMachine.canTransition(from: .queued, to: .completed),
    "JobStateMachine rejects invalid shortcut"
)

tests.check(
    AppSettings.defaultValue().selectedModels[CPUArchitecture.arm64.rawValue]
        == ASRModelDescriptor.appleSiliconDefault.id,
    "AppSettings architecture model defaults"
)

tests.check(
    {
        let bf16 = ASRModelDescriptor.appleSiliconBF16
        let catalog = ASRModelDescriptor.available(for: .arm64)
        return catalog.contains(where: { $0.id == bf16.id })
            && ASRModelDescriptor.revision(forModelID: bf16.id) == bf16.revision
            && (bf16.revision?.count == 40)
    }(),
    "Apple Silicon catalog includes Qwen3-ASR 1.7B BF16 with pinned revision"
)

tests.check(
    {
        let id = UUID()
        return RecoveryScanner.parseJobDirectoryName(id.uuidString) == id
            && RecoveryScanner.parseJobDirectoryName("not-uuid") == nil
    }(),
    "RecoveryScanner accepts only UUID job directory names"
)

tests.check(
    {
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("record-to-text-selftest-recovery-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = ApplicationPaths(root: root)
            try paths.createDirectories()
            let tempJobs = root.appendingPathComponent("tmp-jobs", isDirectory: true)
            try FileManager.default.createDirectory(at: tempJobs, withIntermediateDirectories: true)

            let recoverableID = UUID()
            let recoverableDir = paths.tempRecovery
                .appendingPathComponent(recoverableID.uuidString)
            try FileManager.default.createDirectory(
                at: recoverableDir,
                withIntermediateDirectories: true
            )
            try Data("wav".utf8).write(
                to: recoverableDir.appendingPathComponent("normalized.wav")
            )
            let metadata = RecoveryScanner.RecoveryMetadata(
                schemaVersion: 1,
                jobID: recoverableID,
                sourcePath: "/tmp/a.m4a",
                failureStage: "transcribing",
                createdAt: Date(),
                technicalError: "boom"
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(metadata).write(
                to: recoverableDir.appendingPathComponent("recovery.json")
            )

            let orphanID = UUID()
            let orphanDir = tempJobs.appendingPathComponent(orphanID.uuidString)
            try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
            try Data("wav".utf8).write(
                to: orphanDir.appendingPathComponent("normalized.wav")
            )

            try FileManager.default.createDirectory(
                at: tempJobs.appendingPathComponent("ignore-me"),
                withIntermediateDirectories: true
            )

            let report = RecoveryScanner.scan(paths: paths, systemTempRoot: tempJobs)
            return report.recoverableCount == 1
                && report.orphanedCount == 1
                && report.ignoredNonUUIDDirectoryCount == 1
                && report.damagedCount == 0
        } catch {
            return false
        }
    }(),
    "RecoveryScanner classifies recoverable and orphaned leftovers without deleting"
)

tests.check(
    {
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("record-to-text-selftest-cleanup-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = ApplicationPaths(root: root)
            try paths.createDirectories()
            let tempJobs = root.appendingPathComponent("tmp-jobs", isDirectory: true)
            try FileManager.default.createDirectory(at: tempJobs, withIntermediateDirectories: true)

            let orphanID = UUID()
            let orphanDir = tempJobs.appendingPathComponent(orphanID.uuidString)
            try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
            try Data("w".utf8).write(to: orphanDir.appendingPathComponent("normalized.wav"))

            let item = RecoveryScanItem(
                jobID: orphanID,
                location: .systemTemp,
                kind: .orphaned,
                directoryPath: orphanDir.path,
                summary: "orphan",
                detail: "",
                hasNormalizedWAV: true,
                hasRecoveryJSON: false,
                hasSegmentManifest: false,
                recognizedFileNames: ["normalized.wav"],
                unknownEntryNames: []
            )
            try RecoveryScanner.deleteItem(item, paths: paths, systemTempRoot: tempJobs)

            let outside = RecoveryScanItem(
                jobID: UUID(),
                location: .systemTemp,
                kind: .orphaned,
                directoryPath: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).path,
                summary: "outside",
                detail: "",
                hasNormalizedWAV: false,
                hasRecoveryJSON: false,
                hasSegmentManifest: false,
                recognizedFileNames: [],
                unknownEntryNames: []
            )
            var rejectedOutside = false
            do {
                try RecoveryScanner.deleteItem(outside, paths: paths, systemTempRoot: tempJobs)
            } catch is RecoveryCleanupError {
                rejectedOutside = true
            }

            return !FileManager.default.fileExists(atPath: orphanDir.path) && rejectedOutside
        } catch {
            return false
        }
    }(),
    "RecoveryScanner deletes only validated managed directories"
)

tests.check(
    {
        // Cancel-before-launch must not require a running process; the flag
        // is enough for run() to abort. Smoke-check the public API exists.
        let runner = ProcessRunner()
        runner.cancelCurrent()
        return !runner.isRunning
    }(),
    "ProcessRunner cancelCurrent is safe when idle"
)

tests.check(
    {
        let runner = ProcessRunner()
        do {
            _ = try blockingAwait {
                try await runner.run(
                    executableURL: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["5"],
                    timeout: 0.5
                )
            }
            return false
        } catch ProcessRunnerError.timedOut {
            return true
        } catch {
            return false
        }
    }(),
    "ProcessRunner terminates a process that exceeds its timeout"
)

tests.check(
    {
        do {
            let modelID = "mlx-community/Qwen3-ASR-1.7B-bf16"
            let revision = "e1f6c266914abc5a46e8756e02580f834a6cf8a7"
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("record-to-text-selftest-model-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let models = root.appendingPathComponent("Models", isDirectory: true)
            let snapshot = ModelCache.hubRoot(modelsDirectory: models)
                .appendingPathComponent(ModelCache.repositoryFolderName(modelID: modelID))
                .appendingPathComponent("snapshots")
                .appendingPathComponent(revision)
            try FileManager.default.createDirectory(
                at: snapshot,
                withIntermediateDirectories: true
            )
            try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
            try Data("w".utf8).write(to: snapshot.appendingPathComponent("model.safetensors"))
            return ModelCache.isDownloaded(
                modelID: modelID,
                revision: revision,
                modelsDirectory: models
            )
                && ModelCache.repositoryFolderName(modelID: modelID)
                == "models--mlx-community--Qwen3-ASR-1.7B-bf16"
        } catch {
            return false
        }
    }(),
    "ModelCache detects App-managed hub snapshots"
)

tests.check(
    try {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text-text-validator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = root.appendingPathComponent("valid.txt")
        let empty = root.appendingPathComponent("empty.txt")
        try AtomicFileWriter.writeText("逐字稿內容", to: valid)
        try AtomicFileWriter.writeText(" \n\t", to: empty)

        guard try TextFileValidator.readNonEmptyUTF8(at: valid) == "逐字稿內容" else {
            return false
        }
        do {
            try TextFileValidator.readNonEmptyUTF8(at: empty)
            return false
        } catch TextFileValidationError.empty {
            return true
        }
    }(),
    "TextFileValidator rejects blank transcript output"
)

tests.check(
    try {
        let prompt = "這是一段中文會議錄音。請忠實轉錄音訊內容，不要摘要、改寫、刪除或補充。以下詞彙只在音訊出現時使用。"
        let clean = "前面的會議內容。"
        let echoed = "\(clean)\n\(prompt)"
        guard try OutputContractValidator.validate(
            text: clean,
            path: "/tmp/clean.txt",
            prompt: prompt
        ) == clean else {
            return false
        }
        do {
            _ = try OutputContractValidator.validate(
                text: echoed,
                path: "/tmp/echoed.txt",
                prompt: prompt
            )
            return false
        } catch OutputContractValidationError.promptEcho {
            return true
        }
    }(),
    "OutputContractValidator rejects prompt echo while keeping clean transcript"
)

tests.check(
    try {
        let prompt = """
        這是一段中文會議錄音。請忠實轉錄音訊內容，不要摘要、改寫、刪除或補充。
        以下詞彙可能出現在錄音中。只有當音訊內容相符時才使用以下寫法；沒有出現的詞彙不要自行加入：

        味全
        典華
        學習長
        """
        do {
            _ = try OutputContractValidator.validate(
                text: "味全 典華 學習長。 嗯，真正的會議內容。",
                path: "/tmp/leading-glossary-echo.txt",
                prompt: prompt
            )
            return false
        } catch OutputContractValidationError.promptEcho {
            return true
        }
    }(),
    "OutputContractValidator rejects leading glossary echo"
)

tests.check(
    try {
        let prompt = """
        這是一段中文會議錄音。請忠實轉錄音訊內容，不要摘要、改寫、刪除或補充。
        以下詞彙可能出現在錄音中。只有當音訊內容相符時才使用以下寫法；沒有出現的詞彙不要自行加入：

        味全 典華 學習長
        """
        do {
            _ = try OutputContractValidator.validate(
                text: "味全 典華 學習長。",
                path: "/tmp/space-separated-glossary-echo.txt",
                prompt: prompt
            )
            return false
        } catch OutputContractValidationError.promptEcho {
            return true
        }
    }(),
    "OutputContractValidator rejects space-separated CJK glossary echo"
)

tests.check(
    try {
        let prompt = """
        這是一段中文會議錄音。請忠實轉錄音訊內容，不要摘要、改寫、刪除或補充。
        以下詞彙可能出現在錄音中。只有當音訊內容相符時才使用以下寫法；沒有出現的詞彙不要自行加入：

        味全
        典華
        學習長
        """
        do {
            _ = try OutputContractValidator.validate(
                text: "味全。典華。學習長。",
                path: "/tmp/punctuated-glossary-echo.txt",
                prompt: prompt
            )
            return false
        } catch OutputContractValidationError.promptEcho {
            return true
        }
    }(),
    "OutputContractValidator rejects punctuated glossary echo"
)

tests.check(
    try {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text-runtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let bin = paths.runtimes
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bin,
            withIntermediateDirectories: true
        )

        let helperName = CPUArchitecture.current == .x86_64
            ? "qwen_asr_transformers_runner.py"
            : "qwen_asr_mlx_runner.py"
        for name in ["python", "ffmpeg", "ffprobe", "opencc", helperName] {
            let url = bin.appendingPathComponent(name)
            try AtomicFileWriter.writeText("#!/bin/sh\nexit 0\n", to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
        }

        let settings = AppSettings.defaultValue(developerMode: false)
        do {
            _ = try RuntimeEnvironment.resolve(
                paths: paths,
                settings: settings,
                bundledHelperURL: nil
            )
            return false
        } catch RuntimeEnvironmentError.releaseRuntimeNotVerified {
            let verified = try RuntimeEnvironment.resolve(
                paths: paths,
                settings: settings,
                bundledHelperURL: nil,
                releaseRuntimeVerifier: { _ in }
            )
            return !verified.isDeveloperRuntime
        }
    }(),
    "RuntimeEnvironment fails closed until release runtime is verified"
)

tests.check(
    try {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text-no-overwrite-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("output.txt")
        try AtomicFileWriter.writeText("先存在的內容", to: destination)
        do {
            try AtomicFileWriter.writeTextNew("不可覆寫", to: destination)
            return false
        } catch AtomicFileWriterError.destinationExists {
            return try String(contentsOf: destination, encoding: .utf8)
                == "先存在的內容"
        }
    }(),
    "AtomicFileWriter exclusive mode never replaces an existing output"
)

tests.check(
    try {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text-transcript-merge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("會議_逐字稿_第1-2段.txt")
        let second = root.appendingPathComponent("會議_逐字稿_第2-2段.txt")
        try AtomicFileWriter.writeText("第一段內容。", to: first)
        try AtomicFileWriter.writeText("第二段內容。", to: second)

        let result = try TranscriptMerger.merge([second, first], directory: root)
        let merged = try String(contentsOf: result.outputURL, encoding: .utf8)
        let secondResult = try TranscriptMerger.merge([first, second], directory: root)

        return result.inputURLs == [first, second]
            && result.outputURL.lastPathComponent == "會議_逐字稿_合併.txt"
            && merged == "第一段內容。\n\n第二段內容。"
            && secondResult.outputURL.lastPathComponent == "會議_逐字稿_合併_2.txt"
    }(),
    "TranscriptMerger sorts split TXT files and never overwrites output"
)

tests.check(
    try {
        let plan = try AudioSegmentPlanner.makePlan(sourceDuration: 31 * 60)
        return plan.expectedSegmentCount == 2
            && plan.segments.map(\.durationSeconds) == [1_200, 660]
            && AudioSegmentPlanner.productionMaximumDuration == 20 * 60
    }(),
    "AudioSegmentPlanner splits 31 minutes into 2 segments at 20-minute cap"
)

tests.check(
    try {
        let plan = try AudioSegmentPlanner.makePlan(sourceDuration: 65 * 60)
        return plan.expectedSegmentCount == 4
            && plan.segments.map(\.durationSeconds) == [1_200, 1_200, 1_200, 300]
    }(),
    "AudioSegmentPlanner splits 65 minutes into 4 segments at 20-minute cap"
)

tests.check(
    try {
        let plan = try AudioSegmentPlanner.makePlan(sourceDuration: 120 * 60)
        return plan.expectedSegmentCount == 6
            && plan.segments.allSatisfy {
                $0.durationSeconds == 1_200
            }
            && plan.segments.last?.endSeconds == 7_200
    }(),
    "AudioSegmentPlanner covers the tail of a 120 minute recording at 20-minute cap"
)

tests.check(
    try {
        let plan = try AudioSegmentPlanner.makePlan(sourceDuration: 65 * 60)
        var manifest = AudioSegmentManifest(
            jobID: UUID(),
            sourceDurationSeconds: plan.sourceDurationSeconds,
            maximumSegmentDurationSeconds:
                plan.maximumSegmentDurationSeconds,
            expectedSegmentCount: plan.expectedSegmentCount,
            segments: plan.segments.map { segment in
                AudioSegmentRecord(
                    segmentIndex: segment.index,
                    segmentCount: plan.expectedSegmentCount,
                    startSeconds: segment.startSeconds,
                    endSeconds: segment.endSeconds,
                    audioPath: segment.audioFileName,
                    outputPath: segment.transcriptFileName
                )
            }
        )
        for segment in plan.segments {
            try manifest.mark(
                segmentIndex: segment.index,
                status: .completed,
                completedEventCount: 1
            )
        }
        return try manifest.validatedCompletedSegments()
            .map(\.segmentIndex) == [1, 2, 3, 4]
    }(),
    "AudioSegmentManifest gates merge on one completion per ordered segment"
)

private let retentionSnapshot = JobSnapshot(
    modelID: "mock/model",
    glossaryID: nil,
    glossaryName: nil,
    terms: [],
    prompt: "忠實轉錄",
    outputLocationMode: .fixedDirectory,
    outputDirectory: "/tmp/output",
    keepRawTranscript: false
)

tests.check(
    {
        let queued = TranscriptionJob(
            sourcePath: "/tmp/queued.m4a",
            snapshot: retentionSnapshot,
            stage: .queued
        )
        let active = TranscriptionJob(
            sourcePath: "/tmp/active.m4a",
            snapshot: retentionSnapshot,
            stage: .transcribing
        )
        let interrupted = TranscriptionJob(
            sourcePath: "/tmp/interrupted.m4a",
            snapshot: retentionSnapshot,
            stage: .interrupted
        )
        let completed = TranscriptionJob(
            sourcePath: "/tmp/completed.m4a",
            snapshot: retentionSnapshot,
            stage: .completed
        )
        return JobRetentionPolicy.ledgerJobs(
            [queued, active, interrupted, completed],
            terminalHistoryLimit: 0
        ).map(\.id) == [queued.id, active.id, interrupted.id]
    }(),
    "JobRetentionPolicy keeps unfinished work when recentJobLimit is zero"
)

tests.check(
    {
        let queued = (0..<20).map { index in
            TranscriptionJob(
                sourcePath: "/tmp/queued-\(index).m4a",
                snapshot: retentionSnapshot,
                stage: .queued
            )
        }
        return JobRetentionPolicy.ledgerJobs(
            queued,
            terminalHistoryLimit: 2
        ).map(\.id) == queued.map(\.id)
    }(),
    "JobRetentionPolicy never truncates a queue longer than history limit"
)

tests.check(
    {
        let summary = RecentJobSummary(
            id: UUID(),
            sourcePath: "/tmp/source.m4a",
            outputPath: "/tmp/output.txt",
            stage: .completed,
            startedAt: nil,
            completedAt: nil,
            modelID: "mock/model",
            glossaryName: nil
        )
        let existing: Set<String> = ["/tmp/source.m4a"]
        return summary.fileStatus(fileExists: { existing.contains($0) })
            == .outputMissing
    }(),
    "RecentJobSummary marks a missing completed output"
)

tests.check(
    {
        let slices = TranscriptionSourceSlice.splitInHalf(durationSeconds: 7_200)
        return slices.count == 2
            && slices[0].startSeconds == 0
            && slices[0].durationSeconds == 3_600
            && slices[1].startSeconds == 3_600
            && slices[1].durationSeconds == 3_600
            && slices[0].endSeconds == slices[1].startSeconds
    }(),
    "TranscriptionSourceSlice splits a recording into ordered halves"
)

tests.check(
    {
        let slice = TranscriptionSourceSlice(
            startSeconds: 3_600,
            durationSeconds: 3_600,
            partIndex: 2,
            partCount: 2
        )
        let data = try? JSONEncoder().encode(slice)
        let decoded = data.flatMap {
            try? JSONDecoder().decode(TranscriptionSourceSlice.self, from: $0)
        }
        return decoded == slice && slice.displayName == "第 2／2 段"
    }(),
    "TranscriptionSourceSlice persists through JSON and keeps its label"
)

tests.finish()

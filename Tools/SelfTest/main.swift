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
    {
        let request = ASRRequest(
            jobID: "timeout-test",
            audioPath: "/tmp/audio.wav",
            outputPath: "/tmp/output.txt",
            modelID: ASRModelDescriptor.appleSiliconBF16.id,
            language: "Chinese",
            prompt: "prompt",
            terms: [],
            modelCacheDirectory: "/tmp/models",
            offline: true,
            chunkDurationSeconds: 120
        )
        return HelperInactivityPolicy.hardTimeout(for: request) == 600
    }(),
    "Qwen BF16 hard timeout scales beyond the old fixed three minutes"
)

tests.check(
    try {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text-chunk-checkpoint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try LocalChunkCheckpoint.createSecureDirectory(in: root)
        let checkpoint = directory.appendingPathComponent(
            "segment-0001-of-0001.chunks.json"
        )
        try Data(
            """
            {
              "schemaVersion": 1,
              "fingerprint": "\(String(repeating: "a", count: 64))",
              "totalChunks": 2,
              "completedChunks": [
                {"index": 0, "text": "已完成。", "containsSkippedAudio": false}
              ]
            }
            """.utf8
        ).write(to: checkpoint)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.path
        )
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        return LocalChunkCheckpoint.containsUsableCheckpoint(in: root)
            && permissions.map { $0 & 0o777 } == 0o700
    }(),
    "Local Qwen checkpoint discovery requires valid completed chunks and private directory permissions"
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
                bundledHelperURL: nil,
                includeSystemAudioTools: false
            )
            return false
        } catch RuntimeEnvironmentError.releaseRuntimeNotVerified {
            // Expected: cloud jobs cannot silently trust audio tools selected
            // from the unverified App-managed runtime.
        }

        var verifierWasCalled = false
        let runtime = try RuntimeEnvironment.resolve(
            paths: paths,
            settings: settings,
            bundledHelperURL: nil,
            includeSystemAudioTools: false,
            releaseRuntimeVerifier: { _ in verifierWasCalled = true }
        )
        return !runtime.isDeveloperRuntime
            && verifierWasCalled
            && FileManager.default.isExecutableFile(atPath: runtime.ffmpeg.path)
            && settings.backendType == .googleAIStudio
    }(),
    "Google AI Studio requires verification for managed ffmpeg fallback"
)

tests.check(
    try {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text-local-qwen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let bin = paths.runtimes
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
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

        var settings = AppSettings.defaultValue(developerMode: false)
        settings.backendType = .localQwen
        guard settings.backendType.displayName.contains("本機") else { return false }
        do {
            _ = try RuntimeEnvironment.resolve(
                paths: paths,
                settings: settings,
                bundledHelperURL: nil,
                includeSystemAudioTools: false
            )
            return false
        } catch RuntimeEnvironmentError.releaseRuntimeNotVerified {
            // Expected: managed local executables are not trusted by presence.
        }

        var verifierWasCalled = false
        let runtime = try RuntimeEnvironment.resolve(
            paths: paths,
            settings: settings,
            bundledHelperURL: nil,
            includeSystemAudioTools: false,
            releaseRuntimeVerifier: { _ in verifierWasCalled = true }
        )
        let report = RuntimeEnvironment.inspect(
            runtime,
            backendType: .localQwen,
            releaseRuntimeVerified: true
        )
        let components = report.components.map(\.component)
        return !runtime.isDeveloperRuntime
            && verifierWasCalled
            && report.isReady
            && components.contains(.python)
            && components.contains(.helper)
            && components.contains(.opencc)
    }(),
    "Local Qwen managed runtime fails closed until a verifier approves it"
)

tests.check(
    {
        var settings = AppSettings.defaultValue(developerMode: false)
        settings.backendType = .localQwen
        guard let data = try? JSONEncoder().encode(settings),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return false
        }
        return decoded.backendType == .localQwen
    }(),
    "AppSettings persists localQwen backend selection across JSON round-trip"
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

tests.check(
    CloudAdaptiveSegmentPlanner.splitBoundary(
        duration: 1_200,
        splitDepth: 0,
        silences: [
            DetectedSilence(startSeconds: 480, endSeconds: 481),
            DetectedSilence(startSeconds: 618, endSeconds: 620)
        ]
    ) == 619
        && CloudAdaptiveSegmentPlanner.splitBoundary(
            duration: 1_200,
            splitDepth:
                CloudAdaptiveSegmentPlanner.productionMaximumSplitDepth
        ) == nil,
    "Cloud adaptive segmentation prefers midpoint silence and obeys max depth"
)

tests.check(
    try {
        let first = AudioSegmentRecord(
            segmentIndex: 1,
            segmentCount: 2,
            startSeconds: 0,
            endSeconds: 1_200,
            audioPath: "/tmp/segment-0001.mp3",
            outputPath: "/tmp/segment-0001.txt"
        )
        let second = AudioSegmentRecord(
            segmentIndex: 2,
            segmentCount: 2,
            startSeconds: 1_200,
            endSeconds: 1_800,
            audioPath: "/tmp/segment-0002.mp3",
            outputPath: "/tmp/segment-0002.txt"
        )
        var manifest = AudioSegmentManifest(
            schemaVersion: 3,
            jobID: UUID(),
            sourceDurationSeconds: 1_800,
            maximumSegmentDurationSeconds: 1_200,
            expectedSegmentCount: 2,
            segments: [first, second]
        )
        try manifest.replaceSegment(
            segmentIndex: 1,
            with: [
                AudioSegmentRecord(
                    segmentIndex: 0,
                    segmentCount: 0,
                    startSeconds: 0,
                    endSeconds: 600,
                    audioPath: "/tmp/segment-0001-a.mp3",
                    outputPath: "/tmp/segment-0001-a.txt",
                    splitDepth: 1
                ),
                AudioSegmentRecord(
                    segmentIndex: 0,
                    segmentCount: 0,
                    startSeconds: 600,
                    endSeconds: 1_200,
                    audioPath: "/tmp/segment-0001-b.mp3",
                    outputPath: "/tmp/segment-0001-b.txt",
                    splitDepth: 1
                )
            ]
        )
        return manifest.expectedSegmentCount == 3
            && manifest.segments.map(\.segmentIndex) == [1, 2, 3]
            && manifest.segments.allSatisfy { $0.segmentCount == 3 }
            && manifest.segments.map(\.startSeconds) == [0, 600, 1_200]
    }(),
    "Adaptive cloud split renumbers a contiguous manifest"
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

tests.check(
    {
        let auth = GCloudAuthService(customGCloudPath: "/nonexistent/path/gcloud")
        return auth.resolveGCloudURL() == nil
    }(),
    "GCloudAuthService returns nil for nonexistent custom path"
)

tests.check(
    {
        let settings = AppSettings(
            defaultOutputDirectory: "/tmp/output",
            backendType: .vertexAI,
            vertexAIProjectID: "test-proj",
            vertexAILocation: "asia-east1",
            vertexAIModelID: "gemini-2.0-flash-001"
        )
        guard let data = try? JSONEncoder().encode(settings),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return false
        }
        return decoded.backendType == .vertexAI
            && decoded.vertexAIProjectID == "test-proj"
            && decoded.vertexAILocation == "asia-east1"
            && decoded.vertexAIModelID == "gemini-2.0-flash-001"
            && decoded.vertexAIIncludeSummary == false
    }(),
    "AppSettings persists Vertex AI configuration"
)

tests.check(
    {
        let settings = AppSettings(
            defaultOutputDirectory: "/tmp/output",
            backendType: .googleAIStudio,
            googleAIStudioAPIKey: "AIzaSyTestKey123",
            googleAIStudioModelID: "gemini-3.7-flash"
        )
        guard let data = try? JSONEncoder().encode(settings),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data),
              let legacyDecoded = try? JSONDecoder().decode(
                AppSettings.self,
                from: Data(
                    #"{"defaultOutputDirectory":"/tmp/output","googleAIStudioAPIKey":"legacy-key"}"#.utf8
                )
              ) else {
            return false
        }
        let json = String(decoding: data, as: UTF8.self)
        return decoded.backendType == .googleAIStudio
            && decoded.googleAIStudioAPIKey == nil
            && decoded.googleAIStudioModelID == "gemini-3.7-flash"
            && legacyDecoded.googleAIStudioAPIKey == "legacy-key"
            && !json.contains("AIzaSyTestKey123")
            && !json.contains("googleAIStudioAPIKey")
    }(),
    "AppSettings persists Google AI Studio configuration without API key"
)

tests.check(
    {
        let config = GoogleAIStudioBackend.Configuration(
            apiKey: "AIzaTestKey",
            modelID: "gemini-3.7-flash"
        )
        let backend = GoogleAIStudioBackend(configuration: config)
        let largeData = Data(count: 25 * 1024 * 1024)
        do {
            _ = try blockingAwait {
                try await backend.transcribe(audioData: largeData)
            }
            return false
        } catch let error as GoogleAIStudioError {
            if case .audioPayloadTooLarge = error {
                return true
            }
            return false
        } catch {
            return false
        }
    }(),
    "GoogleAIStudioBackend rejects audio payload exceeding maximum inline size"
)

tests.check(
    {
        let presets = GeminiModelDescriptor.presetModels
        return presets.contains(where: { $0.id == "gemini-3.7-flash" })
            && presets.contains(where: { $0.id == "gemini-3.6-flash" })
            && presets.contains(where: { $0.id == "gemini-3.1-pro-preview" })
    }(),
    "GeminiModelDescriptor contains 3.7 Flash, 3.6 Flash and 3.1 Pro presets"
)

tests.check(
    {
        let base = AppSettings(defaultOutputDirectory: "/tmp/output")
        let qwen = QuickTranscriptionChoice.qwen3ASR1_7BBF16.applying(to: base)
        let vertex = QuickTranscriptionChoice.vertexGemini37Flash.applying(to: qwen)
        let aiStudio = QuickTranscriptionChoice.aiStudioGemini37Flash.applying(
            to: vertex
        )
        return QuickTranscriptionChoice.qwen3ASR1_7BBF16.matches(qwen)
            && qwen.backendType == .localQwen
            && qwen.selectedModelID == ASRModelDescriptor.appleSiliconBF16.id
            && QuickTranscriptionChoice.vertexGemini37Flash.matches(vertex)
            && vertex.vertexAIModelID == "gemini-3.7-flash"
            && QuickTranscriptionChoice.aiStudioGemini37Flash.matches(aiStudio)
            && aiStudio.googleAIStudioModelID == "gemini-3.7-flash"
    }(),
    "Main-window quick model choices switch backend and matching model together"
)

tests.check(
    {
        let system = GeminiTranscriptPrompt.systemInstruction
        let user = GeminiTranscriptPrompt.buildUserPrompt(
            terms: ["盛和塾"],
            canonicalPrompt: "忠實轉錄。\n盛和塾",
            timeOffsetSeconds: 1_200
        )
        return system.contains("[00:00 - 05:00]")
            && system.contains("講者 1：")
            && system.contains("不得猜測身分")
            && system.contains("不同講者回合之間必須保留一個空白行")
            && system.contains("[05:00 - 10:00]")
            && user.contains("20:00")
            && user.contains("不要從 00:00 重新計時")
            && user.contains("第一行即從 [20:00 - ...] 開始")
            && user.components(separatedBy: "盛和塾").count - 1 == 1
    }(),
    "Gemini cloud prompt requests speaker turns and absolute time ranges without duplicating glossary terms"
)

tests.check(
    {
        var roster = SpeakerRoster()
        roster.observe(
            transcript: "彭建文：大家好，我是彭建文。\n郝哥：大家好，我是郝旭烈郝哥。",
            segmentIndex: 1
        )
        let later = "建文：繼續下一題。\n豪哥：好，我補充。"
        roster.observe(transcript: later, segmentIndex: 2)
        return roster.identities.map(\.canonicalLabel) == ["彭建文", "郝旭烈"]
            && roster.normalizingSpeakerLabels(in: later)
                == "彭建文：繼續下一題。\n郝旭烈：好，我補充。"
            && roster.promptInstruction?.contains("不要改名") == true
    }(),
    "Speaker roster keeps canonical labels across cloud segments"
)

tests.check(
    {
        let low = GeminiGenerationConfig.make(
            maxOutputTokens: 16_384,
            modelID: "gemini-3.7-flash",
            thinkingLevel: .low
        )
        let high = GeminiGenerationConfig.make(
            maxOutputTokens: 16_384,
            modelID: "gemini-3.7-flash",
            thinkingLevel: .high
        )
        let custom = GeminiGenerationConfig.make(
            maxOutputTokens: 16_384,
            modelID: "custom-model",
            thinkingLevel: .high
        )
        let lowThinking = (low["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String
        let highThinking = (high["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String
        return lowThinking == "low"
            && highThinking == "high"
            && custom["thinkingConfig"] == nil
    }(),
    "Gemini thinking level is included in Gemini 3 generation config"
)

// MARK: - Gemini Cloud Transport Hardening Tests

tests.check(
    {
        let directPOSIX40 = NSError(domain: NSPOSIXErrorDomain, code: 40, userInfo: [NSLocalizedDescriptionKey: "Message too long"])
        let directPOSIX2 = NSError(domain: NSPOSIXErrorDomain, code: 2, userInfo: [:])
        let cfStream40 = NSError(domain: "kCFErrorDomainCFNetwork", code: -1005, userInfo: [
            "_kCFStreamErrorCodeKey": 40,
            "_kCFStreamErrorDomainKey": 1
        ])
        let wrappedPOSIX40 = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [
            NSUnderlyingErrorKey: directPOSIX40
        ])
        let nestedWrapped = NSError(domain: "CustomDomain", code: 999, userInfo: [
            NSUnderlyingErrorKey: wrappedPOSIX40
        ])

        return GeminiTransportHelper.isPOSIXMessageTooLarge(directPOSIX40)
            && !GeminiTransportHelper.isPOSIXMessageTooLarge(directPOSIX2)
            && GeminiTransportHelper.isPOSIXMessageTooLarge(cfStream40)
            && GeminiTransportHelper.isPOSIXMessageTooLarge(wrappedPOSIX40)
            && GeminiTransportHelper.isPOSIXMessageTooLarge(nestedWrapped)
    }(),
    "GeminiTransportHelper recursively unwraps and detects POSIX 40 / EMSGSIZE errors"
)

tests.check(
    {
        do {
            let testData = Data("{\"test\":\"gemini_transport_payload\"}".utf8)
            let tempURL = try GeminiTransportHelper.writeTemporaryRequestFile(data: testData, prefix: "selftest_req")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            guard FileManager.default.fileExists(atPath: tempURL.path) else {
                return false
            }
            let readData = try Data(contentsOf: tempURL)
            let attributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            let posixPermissions = attributes[.posixPermissions] as? NSNumber

            return readData == testData && (posixPermissions?.intValue == 0o600 || posixPermissions?.intValue == 0o700)
        } catch {
            return false
        }
    }(),
    "GeminiTransportHelper writes request file with tight permissions"
)

tests.check(
    {
        let vertexError = VertexAIError.transportMessageTooLarge.localizedDescription
        let aiStudioError = GoogleAIStudioError.transportMessageTooLarge.localizedDescription

        return vertexError.contains("傳輸通道")
            && vertexError.contains("不是音檔超過 Gemini 時長上限")
            && !vertexError.contains("無法完成作業。訊息太長")
            && aiStudioError.contains("傳輸通道")
            && aiStudioError.contains("不是音檔超過 Gemini 時長上限")
    }(),
    "Transport errors provide explicit channel diagnostic text without vague message too long"
)

tests.check(
    {
        let settings = AppSettings(
            defaultOutputDirectory: "/tmp/output",
            backendType: .vertexAI,
            vertexAIProjectID: "test-proj",
            vertexAILocation: "global",
            vertexAIModelID: "gemini-3.7-flash",
            vertexAIGCSBucket: "my-custom-bucket",
            vertexAIIncludeSummary: false
        )
        guard let data = try? JSONEncoder().encode(settings),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return false
        }
        let snapshot = JobSnapshot(
            modelID: settings.vertexAIModelID,
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "忠實轉錄",
            outputLocationMode: settings.outputLocationMode,
            outputDirectory: settings.defaultOutputDirectory,
            keepRawTranscript: false,
            backendType: settings.backendType,
            googleAIStudioAPIKey: "ledger-secret",
            vertexAIProjectID: settings.vertexAIProjectID,
            vertexAILocation: settings.vertexAILocation,
            vertexAIModelID: settings.vertexAIModelID,
            vertexAIGCSBucket: settings.vertexAIGCSBucket,
            vertexAIIncludeSummary: settings.vertexAIIncludeSummary
        )
        guard let snapData = try? JSONEncoder().encode(snapshot),
              let snapDecoded = try? JSONDecoder().decode(JobSnapshot.self, from: snapData) else {
            return false
        }
        let snapshotJSON = String(decoding: snapData, as: UTF8.self)
        var currentSettings = AppSettings(
            defaultOutputDirectory: "/tmp/current",
            backendType: .localQwen,
            customGCloudPath: "/current/gcloud"
        )
        currentSettings.developerMode = true
        currentSettings.customPythonPath = "/current/python"
        let runtimeSettings = currentSettings.applyingRuntimeConfiguration(
            from: snapDecoded
        )
        return decoded.vertexAIGCSBucket == "my-custom-bucket"
            && snapDecoded.vertexAIGCSBucket == "my-custom-bucket"
            && snapDecoded.googleAIStudioAPIKey == nil
            && !snapshotJSON.contains("ledger-secret")
            && !snapshotJSON.contains("googleAIStudioAPIKey")
            && runtimeSettings.backendType == .vertexAI
            && runtimeSettings.vertexAILocation == "global"
            && runtimeSettings.developerMode
            && runtimeSettings.customPythonPath == "/current/python"
            && runtimeSettings.customGCloudPath == "/current/gcloud"
    }(),
    "JobSnapshot persists transcription configuration but keeps runtime authorization live"
)

private final class MockTransportURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockTransportURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockError", code: 1))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

tests.check(
    {
        URLProtocol.registerClass(MockTransportURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(MockTransportURLProtocol.self)
            MockTransportURLProtocol.requestHandler = nil
        }

        var callCount = 0
        MockTransportURLProtocol.requestHandler = { request in
            callCount += 1
            if callCount == 1 {
                throw NSError(domain: NSPOSIXErrorDomain, code: 40, userInfo: [
                    NSLocalizedDescriptionKey: "Message too long"
                ])
            }
            let successJSON = """
            {
                "candidates": [
                    {
                        "content": {
                            "parts": [{"text": "這是重試成功逐字稿"}],
                            "role": "model"
                        },
                        "finishReason": "STOP"
                    }
                ]
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(successJSON.utf8))
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockTransportURLProtocol.self]
        let session = URLSession(configuration: config)

        let backend = GoogleAIStudioBackend(
            urlSession: session,
            configuration: GoogleAIStudioBackend.Configuration(
                apiKey: "AIzaTestKey",
                modelID: "gemini-3.7-flash",
                useFilesAPI: false
            )
        )

        do {
            let transcript = try blockingAwait {
                try await backend.transcribe(audioData: Data("small audio".utf8))
            }
            return transcript.contains("這是重試成功逐字稿") && callCount >= 1
        } catch {
            return false
        }
    }(),
    "GoogleAIStudioBackend handles POSIX 40 with ephemeral retry and succeeds"
)

tests.check(
    {
        URLProtocol.registerClass(MockTransportURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(MockTransportURLProtocol.self)
            MockTransportURLProtocol.requestHandler = nil
        }

        var sawInit = false
        var sawUpload = false
        var sawGenerate = false

        MockTransportURLProtocol.requestHandler = { request in
            let urlString = request.url?.absoluteString ?? ""

            if urlString.contains("/upload/v1beta/files") && request.httpMethod == "POST" {
                sawInit = true
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json",
                        "X-Goog-Upload-URL": "https://generativelanguage.googleapis.com/upload-target/files/mock123"
                    ]
                )!
                return (response, Data("{}".utf8))
            }

            if urlString.contains("/upload-target/files/mock123") {
                sawUpload = true
                let fileMetadata = """
                {
                    "file": {
                        "name": "files/mock123",
                        "uri": "https://generativelanguage.googleapis.com/v1beta/files/mock123",
                        "state": "ACTIVE"
                    }
                }
                """
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(fileMetadata.utf8))
            }

            if urlString.contains(":generateContent") {
                sawGenerate = true
                let responseJSON = """
                {
                    "candidates": [
                        {
                            "content": {
                                "parts": [{"text": "由 Files API 轉錄成功之逐字稿"}],
                                "role": "model"
                            },
                            "finishReason": "STOP"
                        }
                    ]
                }
                """
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(responseJSON.utf8))
            }

            if urlString.contains("files/mock123") && request.httpMethod == "DELETE" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
                return (response, Data("{}".utf8))
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (response, Data("{}".utf8))
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockTransportURLProtocol.self]
        let session = URLSession(configuration: config)

        let backend = GoogleAIStudioBackend(
            urlSession: session,
            configuration: GoogleAIStudioBackend.Configuration(
                apiKey: "AIzaTestKey",
                modelID: "gemini-3.7-flash",
                useFilesAPI: true
            )
        )

        do {
            let transcript = try blockingAwait {
                try await backend.transcribe(audioData: Data("mock audio data".utf8))
            }
            return transcript.contains("由 Files API 轉錄成功之逐字稿")
                && sawInit
                && sawUpload
                && sawGenerate
        } catch {
            return false
        }
    }(),
    "GoogleAIStudioBackend uploads via Files API and decouples audio from generateContent body"
)

tests.check(
    {
        URLProtocol.registerClass(MockTransportURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(MockTransportURLProtocol.self)
            MockTransportURLProtocol.requestHandler = nil
        }

        let tempGCloudDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mock-gcloud-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempGCloudDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempGCloudDir) }

        let mockGCloud = tempGCloudDir.appendingPathComponent("gcloud")
        try? "#!/bin/sh\nif [ \"$1\" = \"auth\" ]; then echo 'mock-access-token'; exit 0; fi\nif [ \"$1\" = \"config\" ]; then echo 'mock-project'; exit 0; fi\n".write(to: mockGCloud, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockGCloud.path)

        var sawGCSUpload = false
        var sawGenerate = false

        MockTransportURLProtocol.requestHandler = { request in
            let urlString = request.url?.absoluteString ?? ""

            if urlString.contains("storage.googleapis.com/upload/storage/v1/b/test-storage-bucket/o") && request.httpMethod == "POST" {
                sawGCSUpload = true
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data("{}".utf8))
            }

            if urlString.contains(":generateContent") {
                sawGenerate = true
                let responseJSON = """
                {
                    "candidates": [
                        {
                            "content": {
                                "parts": [{"text": "由 Vertex AI GCS 轉錄成功之逐字稿"}],
                                "role": "model"
                            },
                            "finishReason": "STOP"
                        }
                    ]
                }
                """
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(responseJSON.utf8))
            }

            if urlString.contains("storage.googleapis.com/storage/v1/b/test-storage-bucket/o") && request.httpMethod == "DELETE" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: [:])!
                return (response, Data())
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (response, Data("{}".utf8))
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockTransportURLProtocol.self]
        let session = URLSession(configuration: config)

        let backend = VertexAIGeminiBackend(
            authService: GCloudAuthService(customGCloudPath: mockGCloud.path),
            urlSession: session,
            configuration: VertexAIGeminiBackend.Configuration(
                projectID: "mock-proj",
                location: "global",
                modelID: "gemini-3.7-flash",
                gcsBucket: "test-storage-bucket"
            )
        )

        do {
            let transcript = try blockingAwait {
                try await backend.transcribe(audioData: Data("mock audio data".utf8))
            }
            return transcript.contains("由 Vertex AI GCS 轉錄成功之逐字稿")
                && sawGCSUpload
                && sawGenerate
        } catch {
            return false
        }
    }(),
    "VertexAIGeminiBackend uploads to GCS and references gs:// URI without inline audio"
)

// MARK: - Lenient Collection Loader Tests

private func makeSelfTestSnapshot() -> JobSnapshot {
    JobSnapshot(
        modelID: "mock/model",
        glossaryID: nil,
        glossaryName: nil,
        terms: [],
        prompt: "忠實轉錄",
        outputLocationMode: .fixedDirectory,
        outputDirectory: "/tmp/output",
        keepRawTranscript: false
    )
}

private func makeSelfTestISO8601Encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try container.encode(formatter.string(from: date))
    }
    return encoder
}

tests.check(
    try {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text-lenient-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("job-ledger.json")

        let job = TranscriptionJob(
            sourcePath: "/tmp/audio.m4a",
            snapshot: makeSelfTestSnapshot()
        )
        let encoded = try makeSelfTestISO8601Encoder()
            .encode(JobLedgerCollection(jobs: [job]))
        guard
            var object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
            var jobs = object["jobs"] as? [[String: Any]]
        else {
            return false
        }
        jobs.insert(["sourcePath": 42], at: 0) // Wrong type: record must be skipped.
        object["jobs"] = jobs
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let outcome = LenientCollectionLoader.loadJobLedger(at: url)
        guard outcome.skippedRecordCount == 1,
              outcome.value.jobs.count == 1,
              outcome.value.jobs.first?.id == job.id,
              outcome.diagnosticMessage != nil else {
            return false
        }

        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        return siblings.contains { $0.hasPrefix("job-ledger.json.corrupt-") }
    }(),
    "Lenient ledger load skips an incompatible record and quarantines the damaged file"
)

tests.check(
    try {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text-lenient-garbage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("job-ledger.json")
        try Data("這不是 JSON".utf8).write(to: url)

        let outcome = LenientCollectionLoader.loadJobLedger(at: url)
        guard outcome.value.jobs.isEmpty, outcome.diagnosticMessage != nil else {
            return false
        }

        // A follow-up save recreates a usable store; the backup stays.
        let repository = JSONRepository<JobLedgerCollection>(url: url)
        try repository.save(JobLedgerCollection())
        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        return siblings.contains { $0.hasPrefix("job-ledger.json.corrupt-") }
            && siblings.contains("job-ledger.json")
    }(),
    "Unparsable ledger is quarantined instead of being overwritten by a future save"
)

tests.check(
    {
        let json: [String: Any] = [
            "promptFeedback": [
                "blockReason": "OTHER",
                "safetyRatings": [
                    [
                        "category": "HARM_CATEGORY_HARASSMENT",
                        "probability": "NEGLIGIBLE",
                        "blocked": false
                    ]
                ]
            ],
            "usageMetadata": [
                "promptTokenCount": 9999,
                "promptTokensDetails": [
                    ["modality": "AUDIO", "tokenCount": 9800]
                ]
            ],
            "modelVersion": "gemini-3.7-flash-exp",
            "responseId": "resp-blocked-1"
        ]
        guard let diagnostics = GeminiPromptFeedbackParser.diagnosticsIfBlocked(
            from: json,
            httpStatusCode: 200
        ) else {
            return false
        }
        let studioError = GoogleAIStudioError.promptBlocked(diagnostics)
        let vertexError = VertexAIError.promptBlocked(diagnostics)
        let description = studioError.errorDescription ?? ""
        return diagnostics.blockReason == "OTHER"
            && diagnostics.httpStatusCode == 200
            && diagnostics.responseID == "resp-blocked-1"
            && diagnostics.modelVersion == "gemini-3.7-flash-exp"
            && diagnostics.promptTokenCount == 9999
            && diagnostics.audioTokenCount == 9800
            && diagnostics.safetyRatings.contains(where: { $0.category == "HARM_CATEGORY_HARASSMENT" })
            && description.contains("HTTP 200")
            && description.contains("promptFeedback.blockReason=OTHER")
            && !description.contains("HTTP 400")
            && !description.contains("內容安全政策攔截")
            && diagnostics.logSummary.contains("responseId=resp-blocked-1")
            && diagnostics.logSummary.contains("audioTokenCount=9800")
            && studioError.errorDescription == vertexError.errorDescription
    }(),
    "promptFeedback OTHER is fail-closed with diagnostics, not a fake HTTP 400"
)

tests.check(
    {
        let json: [String: Any] = [
            "promptFeedback": [
                "blockReason": "PROHIBITED_CONTENT",
                "blockReasonMessage": "policy"
            ]
        ]
        guard let diagnostics = GeminiPromptFeedbackParser.diagnosticsIfBlocked(
            from: json,
            httpStatusCode: 200
        ) else {
            return false
        }
        let description = VertexAIError.promptBlocked(diagnostics).errorDescription ?? ""
        return diagnostics.isExplicitSafetyPolicy
            && description.contains("內容安全政策攔截")
            && !description.contains("HTTP 400")
    }(),
    "Vertex promptFeedback PROHIBITED_CONTENT stays a policy block without fake HTTP 400"
)

tests.check(
    {
        let json: [String: Any] = [
            "promptFeedback": [
                "blockReason": 2
            ],
            "responseId": "resp-int-other"
        ]
        guard let diagnostics = GeminiPromptFeedbackParser.diagnosticsIfBlocked(
            from: json,
            httpStatusCode: 200
        ) else {
            return false
        }
        return diagnostics.blockReason == "OTHER"
            && diagnostics.responseID == "resp-int-other"
    }(),
    "integer promptFeedback.blockReason 2 maps to OTHER"
)

tests.check(
    {
        let json: [String: Any] = [
            "usageMetadata": [
                "promptTokenCount": 12,
                "thoughtsTokenCount": 34,
                "candidatesTokenCount": 0
            ],
            "modelVersion": "gemini-3.7-flash-exp",
            "responseId": "resp-empty-1"
        ]
        let summary = GeminiResponseInventory.summary(
            from: json,
            reason: "no_candidates",
            rawByteCount: 88
        )
        return summary.contains("no_candidates")
            && summary.contains("candidateCount=0")
            && summary.contains("responseId=resp-empty-1")
            && summary.contains("thoughtsTokenCount=34")
            && summary.contains("rawBytes=88")
    }(),
    "empty Gemini response inventory captures responseId and token counts"
)

tests.check(
    !GeminiTranscriptFinishReason.allowsUsableText("MAX_TOKENS")
        && GeminiTranscriptFinishReason.allowsUsableText("stop")
        && GeminiTranscriptFinishReason.isTruncated("max_tokens")
        && !GeminiTranscriptFinishReason.allowsUsableText("OTHER")
        && GeminiTranscriptFinishReason.isSafetyBlock("SAFETY"),
    "MAX_TOKENS is fail-closed; only STOP is a complete transcript"
)

// MARK: - Process Tree Termination Test

tests.check(
    {
        // A shell that spawns its own child: killing the tree must take down
        // BOTH processes, even though post-launch setpgid usually loses the
        // race against exec. Before descendant-walking termination existed,
        // this scenario could also hang run() forever on inherited pipes.
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text-tree-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let runner = ProcessRunner()
        do {
            _ = try blockingAwait {
                try await runner.run(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "sleep 60 & echo $! > '\(marker.path)'; wait"
                    ],
                    requireSuccess: false,
                    timeout: 0.5
                )
            }
            return false
        } catch ProcessRunnerError.timedOut {
            // Expected.
        } catch {
            return false
        }

        guard let childPIDString = try? String(contentsOf: marker, encoding: .utf8),
              let childPID = Int32(childPIDString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }

        // SIGKILL pass lands ~4s after the initial signal; poll briefly past it.
        for _ in 0..<80 {
            if Darwin.kill(childPID, 0) == -1 && errno == ESRCH {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }(),
    "ProcessRunner timeout kills spawned grandchildren, not just the direct child"
)

// MARK: - Cloud Retry Policy Tests

tests.check(
    {
        URLProtocol.registerClass(MockTransportURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(MockTransportURLProtocol.self)
            MockTransportURLProtocol.requestHandler = nil
        }

        let tempGCloudDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mock-gcloud-retry-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempGCloudDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempGCloudDir) }
        let mockGCloud = tempGCloudDir.appendingPathComponent("gcloud")
        try? "#!/bin/sh\nif [ \"$1\" = \"auth\" ]; then echo 'mock-access-token'; exit 0; fi\n".write(to: mockGCloud, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockGCloud.path)

        var generateCalls = 0
        MockTransportURLProtocol.requestHandler = { request in
            let urlString = request.url?.absoluteString ?? ""

            if urlString.contains(":generateContent") {
                generateCalls += 1
                if generateCalls == 1 {
                    // Transient server overload must be retried, not fatal.
                    let busy = #"{"error":{"code":503,"message":"overloaded"}}"#
                    return (
                        HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                        Data(busy.utf8)
                    )
                }
                let responseJSON = """
                {"candidates":[{"content":{"parts":[{"text":"Vertex 重試後成功的逐字稿"}],"role":"model"},"finishReason":"STOP"}]}
                """
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    Data(responseJSON.utf8)
                )
            }

            if urlString.contains("storage.googleapis.com") && request.httpMethod == "DELETE" {
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: [:])!, Data())
            }

            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, Data("{}".utf8))
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockTransportURLProtocol.self]
        let session = URLSession(configuration: config)

        let backend = VertexAIGeminiBackend(
            authService: GCloudAuthService(customGCloudPath: mockGCloud.path),
            urlSession: session,
            configuration: VertexAIGeminiBackend.Configuration(
                projectID: "retry-proj",
                location: "global",
                modelID: "gemini-3.7-flash",
                gcsBucket: nil
            )
        )

        do {
            let transcript = try blockingAwait {
                try await backend.transcribe(audioData: Data("small audio".utf8))
            }
            return transcript.contains("Vertex 重試後成功的逐字稿") && generateCalls == 2
        } catch {
            return false
        }
    }(),
    "VertexAIGeminiBackend retries transient HTTP 503 and succeeds without failing the job"
)

tests.check(
    {
        URLProtocol.registerClass(MockTransportURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(MockTransportURLProtocol.self)
            MockTransportURLProtocol.requestHandler = nil
        }

        var generateCalls = 0
        MockTransportURLProtocol.requestHandler = { request in
            generateCalls += 1
            if generateCalls <= 4 {
                // Primary model exhausts its retry budget with server errors.
                let busy = #"{"error":{"code":503,"message":"high demand"}}"#
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    Data(busy.utf8)
                )
            }
            // The fallback model answers with a structurally empty response.
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(#"{"candidates": []}"#.utf8)
            )
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockTransportURLProtocol.self]
        let session = URLSession(configuration: config)

        let backend = GoogleAIStudioBackend(
            urlSession: session,
            configuration: GoogleAIStudioBackend.Configuration(
                apiKey: "AIzaTestKey",
                modelID: "gemini-3.7-flash",
                useFilesAPI: false,
                fallbackPolicy: .flashOnly
            )
        )

        do {
            _ = try blockingAwait {
                try await backend.transcribe(audioData: Data("small audio".utf8))
            }
            return false
        } catch GoogleAIStudioError.emptyResponse {
            // The fallback's own failure must surface, not the stale primary 503.
            return true
        } catch {
            return false
        }
    }(),
    "GoogleAIStudioBackend fallback failure surfaces its real error instead of masking it"
)

tests.finish()

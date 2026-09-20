// Opt-in real-provider acceptance probe. Never included in ordinary tests.
// Link against the release Core objects of the exact candidate being validated.
// Usage: probe MODE SOURCE OUTPUT_ROOT
// MODE: qwen | studio | vertex-cancel | vertex-resume
// Cloud modes make paid requests using the existing account. Local mode is offline.
// All journals, recovery files and transcripts go under OUTPUT_ROOT. The installed
// App supplies the audio tools and Qwen helper; its live journal is never changed.
import Darwin
import Foundation
import LocalAuthentication
import RecordToTextCore
import Security

private struct ProbeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
private struct FinalizationProbe {
    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ProbeError(message: message) }
    }

    static func studioKey() throws -> String {
        // Respect Keychain access control; do not prompt or change its ACL.
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.specifique.record-to-text",
            kSecAttrAccount as String: "google-ai-studio-api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw ProbeError(message: "AI Studio credential unavailable (Keychain status \(status)).")
        }
        return key
    }

    static func main() async {
        setbuf(stdout, nil)
        do { try await run() }
        catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func run() async throws {
        try require(CommandLine.arguments.count == 4, "Usage: probe MODE SOURCE OUTPUT_ROOT")
        let mode = CommandLine.arguments[1]
        try require(["qwen", "studio", "vertex-cancel", "vertex-resume"].contains(mode), "Unknown mode")
        let source = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let root = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true).standardizedFileURL
        let fm = FileManager.default
        let live = ApplicationPaths.live()
        try require(!root.path.hasPrefix(live.root.path), "Use an isolated output root")
        let sourceHash = try FileIntegrity.sha256(of: source)
        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: paths.models.path) {
            try fm.createSymbolicLink(at: paths.models, withDestinationURL: live.models)
        }
        try paths.createDirectories()
        let output = root.appendingPathComponent("outputs")
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var settings = try decoder.decode(AppSettings.self, from: Data(contentsOf: live.settings))
        let backend: ASRBackendType = mode == "qwen" ? .localQwen : (mode == "studio" ? .googleAIStudio : .vertexAI)
        settings.backendType = backend
        let app = URL(fileURLWithPath: "/Applications/record-to-text.app/Contents")
        let helper = app.appendingPathComponent("Resources/record-to-text_RecordToTextApp.bundle/qwen_asr_mlx_runner.py")
        let runtime = try RuntimeEnvironment.resolve(paths: live, settings: settings,
            bundledHelperURL: helper,
            bundledFFmpegURL: app.appendingPathComponent("Helpers/ffmpeg"),
            bundledFFprobeURL: app.appendingPathComponent("Helpers/ffprobe"))
        if backend == .localQwen {
            try require(runtime.helper == helper, "Qwen must use the installed helper")
        }
        let prompt = try PromptBuilder.build(commonTerms: [], glossaryTerms: [], temporaryTerms: [])
        let key = mode == "studio" ? try studioKey() : nil
        let snapshot = JobSnapshot(modelID: settings.selectedModelID,
            modelRevision: ASRModelDescriptor.revision(forModelID: settings.selectedModelID),
            glossaryID: nil, glossaryName: nil, terms: prompt.terms, prompt: prompt.prompt,
            outputLocationMode: .fixedDirectory, outputDirectory: output.path,
            keepRawTranscript: true, backendType: backend, googleAIStudioAPIKey: key,
            googleAIStudioModelID: settings.googleAIStudioModelID,
            vertexAIProjectID: settings.vertexAIProjectID,
            vertexAILocation: settings.vertexAILocation,
            vertexAIModelID: settings.vertexAIModelID,
            vertexAIGCSBucket: settings.vertexAIGCSBucket,
            geminiThinkingLevel: settings.geminiThinkingLevel,
            cloudFallbackPolicy: settings.cloudFallbackPolicy,
            silenceAwareCloudSegmentation: settings.silenceAwareCloudSegmentation)
        let savedJobURL = root.appendingPathComponent("cancelled-job.json")
        var job = TranscriptionJob(sourcePath: source.path, snapshot: snapshot)
        if mode == "vertex-resume" {
            job = try decoder.decode(TranscriptionJob.self, from: Data(contentsOf: savedJobURL))
            try require(job.sourcePath == source.path, "Resume source mismatch")
            let baseline = try decoder.decode([String: String].self,
                from: Data(contentsOf: root.appendingPathComponent("cancel-source.json")))
            try require(baseline["sha256"] == sourceHash, "Source changed since cancellation")
            job.stage = .queued
        }
        let engine = TranscriptionEngine(runtime: runtime, paths: paths)
        let duration = try await AudioProbeService(executableURL: runtime.ffprobe).probe(source).duration
        var events: [String] = []
        var cancelledAfterCheckpoint = false
        var manifestData: Data?
        var rawMerge: String?
        var captureError: Error?
        let working = fm.temporaryDirectory.appendingPathComponent("record-to-text/\(job.id.uuidString)")
        let manifestURL = working.appendingPathComponent(RecoveryScanner.segmentManifestFileName)
        let started = Date()
        print("START mode=\(mode) job=\(job.id) sourceSeconds=\(duration)")
        do {
            let result = try await engine.run(job: job, offline: backend == .localQwen) { update in
                switch update {
                case let .log(level, message):
                    let safe = key.map { message.replacingOccurrences(of: $0, with: "[REDACTED]") } ?? message
                    events.append("\(level): \(safe)")
                    print("\(level): \(safe)")
                case let .warning(code, message):
                    events.append("warning \(code): \(message)")
                    print("warning: \(code)")
                case let .stage(stage):
                    print("stage: \(stage.rawValue)")
                    if stage == .writingOutput, backend != .localQwen {
                        do { rawMerge = try String(contentsOf: working.appendingPathComponent("cloud-merged-raw.txt"), encoding: .utf8) }
                        catch { captureError = error }
                    }
                case let .progress(_, _, unit):
                    if unit.hasPrefix("percent|"), backend != .localQwen {
                        do { manifestData = try Data(contentsOf: manifestURL) }
                        catch { captureError = error }
                    }
                    if mode == "vertex-cancel", unit.hasPrefix("percent|1|"), !cancelledAfterCheckpoint {
                        cancelledAfterCheckpoint = true
                        withUnsafeCurrentTask { $0?.cancel() }
                        print("CANCEL after first durable segment; before second request")
                    }
                }
            }
            try require(mode != "vertex-cancel", "Cancellation was not triggered")
            if let captureError { throw captureError }
            try save(result, to: root.appendingPathComponent("\(mode)-result.json"))
            if let manifestData {
                try manifestData.write(to: root.appendingPathComponent("\(mode)-manifest.json"), options: .atomic)
                let manifest = try decoder.decode(AudioSegmentManifest.self, from: manifestData)
                _ = try manifest.validatedCompletedSegments()
                try require(abs(manifest.segments.first!.startSeconds) < 0.05, "Missing source start")
                try require(abs(manifest.segments.last!.endSeconds - duration) < 0.05, "Missing source end")
                for pair in zip(manifest.segments, manifest.segments.dropFirst()) {
                    try require(abs(pair.0.endSeconds - pair.1.startSeconds) < 0.001, "Segment coverage gap or overlap")
                }
                if mode == "vertex-resume" {
                    try require(manifest.segments.first?.reusedFromCheckpoint == true, "First segment was resent")
                    let preserved = try String(contentsOf: root.appendingPathComponent("first-segment.txt"), encoding: .utf8)
                    let text = try String(contentsOf: result.outputURL, encoding: .utf8)
                    // OpenCC may convert characters; compare the captured raw merge.
                    try require(rawMerge?.hasPrefix(preserved) == true, "Completed segment content was altered or lost")
                    try require(!text.isEmpty, "Empty final output")
                    let sentinel = root.appendingPathComponent("sentinel.json")
                    let existing = try decoder.decode([String: String].self, from: Data(contentsOf: sentinel))
                    let prior = URL(fileURLWithPath: existing["path"]!)
                    try require(try FileIntegrity.sha256(of: prior) == existing["sha256"], "Existing TXT was overwritten")
                    try require(result.outputURL != prior, "Output path collision")
                }
            }
            try require(!result.containsSkippedAudio && result.incompleteCloudSegmentIndices.isEmpty, "Result contains explicit gaps")
            try require(try FileIntegrity.sha256(of: source) == sourceHash, "Source file changed")
            try save(events, to: root.appendingPathComponent("\(mode)-events.json"))
            print("PASS mode=\(mode) wallSeconds=\(Date().timeIntervalSince(started)) output=\(result.outputURL.path)")
        } catch is CancellationError where mode == "vertex-cancel" {
            let recovery = paths.tempRecovery.appendingPathComponent(job.id.uuidString)
            let checkpoint = try CloudResumeCheckpointLoader.load(recoveryDirectory: recovery,
                job: job, sourceDuration: duration, sourceTimeOffset: 0,
                maximumSegmentDuration: AudioSegmentPlanner.productionMaximumDuration, paths: paths)
            try require(cancelledAfterCheckpoint && checkpoint.reusableSegments.count == 1, "Expected exactly one reusable segment")
            job.stage = .cancelled
            job.resumeFromRecoveryDirectory = recovery.path
            try save(job, to: savedJobURL)
            try save(["sha256": sourceHash], to: root.appendingPathComponent("cancel-source.json"))
            let first = checkpoint.reusableSegments[1]!.transcript
            try first.write(to: root.appendingPathComponent("first-segment.txt"), atomically: true, encoding: .utf8)
            let sentinel = output.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "_逐字稿.txt")
            try require(!fm.fileExists(atPath: sentinel.path), "Unexpected pre-existing final output")
            try "Existing output must survive resume.\n".write(to: sentinel, atomically: false, encoding: .utf8)
            try save(["path": sentinel.path, "sha256": try FileIntegrity.sha256(of: sentinel)],
                to: root.appendingPathComponent("sentinel.json"))
            try require(try FileIntegrity.sha256(of: source) == sourceHash, "Source file changed")
            try save(events, to: root.appendingPathComponent("\(mode)-events.json"))
            print("PASS cancelled; persisted one reusable segment; exit before resume")
        }
    }
}

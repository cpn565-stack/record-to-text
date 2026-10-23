import Foundation
import XCTest
@testable import RecordToTextCore

/// Opt-in, offline smoke test for an already downloaded model and a short local
/// audio sample. All job state and published output stay in an isolated root.
final class LocalLiveModelSmokeTests: XCTestCase {
    func testOfflineModelThroughRealCheckpointPipeline() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let models = env["R2T_SMOKE_MODELS"],
              let audio = env["R2T_SMOKE_AUDIO"],
              let python = env["R2T_SMOKE_PYTHON"] else {
            throw XCTSkip("Set R2T_SMOKE_MODELS, R2T_SMOKE_AUDIO and R2T_SMOKE_PYTHON to run offline model inference")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-live-model-\(UUID().uuidString)")
        let paths = ApplicationPaths(root: root)
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: paths.models)
        try FileManager.default.createSymbolicLink(atPath: paths.models.path, withDestinationPath: models)

        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runtime = ResolvedRuntime(
            python: URL(fileURLWithPath: python),
            ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            ffprobe: URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe"),
            opencc: URL(fileURLWithPath: "/opt/homebrew/bin/opencc"),
            helper: repo.appendingPathComponent("Sources/RecordToTextApp/Resources/qwen_asr_mlx_runner.py"),
            isDeveloperRuntime: true
        )
        let engine = TranscriptionEngine(
            cloudNetworkEnvironment: .init(), runtime: runtime, paths: paths,
            runner: ProcessRunner(), maximumASRSegmentDuration: 6
        )
        let job = TranscriptionJob(
            sourcePath: audio,
            snapshot: JobSnapshot(
                modelID: "mlx-community/Qwen3-ASR-1.7B-bf16",
                modelRevision: "e1f6c266914abc5a46e8756e02580f834a6cf8a7",
                glossaryID: nil, glossaryName: nil, terms: [], prompt: "",
                outputLocationMode: .fixedDirectory, outputDirectory: root.path,
                keepRawTranscript: false, backendType: .localQwen,
                localSilenceAwareSegmentation: false
            )
        )
        var logs: [String] = []
        let result = try await engine.run(
            job: job, offline: true, allowMissingPrompt: false,
            update: { update in
                if case let .log(_, message) = update { logs.append(message) }
            }
        )
        let transcript = try String(contentsOf: result.outputURL)
        XCTAssertFalse(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(result.containsSkippedAudio)
        XCTAssertTrue(logs.contains { $0.hasPrefix("模型內容 manifest：") }, logs.joined(separator: "\n"))
        XCTAssertFalse(logs.contains { $0.contains("本次不建立 local-checkpoint-v2") })
        print("LIVE_MODEL_SMOKE: published \(transcript.count) characters offline through the real checkpoint pipeline")
    }
}

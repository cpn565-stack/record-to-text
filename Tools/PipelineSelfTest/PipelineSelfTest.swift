import Darwin
import Foundation
import RecordToTextCore

@main
private struct PipelineSelfTest {
    static func main() async {
        do {
            try await run()
            switch ProcessInfo.processInfo.environment["RECORD_TO_TEXT_MOCK_SCENARIO"] {
            case "failure":
                print("PASS mock ASR failure → transcribing-stage recovery → temp cleanup")
            case "slow":
                print("PASS slow mock ASR → cancellation → temp cleanup")
            case "segmented":
                print("PASS coordinator split → ordered ASR merge → tail phrase")
            case "segmented-failure":
                print("PASS final segment failure → recovery draft, no partial final TXT")
            case "segmented-middle-failure":
                print("PASS middle segment failure → recovery draft, no partial final TXT")
            case "segmented-blank":
                print("PASS blank final segment → recovery draft, no partial final TXT")
            case "segmented-token-limit":
                print("PASS irreducible 30-second token limit → explicit gap, continued output")
            case "segmented-no-completed":
                print("PASS final segment without completed → recovery draft, no partial final TXT")
            default:
                print("PASS ffprobe → ffmpeg → mock ASR → OpenCC → atomic TXT")
            }
            Darwin.exit(0)
        } catch {
            print("FAIL pipeline self-test: \(error)")
            Darwin.exit(1)
        }
    }

    private static func run() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("record-to-text-pipeline-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let sourceDirectory = root.appendingPathComponent(
            "中文 路徑（測試）'single-quote'",
            isDirectory: true
        )
        let sourceURL = sourceDirectory.appendingPathComponent("會議 音檔（第一場）.m4a")
        let outputDirectory = root.appendingPathComponent("轉出的文字", isDirectory: true)
        let supportPaths = ApplicationPaths(
            root: root.appendingPathComponent("Application Support", isDirectory: true)
        )
        try fileManager.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )

        let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        let ffprobe = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        let opencc = URL(fileURLWithPath: "/opt/homebrew/bin/opencc")
        for tool in [ffmpeg, ffprobe, opencc] {
            guard fileManager.isExecutableFile(atPath: tool.path) else {
                throw SelfTestError.missingTool(tool.path)
            }
        }

        let scenario = ProcessInfo.processInfo.environment[
            "RECORD_TO_TEXT_MOCK_SCENARIO"
        ]
        let isSegmentedScenario = scenario?.hasPrefix("segmented") == true
        let generator = ProcessRunner()
        _ = try await generator.run(
            executableURL: ffmpeg,
            arguments: [
                "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi",
                "-i", "sine=frequency=440:sample_rate=44100",
                "-t", isSegmentedScenario ? "2.2" : "0.5",
                "-c:a", "aac",
                sourceURL.path
            ]
        )
        let sourceHash = try FileIntegrity.sha256(of: sourceURL)

        let executableDirectory = URL(
            fileURLWithPath: CommandLine.arguments[0]
        ).deletingLastPathComponent()
        let mockHelper = executableDirectory
            .appendingPathComponent("record-to-text-mock-helper")
        guard fileManager.isExecutableFile(atPath: mockHelper.path) else {
            throw SelfTestError.missingMockHelper(mockHelper.path)
        }

        let runtime = ResolvedRuntime(
            python: URL(fileURLWithPath: "/usr/bin/env"),
            ffmpeg: ffmpeg,
            ffprobe: ffprobe,
            opencc: opencc,
            helper: mockHelper,
            isDeveloperRuntime: true
        )
        let mockModelID: String
        switch scenario {
        case "failure":
            mockModelID = "mock/failure"
        case "slow":
            mockModelID = "mock/slow"
        case "segmented":
            mockModelID = "mock/segmented"
        case "segmented-failure":
            mockModelID = "mock/segmentedFailure"
        case "segmented-middle-failure":
            mockModelID = "mock/segmentedMiddleFailure"
        case "segmented-blank":
            mockModelID = "mock/segmentedBlank"
        case "segmented-token-limit":
            mockModelID = "mock/segmentedTokenLimit"
        case "segmented-no-completed":
            mockModelID = "mock/segmentedNoCompleted"
        default:
            mockModelID = "mock/success"
        }
        let prompt = try PromptBuilder.build(
            commonTerms: ["SPECIFIQUE"],
            glossaryTerms: ["OGSTM"],
            temporaryTerms: ["測試專有名詞"]
        )
        let snapshot = JobSnapshot(
            modelID: mockModelID,
            glossaryID: "self-test",
            glossaryName: "Self Test",
            terms: prompt.terms,
            prompt: prompt.prompt,
            outputLocationMode: .fixedDirectory,
            outputDirectory: outputDirectory.path,
            keepRawTranscript: false
        )
        let job = TranscriptionJob(sourcePath: sourceURL.path, snapshot: snapshot)
        let engine = TranscriptionEngine(
            runtime: runtime,
            paths: supportPaths,
            maximumASRSegmentDuration: isSegmentedScenario ? 1 : 1_200
        )
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("record-to-text", isDirectory: true)
            .appendingPathComponent(job.id.uuidString, isDirectory: true)
        var observedStages: [TranscriptionStage] = []
        var observedOverallProgress: [(current: Double, total: Double, unit: String)] = []
        let expectsFailure = scenario == "failure"
            || (scenario?.hasPrefix("segmented-") == true
                && scenario != "segmented-token-limit")
        let expectsCancellation = scenario == "slow"

        if expectsCancellation {
            let task = Task {
                try await engine.run(job: job) { update in
                    if case let .stage(stage) = update {
                        observedStages.append(stage)
                    }
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            task.cancel()
            engine.cancelCurrentJob()
            do {
                _ = try await task.value
                throw SelfTestError.expectedCancellationMissing
            } catch is CancellationError {
                guard try FileIntegrity.sha256(of: sourceURL) == sourceHash else {
                    throw SelfTestError.sourceChanged
                }
                if fileManager.fileExists(atPath: supportPaths.tempRecovery.path) {
                    let remaining = try fileManager.contentsOfDirectory(
                        atPath: supportPaths.tempRecovery.path
                    )
                    guard remaining.isEmpty else {
                        throw SelfTestError.cancelledRecoveryRemains
                    }
                }
                guard !fileManager.fileExists(atPath: workingDirectory.path) else {
                    throw SelfTestError.temporaryFilesRemain
                }
                return
            }
        }

        let result: PipelineResult
        do {
            result = try await engine.run(job: job) { update in
                if case let .stage(stage) = update {
                    observedStages.append(stage)
                } else if case let .progress(current, total, unit) = update {
                    observedOverallProgress.append((current, total, unit))
                }
            }
        } catch let error as PipelineExecutionError where expectsFailure {
            guard
                let recovery = error.recoveryDirectory,
                fileManager.fileExists(
                    atPath: recovery.appendingPathComponent("normalized.wav").path
                )
            else {
                throw SelfTestError.recoveryMissing
            }
            struct RecoveryMetadata: Decodable {
                let failureStage: String
            }
            let metadata = try JSONDecoder().decode(
                RecoveryMetadata.self,
                from: Data(
                    contentsOf: recovery.appendingPathComponent("recovery.json")
                )
            )
            guard metadata.failureStage == TranscriptionStage.transcribing.rawValue else {
                throw SelfTestError.unexpectedRecoveryStage(metadata.failureStage)
            }
            if isSegmentedScenario {
                let manifestURL = recovery.appendingPathComponent(
                    "segment-manifest.json"
                )
                guard fileManager.fileExists(atPath: manifestURL.path) else {
                    throw SelfTestError.segmentManifestMissing
                }
                let manifest = try JSONDecoder().decode(
                    AudioSegmentManifest.self,
                    from: Data(contentsOf: manifestURL)
                )
                let expectedStatuses: [AudioSegmentStatus]
                let expectedCompletionCounts: [Int]
                if scenario == "segmented-middle-failure" {
                    expectedStatuses = [.completed, .failed, .prepared]
                    expectedCompletionCounts = [1, 0, 0]
                } else {
                    expectedStatuses = [.completed, .completed, .failed]
                    expectedCompletionCounts = [1, 1, 0]
                }
                guard
                    manifest.expectedSegmentCount == 3,
                    manifest.segments.map(\.segmentIndex) == [1, 2, 3],
                    manifest.segments.map(\.status) == expectedStatuses,
                    manifest.segments.map(\.completedEventCount)
                        == expectedCompletionCounts
                else {
                    throw SelfTestError.unexpectedSegmentManifest(manifest)
                }
                let partialTranscriptURL = recovery.appendingPathComponent(
                    "partial-transcript.txt"
                )
                guard
                    fileManager.fileExists(atPath: partialTranscriptURL.path),
                    let partialTranscript = try? String(
                        contentsOf: partialTranscriptURL,
                        encoding: .utf8
                    ),
                    partialTranscript.contains("未完成逐字稿"),
                    partialTranscript.contains("这是第 1 段。")
                else {
                    throw SelfTestError.partialRecoveryTranscriptMissing
                }
                if fileManager.fileExists(atPath: outputDirectory.path) {
                    let partialOutputs = try fileManager.contentsOfDirectory(
                        at: outputDirectory,
                        includingPropertiesForKeys: nil
                    ).filter {
                        $0.lastPathComponent.hasSuffix("_逐字稿.txt")
                    }
                    guard partialOutputs.isEmpty else {
                        throw SelfTestError.partialFinalOutputExists(
                            partialOutputs.map(\.path)
                        )
                    }
                }
            }
            guard try FileIntegrity.sha256(of: sourceURL) == sourceHash else {
                throw SelfTestError.sourceChanged
            }
            guard !fileManager.fileExists(atPath: workingDirectory.path) else {
                throw SelfTestError.temporaryFilesRemain
            }
            return
        }

        if expectsFailure {
            throw SelfTestError.expectedFailureMissing
        }

        let output = try String(contentsOf: result.outputURL, encoding: .utf8)
        if isSegmentedScenario {
            let first = output.range(of: "這是第 1 段。")
            let second = output.range(of: "這是第 2 段。")
            let third = output.range(of: "這是第 3 段。")
            let lines = output.split(
                separator: "\n",
                omittingEmptySubsequences: false
            )
            let tailPhraseCount = output.components(
                separatedBy: "尾段唯一驗證句"
            ).count - 1
            let sawSegmentedProgressUnits = observedOverallProgress.contains {
                $0.unit.hasPrefix("percent|") && $0.total == 100
            }
            let sawContinuousGrowth = observedOverallProgress.contains {
                $0.current > 5 && $0.current < 100 && $0.total == 100
            }
            let sawNearComplete = observedOverallProgress.contains {
                $0.current >= 95 && $0.total == 100
            }
            let expectedLineCount = scenario == "segmented-token-limit" ? 4 : 3
            guard
                let first,
                let second,
                let third,
                first.lowerBound < second.lowerBound,
                second.lowerBound < third.lowerBound,
                lines.count == expectedLineCount,
                tailPhraseCount == 1,
                sawSegmentedProgressUnits,
                sawContinuousGrowth,
                sawNearComplete
            else {
                throw SelfTestError.unexpectedSegmentedOutput(output)
            }
            if scenario == "segmented-token-limit" {
                guard
                    result.containsSkippedAudio,
                    output.contains("缺少 30 秒"),
                    output.contains("已跳過此片段")
                else {
                    throw SelfTestError.missingSkippedAudioMarker
                }
            }
        } else {
            guard output.contains("這是 mock 逐字稿"), output.contains("OGSTM") else {
                throw SelfTestError.unexpectedOutput(output)
            }
        }
        guard result.outputURL.lastPathComponent == "會議 音檔（第一場）_逐字稿.txt" else {
            throw SelfTestError.unexpectedName(result.outputURL.lastPathComponent)
        }
        guard try FileIntegrity.sha256(of: sourceURL) == sourceHash else {
            throw SelfTestError.sourceChanged
        }
        guard !fileManager.fileExists(
            atPath: supportPaths.tempRecovery
                .appendingPathComponent(job.id.uuidString)
                .path
        ) else {
            throw SelfTestError.temporaryFilesRemain
        }
        guard !fileManager.fileExists(atPath: workingDirectory.path) else {
            throw SelfTestError.temporaryFilesRemain
        }
        guard
            observedStages.contains(.convertingAudio),
            observedStages.contains(.transcribing),
            observedStages.contains(.convertingTraditionalChinese),
            observedStages.last == .completed
        else {
            throw SelfTestError.missingStages(observedStages)
        }
    }
}

private enum SelfTestError: LocalizedError {
    case missingTool(String)
    case missingMockHelper(String)
    case unexpectedOutput(String)
    case unexpectedSegmentedOutput(String)
    case missingSkippedAudioMarker
    case unexpectedName(String)
    case sourceChanged
    case temporaryFilesRemain
    case missingStages([TranscriptionStage])
    case expectedFailureMissing
    case expectedCancellationMissing
    case recoveryMissing
    case cancelledRecoveryRemains
    case unexpectedRecoveryStage(String)
    case segmentManifestMissing
    case unexpectedSegmentManifest(AudioSegmentManifest)
    case partialFinalOutputExists([String])
    case partialRecoveryTranscriptMissing

    var errorDescription: String? {
        switch self {
        case let .missingTool(path):
            return "Missing developer tool: \(path)"
        case let .missingMockHelper(path):
            return "Build record-to-text-mock-helper first: \(path)"
        case let .unexpectedOutput(output):
            return "Unexpected OpenCC output: \(output)"
        case let .unexpectedSegmentedOutput(output):
            return "Segmented output is incomplete or out of order: \(output)"
        case .missingSkippedAudioMarker:
            return "Token-limit recovery output did not include an explicit skipped-audio marker"
        case let .unexpectedName(name):
            return "Unexpected output name: \(name)"
        case .sourceChanged:
            return "Source audio hash changed"
        case .temporaryFilesRemain:
            return "Successful job left recovery files"
        case let .missingStages(stages):
            return "Missing expected stages: \(stages.map(\.rawValue))"
        case .expectedFailureMissing:
            return "Mock failure scenario unexpectedly completed"
        case .expectedCancellationMissing:
            return "Slow mock scenario unexpectedly completed instead of cancelling"
        case .recoveryMissing:
            return "Failed job did not preserve normalized.wav in Temp-Recovery"
        case .cancelledRecoveryRemains:
            return "Cancelled job left files in Temp-Recovery"
        case let .unexpectedRecoveryStage(stage):
            return "Recovery metadata recorded the wrong failure stage: \(stage)"
        case .segmentManifestMissing:
            return "Failed segmented job did not preserve segment-manifest.json"
        case let .unexpectedSegmentManifest(manifest):
            return "Unexpected segment manifest after failure: \(manifest)"
        case let .partialFinalOutputExists(paths):
            return "Failed segmented job committed partial final output: \(paths)"
        case .partialRecoveryTranscriptMissing:
            return "Failed segmented job did not preserve a usable recovery transcript"
        }
    }
}

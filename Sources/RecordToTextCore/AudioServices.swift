import Foundation

public enum AudioServiceError: LocalizedError {
    case unsupportedExtension(String)
    case noAudioStream
    case invalidProbeResponse
    case insufficientDiskSpace(required: Int64, available: Int64)
    case outputMissing(String)
    case outputEmpty(String)
    case outputInvalidUTF8(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedExtension(fileExtension):
            return "不支援 .\(fileExtension) 音檔。請使用 M4A、MP3、WAV、AAC 或 FLAC。"
        case .noAudioStream:
            return "檔案中找不到可讀取的音訊軌。"
        case .invalidProbeResponse:
            return "ffprobe 回傳的音檔資訊無法解讀。"
        case let .insufficientDiskSpace(required, available):
            return "磁碟空間不足。需要約 \(required) bytes，目前可用 \(available) bytes。"
        case let .outputMissing(path):
            return "外部程序結束後找不到預期輸出：\(path)"
        case let .outputEmpty(path):
            return "外部程序產生了空白或截斷的輸出：\(path)"
        case let .outputInvalidUTF8(path):
            return "外部程序產生的文字不是有效的 UTF-8：\(path)"
        }
    }
}

public final class AudioProbeService {
    public static let supportedExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aac", "flac"
    ]

    private let executableURL: URL
    private let runner: ProcessRunner

    public init(executableURL: URL, runner: ProcessRunner = ProcessRunner()) {
        self.executableURL = executableURL
        self.runner = runner
    }

    public func probe(_ sourceURL: URL) async throws -> AudioMetadata {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(fileExtension) else {
            throw AudioServiceError.unsupportedExtension(fileExtension)
        }

        let result = try await runner.run(
            executableURL: executableURL,
            arguments: [
                "-v", "error",
                "-select_streams", "a:0",
                "-show_entries", "stream=codec_name,sample_rate,channels:format=duration",
                "-of", "json",
                sourceURL.path
            ]
        )

        struct Probe: Decodable {
            struct Stream: Decodable {
                let codec_name: String?
                let sample_rate: String?
                let channels: Int?
            }

            struct Format: Decodable {
                let duration: String?
            }

            let streams: [Stream]
            let format: Format?
        }

        let decoded: Probe
        do {
            decoded = try JSONDecoder().decode(Probe.self, from: result.standardOutput)
        } catch {
            throw AudioServiceError.invalidProbeResponse
        }

        guard let stream = decoded.streams.first else {
            throw AudioServiceError.noAudioStream
        }
        guard
            let durationText = decoded.format?.duration,
            let duration = Double(durationText),
            duration.isFinite,
            duration > 0
        else {
            throw AudioServiceError.invalidProbeResponse
        }

        return AudioMetadata(
            duration: duration,
            codecName: stream.codec_name ?? "unknown",
            sampleRate: Int(stream.sample_rate ?? "") ?? 0,
            channels: stream.channels ?? 0
        )
    }

    public func validateDiskSpace(
        for metadata: AudioMetadata,
        temporaryDirectory: URL
    ) throws {
        let values = try temporaryDirectory.resourceValues(
            forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ]
        )
        let available: Int64?
        if let important = values.volumeAvailableCapacityForImportantUsage {
            available = important
        } else if let standard = values.volumeAvailableCapacity {
            available = Int64(standard)
        } else {
            available = nil
        }
        guard let available, available > 0 else {
            // Some File Provider and sandboxed volumes do not report capacity.
            // The write itself remains the authoritative failure boundary.
            return
        }
        guard available >= metadata.estimatedPCMBytes else {
            throw AudioServiceError.insufficientDiskSpace(
                required: metadata.estimatedPCMBytes,
                available: available
            )
        }
    }
}

public final class FFmpegService {
    private let executableURL: URL
    private let runner: ProcessRunner

    public init(executableURL: URL, runner: ProcessRunner) {
        self.executableURL = executableURL
        self.runner = runner
    }

    public func normalize(
        sourceURL: URL,
        destinationURL: URL,
        duration: Double,
        progress: @escaping (Double, Double) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        _ = try await runner.run(
            executableURL: executableURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-i", sourceURL.path,
                "-vn",
                "-ar", "16000",
                "-ac", "1",
                "-c:a", "pcm_s16le",
                "-progress", "pipe:1",
                "-nostats",
                destinationURL.path
            ],
            stdoutLineHandler: { line in
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else {
                    return
                }

                if parts[0] == "out_time_us", let microseconds = Double(parts[1]) {
                    progress(min(microseconds / 1_000_000, duration), duration)
                } else if parts[0] == "out_time_ms", let microseconds = Double(parts[1]) {
                    // ffmpeg historically labels microseconds as out_time_ms.
                    progress(min(microseconds / 1_000_000, duration), duration)
                }
            }
        )

        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw AudioServiceError.outputMissing(destinationURL.path)
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: destinationURL.path
        )
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 44 else {
            throw AudioServiceError.outputEmpty(destinationURL.path)
        }
    }
}

public final class OpenCCService {
    private let executableURL: URL
    private let runner: ProcessRunner

    public init(executableURL: URL, runner: ProcessRunner) {
        self.executableURL = executableURL
        self.runner = runner
    }

    public func convert(
        sourceURL: URL,
        destinationURL: URL
    ) async throws {
        _ = try await runner.run(
            executableURL: executableURL,
            arguments: [
                "-i", sourceURL.path,
                "-o", destinationURL.path,
                "-c", "s2twp.json"
            ]
        )

        do {
            try TextFileValidator.readNonEmptyUTF8(at: destinationURL)
        } catch TextFileValidationError.missing {
            throw AudioServiceError.outputMissing(destinationURL.path)
        } catch TextFileValidationError.empty {
            throw AudioServiceError.outputEmpty(destinationURL.path)
        } catch TextFileValidationError.invalidUTF8 {
            throw AudioServiceError.outputInvalidUTF8(destinationURL.path)
        }
    }
}

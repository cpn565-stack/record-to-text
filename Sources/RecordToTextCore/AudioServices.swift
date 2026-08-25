import Foundation

private enum AudioProcessTimeouts {
    static let minimumTemporaryReserve: Int64 = 64 * 1_024 * 1_024
    static let minimumOutputReserve: Int64 = 32 * 1_024 * 1_024
    static let probe: TimeInterval = 30
    static let probeInactivity: TimeInterval = 15
    static let ffmpegInactivity: TimeInterval = 5 * 60
    static let openCC: TimeInterval = 10 * 60

    static func ffmpeg(for duration: Double) -> TimeInterval {
        // A generous upper bound for slow disks or very long recordings,
        // while still preventing a wedged ffmpeg from living forever.
        max(2 * 60, duration * 10 + 2 * 60)
    }
}

public enum AudioServiceError: LocalizedError {
    case unsupportedExtension(String)
    case noAudioStream
    case invalidProbeResponse
    case insufficientDiskSpace(required: Int64, available: Int64)
    case insufficientDiskSpaceAt(path: String, required: Int64, available: Int64)
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
        case let .insufficientDiskSpaceAt(path, required, available):
            return "磁碟空間不足：\(path)。至少需要約 \(required) bytes，目前可用 \(available) bytes。"
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
            ],
            timeout: AudioProcessTimeouts.probe,
            inactivityTimeout: AudioProcessTimeouts.probeInactivity
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
        temporaryDirectory: URL,
        outputDirectory: URL,
        pcmWorkingCopies: Int = 1
    ) throws {
        let copyCount = Int64(max(pcmWorkingCopies, 1))
        let multiplication = metadata.estimatedPCMBytes.multipliedReportingOverflow(
            by: copyCount
        )
        let pcmBytes = multiplication.overflow
            ? Int64.max
            : multiplication.partialValue
        let temporaryRequired = pcmBytes.addingReportingOverflow(
            AudioProcessTimeouts.minimumTemporaryReserve
        )
        let requiredTemporary = temporaryRequired.overflow
            ? Int64.max
            : temporaryRequired.partialValue

        if let available = try availableCapacity(at: temporaryDirectory),
           available < requiredTemporary
        {
            throw AudioServiceError.insufficientDiskSpace(
                required: requiredTemporary,
                available: available
            )
        }

        guard let outputAvailable = try availableCapacity(at: outputDirectory) else {
            // Some File Provider and sandboxed volumes do not report capacity.
            // The write itself remains the authoritative failure boundary.
            return
        }
        guard outputAvailable >= AudioProcessTimeouts.minimumOutputReserve else {
            throw AudioServiceError.insufficientDiskSpaceAt(
                path: outputDirectory.path,
                required: AudioProcessTimeouts.minimumOutputReserve,
                available: outputAvailable
            )
        }
    }

    private func availableCapacity(at directory: URL) throws -> Int64? {
        let values = try directory.resourceValues(
            forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ]
        )
        // On some macOS volumes (including temporary/sandbox locations), the
        // important-usage value is reported as zero even when the standard
        // capacity is available. Treat non-positive values as unavailable so
        // a transient resource-value quirk does not reject every recording.
        let important = values.volumeAvailableCapacityForImportantUsage
            .flatMap { $0 > 0 ? $0 : nil }
        let standard = values.volumeAvailableCapacity
            .flatMap { $0 > 0 ? Int64($0) : nil }
        return [important, standard].compactMap { $0 }.min()
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
            timeout: AudioProcessTimeouts.ffmpeg(for: duration),
            inactivityTimeout: AudioProcessTimeouts.ffmpegInactivity,
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

    public func extractSegment(
        sourceURL: URL,
        destinationURL: URL,
        startSeconds: Double,
        durationSeconds: Double
    ) async throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        _ = try await runner.run(
            executableURL: executableURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-ss", Self.ffmpegTime(startSeconds),
                "-i", sourceURL.path,
                "-t", Self.ffmpegTime(durationSeconds),
                "-vn",
                "-ar", "16000",
                "-ac", "1",
                "-c:a", "pcm_s16le",
                destinationURL.path
            ],
            timeout: AudioProcessTimeouts.ffmpeg(for: durationSeconds),
            inactivityTimeout: AudioProcessTimeouts.ffmpegInactivity
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

    /// 將音訊轉為輕量 16kHz 單聲道 MP3 格式（約 24kbps），以供雲端 API 快速上傳
    public func compressForCloud(
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
                "-b:a", "24k",
                "-c:a", "libmp3lame",
                "-progress", "pipe:1",
                "-nostats",
                destinationURL.path
            ],
            timeout: AudioProcessTimeouts.ffmpeg(for: duration),
            inactivityTimeout: AudioProcessTimeouts.ffmpegInactivity,
            stdoutLineHandler: { line in
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else {
                    return
                }

                if parts[0] == "out_time_us", let microseconds = Double(parts[1]) {
                    progress(min(microseconds / 1_000_000, duration), duration)
                } else if parts[0] == "out_time_ms", let microseconds = Double(parts[1]) {
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
        guard byteCount > 100 else {
            throw AudioServiceError.outputEmpty(destinationURL.path)
        }
    }

    /// 截取特定時間區段並壓縮為輕量 16kHz 單聲道 MP3 格式（約 24kbps）以供雲端傳輸
    public func extractSegmentForCloud(
        sourceURL: URL,
        destinationURL: URL,
        startSeconds: Double,
        durationSeconds: Double
    ) async throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        _ = try await runner.run(
            executableURL: executableURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-ss", Self.ffmpegTime(startSeconds),
                "-i", sourceURL.path,
                "-t", Self.ffmpegTime(durationSeconds),
                "-vn",
                "-ar", "16000",
                "-ac", "1",
                "-b:a", "24k",
                "-c:a", "libmp3lame",
                destinationURL.path
            ],
            timeout: AudioProcessTimeouts.ffmpeg(for: durationSeconds),
            inactivityTimeout: AudioProcessTimeouts.ffmpegInactivity
        )

        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw AudioServiceError.outputMissing(destinationURL.path)
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: destinationURL.path
        )
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 100 else {
            throw AudioServiceError.outputEmpty(destinationURL.path)
        }
    }

    private static func ffmpegTime(_ seconds: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), seconds)
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
            ],
            timeout: AudioProcessTimeouts.openCC
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

import CryptoKit
import Darwin
import Foundation
import os

/// Errors raised while establishing or verifying local audio identity.
///
/// The codes match the taxonomy in the phase 0 spec §7 so the UI can explain a
/// refusal without exposing transcript or prompt content.
public enum LocalSourceIdentityError: LocalizedError, Equatable {
    case sourceUnreadable(path: String, underlying: String)
    case sourceChanged(path: String)
    case sourceMissing(path: String)
    case snapshotFailed(path: String, underlying: String)
    case hashMismatch(expected: String, actual: String)
    case pcmMismatch(field: String, expected: String, actual: String)
    case unexpectedWaveLayout(path: String, reason: String)
    case decoderUnavailable(underlying: String)

    /// Stable machine-readable code, safe to log and persist.
    public var code: String {
        switch self {
        case .sourceUnreadable: return "local_source_unreadable"
        case .sourceChanged: return "local_source_changed"
        case .sourceMissing: return "local_source_changed"
        case .snapshotFailed: return "local_snapshot_failed"
        case .hashMismatch: return "local_source_changed"
        case .pcmMismatch: return "local_pcm_mismatch"
        case .unexpectedWaveLayout: return "local_checkpoint_invalid"
        case .decoderUnavailable: return "local_runtime_unavailable"
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .sourceUnreadable(path, underlying):
            return "無法完整讀取來源音檔，已停止（不啟動 ASR）：\(path)\n\(underlying)"
        case let .sourceChanged(path):
            return "來源音檔在處理期間被修改，已停止以避免混用不同內容：\(path)"
        case let .sourceMissing(path):
            return "找不到來源音檔，無法開始或續跑新推論：\(path)"
        case let .snapshotFailed(path, underlying):
            return "無法建立來源 snapshot：\(path)\n\(underlying)"
        case let .hashMismatch(expected, actual):
            return "來源內容 hash 不符（預期 \(expected.prefix(12))…，實際 \(actual.prefix(12))…），拒絕沿用既有結果。"
        case let .pcmMismatch(field, expected, actual):
            return "\(field) 的 PCM digest 不符（預期 \(expected.prefix(12))…，實際 \(actual.prefix(12))…）。"
        case let .unexpectedWaveLayout(path, reason):
            return "WAV 結構不符預期，無法計算 PCM digest：\(path)\n\(reason)"
        case let .decoderUnavailable(underlying):
            return "無法取得 ffmpeg 解碼器身分：\(underlying)"
        }
    }
}

/// Cancellable streaming SHA-256.
///
/// Reads in 1 MiB batches so a multi-gigabyte recording is never resident in
/// memory, checks cancellation between batches, and propagates read errors
/// instead of hashing a truncated prefix.
public enum LocalContentHasher {
    public static let batchByteCount = 1_048_576

    public static func sha256(
        of url: URL,
        fileManager: FileManager = .default
    ) async throws -> String {
        try Task.checkCancellation()
        try requireReadableFile(url, fileManager: fileManager)
        return try await hashDetached { signal in
            try Self.hashStream(url: url, offset: 0, length: nil, signal: signal)
        }
    }

    /// Bounded to a `[offset, offset+length)` window of the file.
    public static func sha256(
        of url: URL,
        offset: UInt64,
        length: UInt64,
        fileManager: FileManager = .default
    ) async throws -> String {
        try Task.checkCancellation()
        try requireReadableFile(url, fileManager: fileManager)
        return try await hashDetached { signal in
            try Self.hashStream(url: url, offset: offset, length: length, signal: signal)
        }
    }

    /// Detached tasks do not inherit the caller's cancellation, so the flag is
    /// handed over explicitly and polled once per batch.
    private final class CancellationSignal: @unchecked Sendable {
        private let storage = OSAllocatedUnfairLock(initialState: false)
        var isCancelled: Bool { storage.withLock { $0 } }
        func cancel() { storage.withLock { $0 = true } }
    }

    private static func requireReadableFile(_ url: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw LocalSourceIdentityError.sourceMissing(path: url.path)
        }
    }

    /// Hashing a multi-gigabyte recording must neither block the main actor nor
    /// occupy a cooperative-pool thread for the whole read, so it runs detached
    /// at utility priority while still honouring cancellation between batches.
    private static func hashDetached(
        _ operation: @escaping @Sendable (CancellationSignal) throws -> String
    ) async throws -> String {
        let signal = CancellationSignal()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try operation(signal)
            }.value
        } onCancel: {
            signal.cancel()
        }
    }

    private static func hashStream(
        url: URL,
        offset: UInt64,
        length: UInt64?,
        signal: CancellationSignal
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        if offset > 0 {
            try handle.seek(toOffset: offset)
        }

        var hasher = SHA256()
        var remaining = length
        while true {
            if signal.isCancelled || Task.isCancelled {
                throw CancellationError()
            }
            let requested = remaining.map { min(UInt64(batchByteCount), $0) }
                ?? UInt64(batchByteCount)
            guard requested > 0 else { break }

            let data: Data
            do {
                data = try handle.read(upToCount: Int(requested)) ?? Data()
            } catch {
                throw LocalSourceIdentityError.sourceUnreadable(
                    path: url.path,
                    underlying: error.localizedDescription
                )
            }
            if data.isEmpty { break }
            hasher.update(data: data)
            if let remainingValue = remaining {
                remaining = remainingValue - UInt64(data.count)
            }
        }

        // An early EOF while bytes were still expected means the file was
        // truncated underneath us; hashing the prefix would forge an identity.
        if let remainingValue = remaining, remainingValue > 0 {
            throw LocalSourceIdentityError.sourceUnreadable(
                path: url.path,
                underlying: "檔案在讀完預期範圍前結束，尚缺 \(remainingValue) bytes。"
            )
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// App-private source snapshot so the pipeline never re-reads a file that an
/// external process may overwrite mid-run.
public enum LocalSourceSnapshot {
    /// Copy-on-write clone when the volume supports it, streaming copy otherwise.
    public static func create(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        let cloned = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                clonefile(sourcePath, destinationPath, 0)
            }
        }
        if cloned == 0 {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destinationURL.path
            )
            return
        }

        // EXDEV / ENOTSUP / EPERM all mean "clone unavailable here".
        try streamingCopy(from: sourceURL, to: destinationURL)
    }

    private static func streamingCopy(from sourceURL: URL, to destinationURL: URL) throws {
        guard sourceURL.withUnsafeFileSystemRepresentation({ sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return false }
                return copyfile(
                    sourcePath,
                    destinationPath,
                    nil,
                    UInt32(COPYFILE_DATA | COPYFILE_EXCL)
                ) == 0
            }
        }) else {
            throw LocalSourceIdentityError.snapshotFailed(
                path: sourceURL.path,
                underlying: String(cString: strerror(errno))
            )
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )
    }
}

/// Versioned description of how source audio becomes the PCM the model sees.
///
/// Bumping `version` invalidates every persisted WAV cache: a new decoder or
/// normalization rule must never silently reuse old samples.
public struct LocalNormalizationProfile: Codable, Equatable, Sendable {
    public static let current = LocalNormalizationProfile(
        version: "rec2t-local-normalize-v1",
        sampleRate: 16_000,
        channels: 1,
        codec: "pcm_s16le",
        byteOrder: "little",
        trackSelection: "a:0",
        stripVideo: true,
        sliceSeek: "input-seek-on-source",
        rootExtraction: "output-seek-on-normalized-pcm"
    )

    public let version: String
    public let sampleRate: Int
    public let channels: Int
    public let codec: String
    public let byteOrder: String
    public let trackSelection: String
    public let stripVideo: Bool
    public let sliceSeek: String
    public let rootExtraction: String

    /// ffmpeg arguments that realize this profile for a whole-file normalize.
    public var normalizeArguments: [String] {
        ["-vn", "-ar", String(sampleRate), "-ac", String(channels), "-c:a", codec]
    }
}

/// Actual decoder build, not merely the executable path.
public struct LocalDecoderIdentity: Codable, Equatable, Sendable {
    public let executablePath: String
    public let versionLine: String
    public let signature: String

    public static func capture(
        ffmpegURL: URL,
        runner: ProcessRunner
    ) async throws -> LocalDecoderIdentity {
        let result: ProcessResult
        do {
            result = try await runner.run(
                executableURL: ffmpegURL,
                arguments: ["-hide_banner", "-version"],
                requireSuccess: true,
                timeout: 30,
                inactivityTimeout: 15
            )
        } catch {
            throw LocalSourceIdentityError.decoderUnavailable(
                underlying: error.localizedDescription
            )
        }

        let text = result.standardOutputText
        let versionLine = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        guard !versionLine.isEmpty else {
            throw LocalSourceIdentityError.decoderUnavailable(
                underlying: "ffmpeg -version 沒有輸出。"
            )
        }

        let resolvedPath = (try? FileManager.default.destinationOfSymbolicLink(
            atPath: ffmpegURL.path
        )) ?? ffmpegURL.path

        var hasher = SHA256()
        hasher.update(data: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        hasher.update(data: Data("\u{0000}".utf8))
        hasher.update(data: Data(resolvedPath.utf8))
        let signature = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        return LocalDecoderIdentity(
            executablePath: ffmpegURL.path,
            versionLine: versionLine,
            signature: signature
        )
    }
}

/// Location of the PCM payload inside a RIFF/WAVE file.
///
/// Header and metadata chunks are excluded so `pcmSHA256` describes only the
/// samples actually fed to the model.
public struct WavePCMLayout: Equatable, Sendable {
    public let dataOffset: UInt64
    public let dataByteCount: UInt64
    public let formatTag: UInt16
    public let channels: UInt16
    public let sampleRate: UInt32
    public let bitsPerSample: UInt16

    public var sampleCount: Int64 {
        guard bitsPerSample > 0, channels > 0 else { return 0 }
        let bytesPerSample = UInt64(bitsPerSample / 8) * UInt64(channels)
        guard bytesPerSample > 0 else { return 0 }
        return Int64(dataByteCount / bytesPerSample)
    }

    private static let maximumHeaderScanBytes = 1_048_576

    /// Digest of the sample payload only, so two files carrying identical audio
    /// but different metadata chunks hash the same.
    public func pcmSHA256(at url: URL) async throws -> String {
        try await LocalContentHasher.sha256(of: url, offset: dataOffset, length: dataByteCount)
    }

    public static func parse(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> WavePCMLayout {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let header = try handle.read(upToCount: maximumHeaderScanBytes) ?? Data()
        guard header.count >= 12 else {
            throw LocalSourceIdentityError.unexpectedWaveLayout(
                path: url.path,
                reason: "檔案小於 12 bytes，不是有效 RIFF。"
            )
        }

        func ascii(_ range: Range<Int>) -> String {
            String(decoding: header[range], as: UTF8.self)
        }
        func littleEndianUInt32(at offset: Int) -> UInt32 {
            UInt32(header[offset])
                | (UInt32(header[offset + 1]) << 8)
                | (UInt32(header[offset + 2]) << 16)
                | (UInt32(header[offset + 3]) << 24)
        }
        func littleEndianUInt16(at offset: Int) -> UInt16 {
            UInt16(header[offset]) | (UInt16(header[offset + 1]) << 8)
        }

        guard ascii(0..<4) == "RIFF", ascii(8..<12) == "WAVE" else {
            throw LocalSourceIdentityError.unexpectedWaveLayout(
                path: url.path,
                reason: "缺少 RIFF/WAVE 標記。"
            )
        }

        var formatTag: UInt16?
        var channels: UInt16?
        var sampleRate: UInt32?
        var bitsPerSample: UInt16?
        var dataOffset: UInt64?
        var dataByteCount: UInt64?

        var cursor = 12
        while cursor + 8 <= header.count {
            let chunkID = ascii(cursor..<(cursor + 4))
            let chunkSize = Int(littleEndianUInt32(at: cursor + 4))
            let payloadStart = cursor + 8

            switch chunkID {
            case "fmt ":
                guard payloadStart + 16 <= header.count else {
                    throw LocalSourceIdentityError.unexpectedWaveLayout(
                        path: url.path,
                        reason: "fmt chunk 被截斷。"
                    )
                }
                formatTag = littleEndianUInt16(at: payloadStart)
                channels = littleEndianUInt16(at: payloadStart + 2)
                sampleRate = littleEndianUInt32(at: payloadStart + 4)
                bitsPerSample = littleEndianUInt16(at: payloadStart + 14)
            case "data":
                dataOffset = UInt64(payloadStart)
                dataByteCount = UInt64(chunkSize)
            default:
                break
            }

            if dataOffset != nil { break }
            // RIFF chunks are word aligned.
            cursor = payloadStart + chunkSize + (chunkSize % 2)
        }

        guard let resolvedFormat = formatTag else {
            throw LocalSourceIdentityError.unexpectedWaveLayout(
                path: url.path,
                reason: "找不到 fmt chunk。"
            )
        }
        guard let resolvedDataOffset = dataOffset, let resolvedDataSize = dataByteCount else {
            throw LocalSourceIdentityError.unexpectedWaveLayout(
                path: url.path,
                reason: "在前 1 MiB 內找不到 data chunk。"
            )
        }
        guard let resolvedChannels = channels, let resolvedSampleRate = sampleRate,
              let resolvedBits = bitsPerSample
        else {
            throw LocalSourceIdentityError.unexpectedWaveLayout(
                path: url.path,
                reason: "fmt chunk 欄位不完整。"
            )
        }

        // WAVE_FORMAT_PCM only; compressed payloads would make the digest
        // meaningless as a sample-level identity.
        guard resolvedFormat == 1 else {
            throw LocalSourceIdentityError.unexpectedWaveLayout(
                path: url.path,
                reason: "格式標籤 \(resolvedFormat) 不是未壓縮 PCM。"
            )
        }

        let fileSize = UInt64(
            (try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        )
        let available = fileSize > resolvedDataOffset ? fileSize - resolvedDataOffset : 0
        guard available >= resolvedDataSize else {
            throw LocalSourceIdentityError.unexpectedWaveLayout(
                path: url.path,
                reason: "data chunk 宣告 \(resolvedDataSize) bytes，但檔案只剩 \(available) bytes（截斷）。"
            )
        }

        return WavePCMLayout(
            dataOffset: resolvedDataOffset,
            dataByteCount: resolvedDataSize,
            formatTag: resolvedFormat,
            channels: resolvedChannels,
            sampleRate: resolvedSampleRate,
            bitsPerSample: resolvedBits
        )
    }
}

/// Everything needed to prove that a resumed run sees the same audio, decoded
/// the same way, as the run that produced the checkpoint.
public struct LocalSourceIdentity: Codable, Equatable, Sendable {
    public let sourceSHA256: String
    public let sourceByteCount: Int64
    /// Retrieval hint only. A moved file with identical bytes is still the same
    /// source; a replaced file at the same path is not.
    public let sourceLocator: String
    public let normalizationProfile: LocalNormalizationProfile
    public let decoder: LocalDecoderIdentity

    /// Original value supplied by the caller, kept for diagnostics.
    public let sliceStartSeconds: Double?
    /// The single quantization of `sliceStartSeconds`, in original-recording samples.
    public let workStartSample: Int64
    /// `workStartSample + decoded PCM sample count`.
    public let workEndSample: Int64

    public var workSpan: LocalSampleSpan {
        LocalSampleSpan(start: workStartSample, end: workEndSample)
    }

    public init(
        sourceSHA256: String,
        sourceByteCount: Int64,
        sourceLocator: String,
        normalizationProfile: LocalNormalizationProfile,
        decoder: LocalDecoderIdentity,
        sliceStartSeconds: Double?,
        workStartSample: Int64,
        workEndSample: Int64
    ) {
        self.sourceSHA256 = sourceSHA256
        self.sourceByteCount = sourceByteCount
        self.sourceLocator = sourceLocator
        self.normalizationProfile = normalizationProfile
        self.decoder = decoder
        self.sliceStartSeconds = sliceStartSeconds
        self.workStartSample = workStartSample
        self.workEndSample = workEndSample
    }

    private enum CodingKeys: String, CodingKey {
        case sourceSHA256
        case sourceByteCount
        case sourceLocator
        case normalizationProfile
        case decoder
        case sliceStartSeconds
        case workStartSample
        case workEndSample
    }

    /// The canonical subset has no float type, so a frozen identity records
    /// `sliceStartSeconds` as a `"%.6f"` string. Synthesized `Decodable` demands
    /// a JSON number and therefore fails on Swift's own bytes — every sliced job
    /// wrote an `identity.json` that no resume could read back. Sample
    /// coordinates go through `StrictCheckpointDecoding` for the same reason the
    /// rest of the checkpoint contract does: `true` must not become `1`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceSHA256 = try container.decode(String.self, forKey: .sourceSHA256)
        sourceByteCount = try StrictCheckpointDecoding.int64(
            container, .sourceByteCount, field: "source.sourceByteCount"
        )
        sourceLocator = try container.decode(String.self, forKey: .sourceLocator)
        normalizationProfile = try container.decode(
            LocalNormalizationProfile.self, forKey: .normalizationProfile
        )
        self.decoder = try container.decode(LocalDecoderIdentity.self, forKey: .decoder)
        if try container.decodeNil(forKey: .sliceStartSeconds) {
            sliceStartSeconds = nil
        } else {
            sliceStartSeconds = try decodeCanonicalSeconds(container, .sliceStartSeconds)
        }
        workStartSample = try StrictCheckpointDecoding.int64(
            container, .workStartSample, field: "source.workStartSample"
        )
        workEndSample = try StrictCheckpointDecoding.int64(
            container, .workEndSample, field: "source.workEndSample"
        )
    }
}

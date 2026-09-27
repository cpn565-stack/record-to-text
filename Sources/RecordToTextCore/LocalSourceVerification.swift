import Foundation

/// What one run proved about the recording it is working from.
public struct LocalSourceFacts: Equatable, Sendable {
    /// SHA-256 over every byte of the source file, never a header or a sample.
    public let sha256: String
    public let byteCount: Int64
    /// Auxiliary stability check only. Two runs must never skip the content hash
    /// because this happens to match.
    public let attributeSignature: String
}

public enum LocalSourceVerificationError: LocalizedError, Equatable {
    case attributesChanged(path: String, before: String, after: String)
    case snapshotContentDiffers(path: String, sourceSHA256: String, snapshotSHA256: String)
    case snapshotSizeDiffers(path: String, source: Int64, snapshot: Int64)
    case sourceChanged(path: String, expected: String, actual: String)

    public var code: String {
        switch self {
        case .attributesChanged, .snapshotContentDiffers, .snapshotSizeDiffers, .sourceChanged:
            return "local_source_changed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .attributesChanged(path, before, after):
            return "來源音檔在複製／hash 期間屬性改變（\(before.prefix(12))… → \(after.prefix(12))…），已停止：\(path)"
        case let .snapshotContentDiffers(path, sourceSHA256, snapshotSHA256):
            return "來源 snapshot 內容與原檔不符（原檔 \(sourceSHA256.prefix(12))…，snapshot \(snapshotSHA256.prefix(12))…），已停止：\(path)"
        case let .snapshotSizeDiffers(path, source, snapshot):
            return "來源 snapshot 大小 \(snapshot) bytes 與原檔 \(source) bytes 不符：\(path)"
        case let .sourceChanged(path, expected, actual):
            return "原始音檔在處理期間被改動（記錄 \(expected.prefix(12))…，目前 \(actual.prefix(12))…）；已提交的結果保留，但不得宣稱已為新來源完成：\(path)"
        }
    }
}

/// Establishes and re-checks source identity for the local pipeline.
///
/// Phase 0 §2.1: work from an app-private snapshot so the pipeline never
/// re-reads a file an external process can overwrite mid-run, prove the copy is
/// byte-identical with two independent reads, and re-verify the original before
/// publishing anything.
public enum LocalSourceVerification {

    /// Fixed name for the §2.1 source snapshot inside a job working directory.
    ///
    /// Extensionless on purpose: `RecoveryScanner` matches temp entries by exact
    /// name, and ffmpeg identifies the container from content, so keeping the
    /// source's extension would only turn the snapshot into an "unknown" entry.
    public static let snapshotFileName = "source-snapshot"

    /// Size, timestamps, inode and mode, digested into one comparable string.
    public static func attributeSignature(
        of url: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        func value(_ key: FileAttributeKey) -> String {
            (attributes[key] as? NSObject)?.description ?? "-"
        }
        let payload = [
            value(.size),
            value(.modificationDate),
            value(.creationDate),
            value(.posixPermissions),
            value(.systemNumber),
            // Without the inode, a rename-swap that happens to land on the same
            // size and timestamp looks identical. Attributes stay auxiliary —
            // the content digest is what decides — but this closes the cheapest
            // hole in them.
            value(.systemFileNumber),
            value(.referenceCount),
            value(.type)
        ].joined(separator: "\u{0000}")
        return LocalDigest.sha256(payload)
    }

    /// §2.1 steps 1–2: snapshot, then prove the snapshot and the source agree.
    ///
    /// Hashing the copy and the original separately and requiring equality is
    /// what makes a single unstable read unacceptable: a file being rewritten
    /// underneath the copy shows up either as an attribute change or as two
    /// digests that do not match.
    public static func snapshotAndVerify(
        sourceURL: URL,
        snapshotURL: URL,
        fileManager: FileManager = .default
    ) async throws -> LocalSourceFacts {
        try Task.checkCancellation()
        let before = try attributeSignature(of: sourceURL, fileManager: fileManager)
        let sourceByteCount = try byteCount(of: sourceURL, fileManager: fileManager)

        try LocalSourceSnapshot.create(
            from: sourceURL,
            to: snapshotURL,
            fileManager: fileManager
        )
        try Task.checkCancellation()

        let afterCopy = try attributeSignature(of: sourceURL, fileManager: fileManager)
        guard afterCopy == before else {
            throw LocalSourceVerificationError.attributesChanged(
                path: sourceURL.path, before: before, after: afterCopy
            )
        }

        let snapshotSHA256 = try await LocalContentHasher.sha256(
            of: snapshotURL, fileManager: fileManager
        )
        try Task.checkCancellation()
        let sourceSHA256 = try await LocalContentHasher.sha256(
            of: sourceURL, fileManager: fileManager
        )
        guard snapshotSHA256 == sourceSHA256 else {
            throw LocalSourceVerificationError.snapshotContentDiffers(
                path: sourceURL.path,
                sourceSHA256: sourceSHA256,
                snapshotSHA256: snapshotSHA256
            )
        }

        let snapshotByteCount = try byteCount(of: snapshotURL, fileManager: fileManager)
        guard snapshotByteCount == sourceByteCount else {
            throw LocalSourceVerificationError.snapshotSizeDiffers(
                path: snapshotURL.path,
                source: sourceByteCount,
                snapshot: snapshotByteCount
            )
        }

        let afterHash = try attributeSignature(of: sourceURL, fileManager: fileManager)
        guard afterHash == afterCopy else {
            throw LocalSourceVerificationError.attributesChanged(
                path: sourceURL.path, before: afterCopy, after: afterHash
            )
        }
        return LocalSourceFacts(
            sha256: sourceSHA256,
            byteCount: sourceByteCount,
            attributeSignature: afterHash
        )
    }

    /// §2.1 step 3: the original must still be the bytes the plan was frozen for.
    ///
    /// Called again before a new official transcript is published. A changed
    /// source keeps the snapshot's committed results but must not be reported as
    /// finished work for the new content.
    public static func confirmUnchanged(
        sourceURL: URL,
        expectedSHA256: String,
        fileManager: FileManager = .default
    ) async throws -> LocalSourceFacts {
        try Task.checkCancellation()
        let actual = try await LocalContentHasher.sha256(
            of: sourceURL, fileManager: fileManager
        )
        guard actual == expectedSHA256 else {
            throw LocalSourceVerificationError.sourceChanged(
                path: sourceURL.path,
                expected: expectedSHA256,
                actual: actual
            )
        }
        return LocalSourceFacts(
            sha256: actual,
            byteCount: try byteCount(of: sourceURL, fileManager: fileManager),
            attributeSignature: try attributeSignature(of: sourceURL, fileManager: fileManager)
        )
    }

    private static func byteCount(of url: URL, fileManager: FileManager) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// Measured facts about one decoded root WAV.
public struct LocalRootMeasurement: Equatable, Sendable {
    public let sampleCount: Int64
    public let pcmSHA256: String

    public var seconds: Double {
        LocalAudioCoordinates.seconds(forSamples: sampleCount)
    }
}

public enum LocalRootMeasurer {
    /// Measure the samples the model will actually see.
    ///
    /// `expectedSeconds` is a probe-derived estimate used only for the §3 sanity
    /// check: a decode that comes out far shorter or longer than the container
    /// claims is a defect to report, not a tail to invent or discard. Pass `nil`
    /// to skip the comparison.
    public static func measure(
        wavURL: URL,
        expectedSeconds: Double?,
        fileManager: FileManager = .default
    ) async throws -> LocalRootMeasurement {
        let layout = try WavePCMLayout.parse(at: wavURL, fileManager: fileManager)
        guard layout.sampleRate == LocalAudioCoordinates.sampleRate else {
            throw LocalSourceIdentityError.pcmMismatch(
                field: wavURL.lastPathComponent,
                expected: "\(LocalAudioCoordinates.sampleRate) Hz",
                actual: "\(layout.sampleRate) Hz"
            )
        }
        guard layout.channels == 1, layout.bitsPerSample == 16 else {
            throw LocalSourceIdentityError.unexpectedWaveLayout(
                path: wavURL.path,
                reason: "root 必須是 16 kHz 單聲道 signed PCM16，實際 \(layout.channels) 聲道 \(layout.bitsPerSample) bits。"
            )
        }
        if let expectedSeconds, expectedSeconds.isFinite {
            let decoded = LocalAudioCoordinates.seconds(forSamples: layout.sampleCount)
            guard abs(decoded - expectedSeconds)
                <= LocalAudioCoordinates.maximumDurationMismatchSeconds
            else {
                throw LocalCoordinateError.durationMismatch(
                    containerSeconds: expectedSeconds,
                    decodedSeconds: decoded
                )
            }
        }
        let digest = try await layout.pcmSHA256(at: wavURL)
        try Task.checkCancellation()
        return LocalRootMeasurement(sampleCount: layout.sampleCount, pcmSHA256: digest)
    }
}

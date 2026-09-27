import Foundation

public struct SilenceAnalysisMetrics: Equatable, Sendable {
    public var scanCount: Int
    public var scannedAudioSeconds: Double
    public var scanElapsedMilliseconds: Double
    public var cacheHitCount: Int
    public var skipIneligibleCount: Int
    public var fallbackCount: Int

    public init(
        scanCount: Int = 0,
        scannedAudioSeconds: Double = 0,
        scanElapsedMilliseconds: Double = 0,
        cacheHitCount: Int = 0,
        skipIneligibleCount: Int = 0,
        fallbackCount: Int = 0
    ) {
        self.scanCount = scanCount
        self.scannedAudioSeconds = scannedAudioSeconds
        self.scanElapsedMilliseconds = scanElapsedMilliseconds
        self.cacheHitCount = cacheHitCount
        self.skipIneligibleCount = skipIneligibleCount
        self.fallbackCount = fallbackCount
    }
}

/// Phase 1 §3.4: content-level identity for a scan.
///
/// Path, size and mtime say where a file is, not which samples were analysed.
/// The local path already computes these digests in phase 0, so binding them
/// here means a cache entry can only be reused for the audio it describes.
public struct SilenceAnalysisContentIdentity: Equatable, Hashable, Sendable {
    public let sourceSHA256: String
    public let pcmSHA256: String
    public let normalizationProfile: String

    public init(
        sourceSHA256: String,
        pcmSHA256: String,
        normalizationProfile: String
    ) {
        self.sourceSHA256 = sourceSHA256
        self.pcmSHA256 = pcmSHA256
        self.normalizationProfile = normalizationProfile
    }
}

public struct SilenceAnalysisSourceIdentity: Equatable, Hashable, Sendable {
    public let canonicalPath: String
    public let resourceIdentifier: String?
    public let fileSize: Int64
    public let contentModificationDate: Date
    public let noiseProfile: String
    public let minimumSilenceDuration: Double
    public let content: SilenceAnalysisContentIdentity?

    public init(
        canonicalPath: String,
        resourceIdentifier: String?,
        fileSize: Int64,
        contentModificationDate: Date,
        noiseProfile: String,
        minimumSilenceDuration: Double,
        content: SilenceAnalysisContentIdentity? = nil
    ) {
        self.canonicalPath = canonicalPath
        self.resourceIdentifier = resourceIdentifier
        self.fileSize = fileSize
        self.contentModificationDate = contentModificationDate
        self.noiseProfile = noiseProfile
        self.minimumSilenceDuration = minimumSilenceDuration
        self.content = content
    }
}

/// In-memory silence analysis results for one transcription run.
///
/// The cache deliberately owns no global state and never writes to disk. A
/// range is only reusable when the complete requested source range was scanned
/// under the same source identity and detection settings.
public final class JobSilenceAnalysisCache {
    public static let defaultNoiseProfile = "-35dB"
    public static let defaultMinimumSilenceDuration: TimeInterval = 0.35
    public static let defaultMaximumIntervalCount = 100_000

    private struct Entry {
        let startSeconds: Double
        let endSeconds: Double
        let silences: [DetectedSilence]
    }

    private let fileManager: FileManager
    private let sourceURL: URL
    private let configuredNoiseProfile: String
    private let configuredMinimumSilenceDuration: TimeInterval
    private let maximumIntervalCount: Int
    private let contentIdentity: SilenceAnalysisContentIdentity?
    private let initialIdentity: SilenceAnalysisSourceIdentity?
    private var entries: [Entry] = []
    private var identityInvalidated = false

    public private(set) var metrics = SilenceAnalysisMetrics()

    public init(
        sourceURL: URL,
        fileManager: FileManager = .default,
        noiseProfile: String = JobSilenceAnalysisCache.defaultNoiseProfile,
        minimumSilenceDuration: TimeInterval =
            JobSilenceAnalysisCache.defaultMinimumSilenceDuration,
        maximumIntervalCount: Int = JobSilenceAnalysisCache.defaultMaximumIntervalCount,
        contentIdentity: SilenceAnalysisContentIdentity? = nil
    ) {
        self.fileManager = fileManager
        self.sourceURL = sourceURL
        self.configuredNoiseProfile = noiseProfile
        self.configuredMinimumSilenceDuration = minimumSilenceDuration
        self.maximumIntervalCount = max(maximumIntervalCount, 0)
        self.contentIdentity = contentIdentity
        self.initialIdentity = Self.makeIdentity(
            sourceURL: sourceURL,
            fileManager: fileManager,
            noiseProfile: noiseProfile,
            minimumSilenceDuration: minimumSilenceDuration,
            content: contentIdentity
        )
    }

    public var isEnabled: Bool {
        initialIdentity != nil && currentIdentityMatchesInitial
    }

    public var sourceIdentity: SilenceAnalysisSourceIdentity? {
        guard currentIdentityMatchesInitial else {
            return nil
        }
        return initialIdentity
    }

    public func cachedSilences(
        startSeconds: Double,
        endSeconds: Double
    ) -> [DetectedSilence]? {
        guard validRange(startSeconds: startSeconds, endSeconds: endSeconds),
              currentIdentityMatchesInitial
        else {
            return nil
        }
        guard let entry = entries.first(where: { entry in
            entry.startSeconds <= startSeconds + Self.rangeEpsilon
                && entry.endSeconds >= endSeconds - Self.rangeEpsilon
        }) else {
            return nil
        }
        metrics.cacheHitCount += 1
        return Self.clippedSilences(
            entry.silences,
            startSeconds: startSeconds,
            endSeconds: endSeconds
        )
    }

    /// Runs a relative-time detector only on a cache miss, then stores the
    /// resulting intervals in source-absolute coordinates.
    public func cachedOrDetect(
        startSeconds: Double,
        durationSeconds: Double,
        detector: any SilenceDetectionServicing
    ) async throws -> [DetectedSilence] {
        try CloudBudgetContext.check("split")
        let endSeconds = startSeconds + durationSeconds
        if let cached = cachedSilences(
            startSeconds: startSeconds,
            endSeconds: endSeconds
        ) {
            return cached
        }

        let clock = ContinuousClock()
        let began = clock.now
        func recordCompletedScan() {
            let elapsed = began.duration(to: clock.now)
            metrics.scanCount += 1
            metrics.scannedAudioSeconds += max(durationSeconds, 0)
            metrics.scanElapsedMilliseconds +=
                Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        }

        let detected: [DetectedSilence]
        do {
            detected = try await detector.detect(
                sourceURL: sourceURL,
                startSeconds: startSeconds,
                durationSeconds: durationSeconds
            )
        } catch let error as CloudSegmentDeadlineExceeded {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try CloudBudgetContext.check("split")
            recordCompletedScan()
            throw error
        }
        try CloudBudgetContext.check("split")
        recordCompletedScan()
        let absolute = detected.map {
            DetectedSilence(
                startSeconds: startSeconds + $0.startSeconds,
                endSeconds: startSeconds + $0.endSeconds
            )
        }
        _ = store(
            silences: absolute,
            startSeconds: startSeconds,
            endSeconds: endSeconds
        )
        return Self.clippedSilences(
            absolute,
            startSeconds: startSeconds,
            endSeconds: endSeconds
        )
    }

    @discardableResult
    public func store(
        silences: [DetectedSilence],
        startSeconds: Double,
        endSeconds: Double
    ) -> Bool {
        guard validRange(startSeconds: startSeconds, endSeconds: endSeconds),
              currentIdentityMatchesInitial,
              silences.count <= maximumIntervalCount
        else {
            return false
        }

        for silence in silences {
            guard silence.startSeconds.isFinite,
                  silence.endSeconds.isFinite,
                  silence.startSeconds >= 0,
                  silence.endSeconds > silence.startSeconds
            else {
                return false
            }
        }
        let normalized = Self.clippedSilences(
            silences,
            startSeconds: startSeconds,
            endSeconds: endSeconds
        )
        entries.removeAll {
            abs($0.startSeconds - startSeconds) <= Self.rangeEpsilon
                && abs($0.endSeconds - endSeconds) <= Self.rangeEpsilon
        }
        entries.append(
            Entry(
                startSeconds: startSeconds,
                endSeconds: endSeconds,
                silences: normalized
            )
        )
        return true
    }

    public func recordScan(
        durationSeconds: Double,
        elapsedMilliseconds: Double
    ) {
        metrics.scanCount += 1
        metrics.scannedAudioSeconds += max(durationSeconds, 0)
        metrics.scanElapsedMilliseconds += max(elapsedMilliseconds, 0)
    }

    public func recordSkippedIneligible() {
        metrics.skipIneligibleCount += 1
    }

    public func recordFallback() {
        metrics.fallbackCount += 1
    }

    public var metricsSummary: String {
        String(
            format:
                "silence_scan_count=%d；silence_scanned_audio_seconds=%.3f；silence_scan_elapsed_ms=%.3f；silence_cache_hit_count=%d；silence_skip_ineligible_count=%d；silence_fallback_count=%d",
            metrics.scanCount,
            metrics.scannedAudioSeconds,
            metrics.scanElapsedMilliseconds,
            metrics.cacheHitCount,
            metrics.skipIneligibleCount,
            metrics.fallbackCount
        )
    }

    private static let rangeEpsilon = 0.000_001

    private var currentIdentityMatchesInitial: Bool {
        guard !identityInvalidated else {
            return false
        }
        guard let initialIdentity,
              let current = Self.makeIdentity(
                  sourceURL: sourceURL,
                  fileManager: fileManager,
                  noiseProfile: configuredNoiseProfile,
                  minimumSilenceDuration: configuredMinimumSilenceDuration,
                  content: contentIdentity
              )
        else {
            return false
        }
        guard current == initialIdentity else {
            identityInvalidated = true
            entries.removeAll()
            return false
        }
        return true
    }

    private func validRange(startSeconds: Double, endSeconds: Double) -> Bool {
        startSeconds.isFinite
            && endSeconds.isFinite
            && startSeconds >= 0
            && endSeconds > startSeconds
    }

    private static func clippedSilences(
        _ silences: [DetectedSilence],
        startSeconds: Double,
        endSeconds: Double
    ) -> [DetectedSilence] {
        silences.compactMap { silence in
            guard silence.startSeconds.isFinite,
                  silence.endSeconds.isFinite,
                  silence.endSeconds > silence.startSeconds
            else {
                return nil
            }
            let clippedStart = max(silence.startSeconds, startSeconds)
            let clippedEnd = min(silence.endSeconds, endSeconds)
            guard clippedEnd > clippedStart else {
                return nil
            }
            return DetectedSilence(
                startSeconds: clippedStart,
                endSeconds: clippedEnd
            )
        }.sorted {
            if $0.startSeconds == $1.startSeconds {
                return $0.endSeconds < $1.endSeconds
            }
            return $0.startSeconds < $1.startSeconds
        }
    }

    private static func makeIdentity(
        sourceURL: URL,
        fileManager: FileManager,
        noiseProfile: String,
        minimumSilenceDuration: TimeInterval,
        content: SilenceAnalysisContentIdentity?
    ) -> SilenceAnalysisSourceIdentity? {
        let canonicalURL = sourceURL.standardizedFileURL
            .resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: canonicalURL.path),
              let values = try? canonicalURL.resourceValues(forKeys: [
                  .fileResourceIdentifierKey,
                  .fileSizeKey,
                  .contentModificationDateKey
              ]),
              let fileSize = values.fileSize,
              let modificationDate = values.contentModificationDate
        else {
            return nil
        }
        return SilenceAnalysisSourceIdentity(
            canonicalPath: canonicalURL.path,
            resourceIdentifier: values.fileResourceIdentifier.map {
                String(describing: $0)
            },
            fileSize: Int64(fileSize),
            contentModificationDate: modificationDate,
            noiseProfile: noiseProfile,
            minimumSilenceDuration: minimumSilenceDuration,
            content: content
        )
    }
}

internal enum CloudAdaptiveSilenceCoordinator {
    static func splitBoundary(
        duration: TimeInterval,
        splitDepth: Int,
        startSeconds: TimeInterval,
        silenceAware: Bool,
        minimumChildDuration: TimeInterval,
        cache: JobSilenceAnalysisCache,
        detector: any SilenceDetectionServicing,
        onFallback: ((Error) -> Void)? = nil
    ) async throws -> TimeInterval? {
        try CloudBudgetContext.check("split")
        // `startSeconds` is already the source-absolute start of this record.
        // Do not add sourceSlice.startSeconds again.
        let midpointBoundary = CloudAdaptiveSegmentPlanner.splitBoundary(
            duration: duration,
            splitDepth: splitDepth,
            minimumChildDuration: minimumChildDuration
        )
        guard let midpointBoundary else {
            cache.recordSkippedIneligible()
            return nil
        }
        guard silenceAware else {
            return midpointBoundary
        }

        do {
            let absoluteSilences = try await cache.cachedOrDetect(
                startSeconds: startSeconds,
                durationSeconds: duration,
                detector: detector
            )
            let relativeSilences = absoluteSilences.compactMap { silence -> DetectedSilence? in
                let start = silence.startSeconds - startSeconds
                let end = silence.endSeconds - startSeconds
                guard start.isFinite, end.isFinite, end > start else {
                    return nil
                }
                return DetectedSilence(startSeconds: start, endSeconds: end)
            }
            return CloudAdaptiveSegmentPlanner.splitBoundary(
                duration: duration,
                splitDepth: splitDepth,
                silences: relativeSilences,
                minimumChildDuration: minimumChildDuration
            )
        } catch let error as CloudSegmentDeadlineExceeded {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            cache.recordFallback()
            onFallback?(error)
            return midpointBoundary
        }
    }
}

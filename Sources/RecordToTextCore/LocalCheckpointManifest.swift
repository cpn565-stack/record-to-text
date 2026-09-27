import CryptoKit
import Foundation

/// On-disk names and contract versions for the local v2 checkpoint.
public enum LocalCheckpointSchema {
    public static let version = 2
    public static let asrContractVersion = "rec2t-local-asr-v2"
    public static let displayLayoutVersion = "rec2t-local-display-v1"

    public static let directoryName = "local-checkpoint-v2"
    public static let identityFileName = "identity.json"
    public static let manifestFileName = "manifest.json"
    public static let silencePlanFileName = "silence-plan.json"
    public static let rootsDirectoryName = "roots"
    public static let audioDirectoryName = "audio"

    /// Display headings every ten minutes from the work start, not from the
    /// wall-clock minute grid of the original recording.
    public static let displayGroupSeconds: Double = 600
}

public enum LocalDigest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    public static func sha256<T: CanonicalJSONRepresentable>(_ value: T) -> String {
        sha256(value.canonicalBytes())
    }
}

/// Stable identifiers derived from plan coordinates.
///
/// Deriving rather than counter-numbering keeps IDs reproducible across
/// restarts, so `planID` stays stable, and prevents a split or an inserted
/// segment from silently renumbering nodes that already have persisted results.
public enum LocalCheckpointID {
    private static func short(_ value: CanonicalJSONValue) -> String {
        String(LocalDigest.sha256(CanonicalJSONEncoder.encode(value)).prefix(16))
    }

    public static func root(order: Int, startSample: Int64, endSample: Int64) -> String {
        "root-" + short(.object([
            "kind": .string("root"),
            "order": .integer(Int64(order)),
            "start": .integer(startSample),
            "end": .integer(endSample)
        ]))
    }

    public static func chunk(
        rootID: String,
        order: Int,
        startSample: Int64,
        endSample: Int64
    ) -> String {
        "node-" + short(.object([
            "kind": .string("chunk"),
            "root": .string(rootID),
            "order": .integer(Int64(order)),
            "start": .integer(startSample),
            "end": .integer(endSample)
        ]))
    }

    /// `side` is "a" or "b". Deterministic given the parent and split point, so
    /// re-running the same split reuses the same subtree instead of forking it.
    public static func splitChild(
        parentID: String,
        side: String,
        startSample: Int64,
        endSample: Int64
    ) -> String {
        "node-" + short(.object([
            "kind": .string("split"),
            "parent": .string(parentID),
            "side": .string(side),
            "start": .integer(startSample),
            "end": .integer(endSample)
        ]))
    }

    public static func displayGroup(
        order: Int,
        startSample: Int64,
        endSample: Int64
    ) -> String {
        "group-" + short(.object([
            "kind": .string("displayGroup"),
            "order": .integer(Int64(order)),
            "start": .integer(startSample),
            "end": .integer(endSample)
        ]))
    }
}

/// Filesystem layout of `local-checkpoint-v2/`, with the containment rules the
/// phase 0 spec requires for every relative path it stores.
public struct LocalCheckpointLayout: Equatable, Sendable {
    public let root: URL

    public init(recoveryDirectory: URL) {
        self.root = recoveryDirectory.appendingPathComponent(
            LocalCheckpointSchema.directoryName,
            isDirectory: true
        )
    }

    public var identityURL: URL {
        root.appendingPathComponent(LocalCheckpointSchema.identityFileName)
    }

    public var manifestURL: URL {
        root.appendingPathComponent(LocalCheckpointSchema.manifestFileName)
    }

    /// Frozen silence analysis. Written next to the manifest rather than inside
    /// it so §3.7 can drop a huge interval list without touching `planID`.
    public var silencePlanURL: URL {
        root.appendingPathComponent(LocalCheckpointSchema.silencePlanFileName)
    }

    public var rootsDirectoryURL: URL {
        root.appendingPathComponent(LocalCheckpointSchema.rootsDirectoryName, isDirectory: true)
    }

    public var audioDirectoryURL: URL {
        root.appendingPathComponent(LocalCheckpointSchema.audioDirectoryName, isDirectory: true)
    }

    public func stateURL(rootID: String) -> URL {
        rootsDirectoryURL.appendingPathComponent("\(rootID).json")
    }

    public func audioURL(rootID: String) -> URL {
        audioDirectoryURL.appendingPathComponent("\(rootID).wav")
    }

    /// Creates the directory tree with 0700 permissions.
    public func createDirectories(fileManager: FileManager = .default) throws {
        for directory in [root, rootsDirectoryURL, audioDirectoryURL] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }

    /// Resolve a stored relative path, refusing traversal and symlink escape.
    public func resolve(
        relativePath: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard !relativePath.isEmpty else {
            throw LocalCheckpointError.pathEscape(path: relativePath, reason: "路徑為空。")
        }
        guard !relativePath.hasPrefix("/") else {
            throw LocalCheckpointError.pathEscape(path: relativePath, reason: "不接受絕對路徑。")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.contains(where: { $0 == ".." }) == false else {
            throw LocalCheckpointError.pathEscape(path: relativePath, reason: "不接受上層跳脫。")
        }

        let resolved = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
            throw LocalCheckpointError.pathEscape(
                path: relativePath,
                reason: "解析後不在 checkpoint 根目錄內。"
            )
        }

        var componentURL = root
        for component in components {
            componentURL.appendPathComponent(String(component))
            if (try? fileManager.attributesOfItem(atPath: componentURL.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw LocalCheckpointError.pathEscape(path: relativePath, reason: "不接受 symbolic link。")
            }
        }
        return resolved
    }
}

// MARK: - Inference and presentation identity

/// Everything that changes what the model would recognize.
///
/// Kept separate from presentation so that moving the output file or restyling
/// the ten-minute headings can reassemble an existing transcript without
/// re-running inference.
public struct LocalInferenceIdentity: Codable, Equatable, Sendable, CanonicalJSONRepresentable {
    public let asrContractVersion: String
    public let runtimeKind: String
    public let modelID: String
    /// Pinned upstream revision. Absent for an unpinned local folder.
    public let modelRevision: String?
    /// Content digest of the model files. Without it there is no way to prove
    /// the weights are unchanged, so cross-run reuse must be refused.
    public let modelManifestDigest: String?
    public let language: String?
    public let promptDigest: String
    public let termsDigest: String
    /// Which prompt channel actually ran, so glossary and no-glossary results
    /// are never mixed.
    public let promptChannel: String
    public let allowMissingPrompt: Bool
    public let maximumTokens: Int
    public let samplerDigest: String
    public let mlxVersion: String?
    public let mlxAudioVersion: String?

    public init(
        asrContractVersion: String = LocalCheckpointSchema.asrContractVersion,
        runtimeKind: String,
        modelID: String,
        modelRevision: String?,
        modelManifestDigest: String?,
        language: String?,
        promptDigest: String,
        termsDigest: String,
        promptChannel: String,
        allowMissingPrompt: Bool,
        maximumTokens: Int,
        samplerDigest: String,
        mlxVersion: String?,
        mlxAudioVersion: String?
    ) {
        self.asrContractVersion = asrContractVersion
        self.runtimeKind = runtimeKind
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.modelManifestDigest = modelManifestDigest
        self.language = language
        self.promptDigest = promptDigest
        self.termsDigest = termsDigest
        self.promptChannel = promptChannel
        self.allowMissingPrompt = allowMissingPrompt
        self.maximumTokens = maximumTokens
        self.samplerDigest = samplerDigest
        self.mlxVersion = mlxVersion
        self.mlxAudioVersion = mlxAudioVersion
    }

    /// True only when the weights themselves are pinned and digestible.
    public var canReuseAcrossRuns: Bool {
        modelManifestDigest != nil
    }

    public var digest: String { LocalDigest.sha256(self) }

    public var canonicalValue: CanonicalJSONValue {
        .object([
            "allowMissingPrompt": .bool(allowMissingPrompt),
            "asrContractVersion": .string(asrContractVersion),
            "language": .optionalString(language),
            "maximumTokens": .integer(Int64(maximumTokens)),
            "mlxAudioVersion": .optionalString(mlxAudioVersion),
            "mlxVersion": .optionalString(mlxVersion),
            "modelID": .string(modelID),
            "modelManifestDigest": .optionalString(modelManifestDigest),
            "modelRevision": .optionalString(modelRevision),
            "promptChannel": .string(promptChannel),
            "promptDigest": .string(promptDigest),
            "runtimeKind": .string(runtimeKind),
            "samplerDigest": .string(samplerDigest),
            "termsDigest": .string(termsDigest)
        ])
    }
}

/// Recorded for diagnosis only. Changing these must not invalidate results.
public struct LocalPresentationOptions: Codable, Equatable, Sendable, CanonicalJSONRepresentable {
    public let displayLayoutVersion: String
    public let openCCConfiguration: String?
    public let outputLocatorHint: String?
    public let jobUUID: String

    public init(
        displayLayoutVersion: String = LocalCheckpointSchema.displayLayoutVersion,
        openCCConfiguration: String?,
        outputLocatorHint: String?,
        jobUUID: String
    ) {
        self.displayLayoutVersion = displayLayoutVersion
        self.openCCConfiguration = openCCConfiguration
        self.outputLocatorHint = outputLocatorHint
        self.jobUUID = jobUUID
    }

    public var canonicalValue: CanonicalJSONValue {
        .object([
            "displayLayoutVersion": .string(displayLayoutVersion),
            "jobUUID": .string(jobUUID),
            "openCCConfiguration": .optionalString(openCCConfiguration),
            "outputLocatorHint": .optionalString(outputLocatorHint)
        ])
    }
}

/// The frozen source-and-inference contract Swift writes once per job.
public struct LocalIdentityDocument: Codable, Equatable, Sendable, CanonicalJSONRepresentable {
    public let schemaVersion: Int
    public let jobID: String
    public let source: LocalSourceIdentity
    public let normalizationProfile: LocalNormalizationProfile
    public let inference: LocalInferenceIdentity
    public let presentation: LocalPresentationOptions

    public init(
        schemaVersion: Int = LocalCheckpointSchema.version,
        jobID: String,
        source: LocalSourceIdentity,
        normalizationProfile: LocalNormalizationProfile,
        inference: LocalInferenceIdentity,
        presentation: LocalPresentationOptions
    ) {
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.source = source
        self.normalizationProfile = normalizationProfile
        self.inference = inference
        self.presentation = presentation
    }

    public var canonicalValue: CanonicalJSONValue {
        .object([
            "inference": inference.canonicalValue,
            "jobID": .string(jobID),
            "normalizationProfile": normalizationProfile.canonicalValue,
            "presentation": presentation.canonicalValue,
            "schemaVersion": .integer(Int64(schemaVersion)),
            "source": source.canonicalValue
        ])
    }

    /// Digest of the whole frozen document. Resume decisions compare the
    /// narrower `inference.digest` so presentation changes stay free.
    public var digest: String { LocalDigest.sha256(self) }
}

extension LocalNormalizationProfile: CanonicalJSONRepresentable {
    public var canonicalValue: CanonicalJSONValue {
        .object([
            "byteOrder": .string(byteOrder),
            "channels": .integer(Int64(channels)),
            "codec": .string(codec),
            "rootExtraction": .string(rootExtraction),
            "sampleRate": .integer(Int64(sampleRate)),
            "sliceSeek": .string(sliceSeek),
            "stripVideo": .bool(stripVideo),
            "trackSelection": .string(trackSelection),
            "version": .string(version)
        ])
    }
}

extension LocalDecoderIdentity: CanonicalJSONRepresentable {
    public var canonicalValue: CanonicalJSONValue {
        .object([
            "executablePath": .string(executablePath),
            "signature": .string(signature),
            "versionLine": .string(versionLine)
        ])
    }
}

extension LocalSourceIdentity: CanonicalJSONRepresentable {
    public var canonicalValue: CanonicalJSONValue {
        .object([
            "decoder": decoder.canonicalValue,
            "normalizationProfile": normalizationProfile.canonicalValue,
            "sliceStartSeconds": sliceStartSeconds.map { .string(Self.encodeSeconds($0)) } ?? .null,
            "sourceByteCount": .integer(sourceByteCount),
            "sourceLocator": .string(sourceLocator),
            "sourceSHA256": .string(sourceSHA256),
            "workEndSample": .integer(workEndSample),
            "workStartSample": .integer(workStartSample)
        ])
    }

    /// Doubles are excluded from the canonical subset, so the recorded original
    /// slice seconds travel as a fixed-precision string. This is a diagnostic
    /// value; `workStartSample` is the authoritative quantization.
    static func encodeSeconds(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

// MARK: - Plan

public struct LocalChunkPlan: Codable, Equatable, Sendable, CanonicalJSONRepresentable {
    public let nodeID: String
    public let startSample: Int64
    public let endSample: Int64

    public init(nodeID: String, startSample: Int64, endSample: Int64) {
        self.nodeID = nodeID
        self.startSample = startSample
        self.endSample = endSample
    }

    public var span: LocalSampleSpan {
        LocalSampleSpan(start: startSample, end: endSample)
    }

    public var canonicalValue: CanonicalJSONValue {
        .object([
            "endSample": .integer(endSample),
            "nodeID": .string(nodeID),
            "startSample": .integer(startSample)
        ])
    }
}

public struct LocalRootPlan: Codable, Equatable, Sendable, CanonicalJSONRepresentable {
    public let rootID: String
    public let order: Int
    public let startSample: Int64
    public let endSample: Int64
    /// Digest of the PCM payload actually handed to ASR, WAV header excluded.
    public let pcmSHA256: String
    public let audioRelativePath: String
    public let stateRelativePath: String
    public let initialChunks: [LocalChunkPlan]

    public init(
        rootID: String,
        order: Int,
        startSample: Int64,
        endSample: Int64,
        pcmSHA256: String,
        audioRelativePath: String,
        stateRelativePath: String,
        initialChunks: [LocalChunkPlan]
    ) {
        self.rootID = rootID
        self.order = order
        self.startSample = startSample
        self.endSample = endSample
        self.pcmSHA256 = pcmSHA256
        self.audioRelativePath = audioRelativePath
        self.stateRelativePath = stateRelativePath
        self.initialChunks = initialChunks
    }

    public var span: LocalSampleSpan {
        LocalSampleSpan(start: startSample, end: endSample)
    }

    public var canonicalValue: CanonicalJSONValue {
        .object([
            "audioRelativePath": .string(audioRelativePath),
            "endSample": .integer(endSample),
            "initialChunks": .representables(initialChunks),
            "order": .integer(Int64(order)),
            "pcmSHA256": .string(pcmSHA256),
            "rootID": .string(rootID),
            "startSample": .integer(startSample),
            "stateRelativePath": .string(stateRelativePath)
        ])
    }
}

public struct LocalDisplayGroup: Codable, Equatable, Sendable, CanonicalJSONRepresentable {
    public let groupID: String
    public let startSample: Int64
    public let endSample: Int64

    public init(groupID: String, startSample: Int64, endSample: Int64) {
        self.groupID = groupID
        self.startSample = startSample
        self.endSample = endSample
    }

    public var span: LocalSampleSpan {
        LocalSampleSpan(start: startSample, end: endSample)
    }

    public var canonicalValue: CanonicalJSONValue {
        .object([
            "endSample": .integer(endSample),
            "groupID": .string(groupID),
            "startSample": .integer(startSample)
        ])
    }
}

public struct LocalCheckpointManifest: Codable, Equatable, Sendable, CanonicalJSONRepresentable {
    public let schemaVersion: Int
    public let jobID: String
    /// SHA-256 over the exact bytes of `identity.json`.
    public let identityDigest: String
    /// SHA-256 over the canonical inference identity, compared on resume.
    public let inferenceDigest: String
    public let normalizationDigest: String
    public let sampleRate: Int64
    public let workStartSample: Int64
    public let workEndSample: Int64
    public let planID: String
    public let plannerVersion: String
    public let roots: [LocalRootPlan]
    public let displayGroups: [LocalDisplayGroup]
    /// Digest of `silence-plan.json`'s exact bytes. Absent for a fixed-cut plan
    /// and for anything frozen before phase 1.
    public let silencePlanDigest: String?
    public let silencePlanRelativePath: String?
    public let normalizedPCMSHA256: String?
    public let createdAt: String

    public init(
        schemaVersion: Int = LocalCheckpointSchema.version,
        jobID: String,
        identityDigest: String,
        inferenceDigest: String,
        normalizationDigest: String,
        sampleRate: Int64 = LocalAudioCoordinates.sampleRate,
        workStartSample: Int64,
        workEndSample: Int64,
        planID: String,
        plannerVersion: String = LocalPlannerStrategy.fixed,
        roots: [LocalRootPlan],
        displayGroups: [LocalDisplayGroup],
        silencePlanDigest: String? = nil,
        silencePlanRelativePath: String? = nil,
        normalizedPCMSHA256: String? = nil,
        createdAt: String
    ) {
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.identityDigest = identityDigest
        self.inferenceDigest = inferenceDigest
        self.normalizationDigest = normalizationDigest
        self.sampleRate = sampleRate
        self.workStartSample = workStartSample
        self.workEndSample = workEndSample
        self.planID = planID
        self.plannerVersion = plannerVersion
        self.roots = roots
        self.displayGroups = displayGroups
        self.silencePlanDigest = silencePlanDigest
        self.silencePlanRelativePath = silencePlanRelativePath
        self.normalizedPCMSHA256 = normalizedPCMSHA256
        self.createdAt = createdAt
    }

    public var workSpan: LocalSampleSpan {
        LocalSampleSpan(start: workStartSample, end: workEndSample)
    }

    public var canonicalValue: CanonicalJSONValue {
        .object([
            "createdAt": .string(createdAt),
            "displayGroups": .representables(displayGroups),
            "identityDigest": .string(identityDigest),
            "inferenceDigest": .string(inferenceDigest),
            "jobID": .string(jobID),
            "normalizationDigest": .string(normalizationDigest),
            "planID": .string(planID),
            "plannerVersion": .string(plannerVersion),
            "roots": .representables(roots),
            "sampleRate": .integer(sampleRate),
            "schemaVersion": .integer(Int64(schemaVersion)),
            "silencePlanDigest": .optionalString(silencePlanDigest),
            "silencePlanRelativePath": .optionalString(silencePlanRelativePath),
            "normalizedPCMSHA256": .optionalString(normalizedPCMSHA256),
            "workEndSample": .integer(workEndSample),
            "workStartSample": .integer(workStartSample)
        ])
    }

    /// The initial plan only. Recursive splits never change this, so a resumed
    /// run can confirm it is continuing the same decomposition.
    public static func computePlanID(
        plannerVersion: String = LocalPlannerStrategy.fixed,
        sampleRate: Int64 = LocalAudioCoordinates.sampleRate,
        workStartSample: Int64,
        workEndSample: Int64,
        roots: [LocalRootPlan],
        displayGroups: [LocalDisplayGroup]
    ) -> String {
        let payload = CanonicalJSONValue.object([
            "displayGroups": .representables(displayGroups),
            "plannerVersion": .string(plannerVersion),
            "roots": .representables(roots),
            "sampleRate": .integer(sampleRate),
            "workEndSample": .integer(workEndSample),
            "workStartSample": .integer(workStartSample)
        ])
        return LocalDigest.sha256(CanonicalJSONEncoder.encode(payload))
    }

    /// Ten-minute groups from the work start, last one cut at the real end.
    public static func makeDisplayGroups(
        workStartSample: Int64,
        workEndSample: Int64,
        groupSeconds: Double = LocalCheckpointSchema.displayGroupSeconds
    ) throws -> [LocalDisplayGroup] {
        let step = try LocalAudioCoordinates.quantize(seconds: groupSeconds)
        guard step > 0 else {
            throw LocalCoordinateError.nonFiniteSeconds(groupSeconds)
        }
        var groups: [LocalDisplayGroup] = []
        var cursor = workStartSample
        var order = 0
        while cursor < workEndSample {
            let advanced = cursor.addingReportingOverflow(step)
            let candidate = advanced.overflow ? workEndSample : min(advanced.partialValue, workEndSample)
            let end = max(candidate, cursor + 1)
            groups.append(
                LocalDisplayGroup(
                    groupID: LocalCheckpointID.displayGroup(
                        order: order,
                        startSample: cursor,
                        endSample: end
                    ),
                    startSample: cursor,
                    endSample: end
                )
            )
            cursor = end
            order += 1
        }
        return groups
    }
}

// MARK: - Root state (written by the Python helper)

public enum LocalNodeState: String, Codable, Equatable, Sendable {
    case pending
    case running
    case completed
    case verifiedSilence
    case gap
    case failed
    case split

    /// States that end a node's life without producing children.
    public var isTerminal: Bool {
        switch self {
        case .completed, .verifiedSilence, .gap, .failed:
            return true
        case .pending, .running, .split:
            return false
        }
    }

    /// Only these three count toward coverage. A `split` parent holds truncated
    /// text that must never reach the final transcript, and `failed` is a hole.
    public var contributesCoverage: Bool {
        switch self {
        case .completed, .verifiedSilence, .gap:
            return true
        case .pending, .running, .failed, .split:
            return false
        }
    }
}

public struct LocalFinishEvidence: Codable, Equatable, Sendable {
    public let generationTokens: Int
    public let maximumTokens: Int
    public let reachedTokenLimit: Bool
    public let finishReason: String

    public init(
        generationTokens: Int,
        maximumTokens: Int,
        reachedTokenLimit: Bool,
        finishReason: String
    ) {
        self.generationTokens = generationTokens
        self.maximumTokens = maximumTokens
        self.reachedTokenLimit = reachedTokenLimit
        self.finishReason = finishReason
    }
}

/// Phase 1 writes these; phase 0 records the shape so the state machine already
/// distinguishes "proved silent" from "model returned nothing".
public struct LocalSilenceEvidence: Codable, Equatable, Sendable {
    public let detector: String
    public let coveredStartSample: Int64
    public let coveredEndSample: Int64
    public let silencePlanDigest: String?
    public let thresholdDB: Double
    public let minimumDurationSeconds: Double

    public init(
        detector: String,
        coveredStartSample: Int64,
        coveredEndSample: Int64,
        thresholdDB: Double,
        minimumDurationSeconds: Double,
        silencePlanDigest: String? = nil
    ) {
        self.detector = detector
        self.coveredStartSample = coveredStartSample
        self.coveredEndSample = coveredEndSample
        self.thresholdDB = thresholdDB
        self.minimumDurationSeconds = minimumDurationSeconds
        self.silencePlanDigest = silencePlanDigest
    }

    public var coveredSpan: LocalSampleSpan {
        LocalSampleSpan(start: coveredStartSample, end: coveredEndSample)
    }
}

public struct LocalNodeAttempt: Codable, Equatable, Sendable {
    public let index: Int
    public let startedAt: String
    public let endedAt: String?
    public let outcome: String
    public let errorCode: String?
    public let spanSeconds: Double?

    public init(
        index: Int,
        startedAt: String,
        endedAt: String?,
        outcome: String,
        errorCode: String?,
        spanSeconds: Double?
    ) {
        self.index = index
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.errorCode = errorCode
        self.spanSeconds = spanSeconds
    }
}

public struct LocalLeafResult: Codable, Equatable, Sendable {
    /// Raw recognized text with no time headings and no gap markers mixed in.
    public let text: String
    public let textSHA256: String
    public let pcmSHA256: String
    public let finishEvidence: LocalFinishEvidence?
    public let silenceEvidence: LocalSilenceEvidence?
    public let gapReason: String?
    public let gapErrorCode: String?

    public init(
        text: String,
        textSHA256: String,
        pcmSHA256: String,
        finishEvidence: LocalFinishEvidence?,
        silenceEvidence: LocalSilenceEvidence? = nil,
        gapReason: String? = nil,
        gapErrorCode: String? = nil
    ) {
        self.text = text
        self.textSHA256 = textSHA256
        self.pcmSHA256 = pcmSHA256
        self.finishEvidence = finishEvidence
        self.silenceEvidence = silenceEvidence
        self.gapReason = gapReason
        self.gapErrorCode = gapErrorCode
    }
}

public struct LocalCheckpointNode: Codable, Equatable, Sendable {
    public let nodeID: String
    public let parentID: String?
    public let startSample: Int64
    public let endSample: Int64
    public let splitDepth: Int
    public var state: LocalNodeState
    public var childrenIDs: [String]
    public var attempts: [LocalNodeAttempt]
    public var result: LocalLeafResult?
    /// Split policy adopted when this subtree was created; recorded on the root
    /// revision rather than folded into `planID`.
    public var splitPolicy: String?

    public init(
        nodeID: String,
        parentID: String? = nil,
        startSample: Int64,
        endSample: Int64,
        splitDepth: Int = 0,
        state: LocalNodeState = .pending,
        childrenIDs: [String] = [],
        attempts: [LocalNodeAttempt] = [],
        result: LocalLeafResult? = nil,
        splitPolicy: String? = nil
    ) {
        self.nodeID = nodeID
        self.parentID = parentID
        self.startSample = startSample
        self.endSample = endSample
        self.splitDepth = splitDepth
        self.state = state
        self.childrenIDs = childrenIDs
        self.attempts = attempts
        self.result = result
        self.splitPolicy = splitPolicy
    }

    public var span: LocalSampleSpan {
        LocalSampleSpan(start: startSample, end: endSample)
    }

    private enum CodingKeys: String, CodingKey {
        case nodeID, parentID, startSample, endSample, splitDepth
        case state, childrenIDs, attempts, result, splitPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try container.decode(String.self, forKey: .nodeID)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        startSample = try StrictCheckpointDecoding.int64(container, .startSample, field: "node.startSample")
        endSample = try StrictCheckpointDecoding.int64(container, .endSample, field: "node.endSample")
        splitDepth = Int(try StrictCheckpointDecoding.int64(container, .splitDepth, field: "node.splitDepth"))
        state = try container.decode(LocalNodeState.self, forKey: .state)
        childrenIDs = try container.decodeIfPresent([String].self, forKey: .childrenIDs) ?? []
        attempts = try container.decodeIfPresent([LocalNodeAttempt].self, forKey: .attempts) ?? []
        result = try container.decodeIfPresent(LocalLeafResult.self, forKey: .result)
        splitPolicy = try container.decodeIfPresent(String.self, forKey: .splitPolicy)
    }
}

public struct LocalRootState: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let identityDigest: String
    public let planID: String
    public let rootID: String
    /// Monotonically increasing; a rollback means the file was replaced.
    public var revision: Int
    public var splitPolicy: String?
    public var nodes: [LocalCheckpointNode]

    public init(
        schemaVersion: Int = LocalCheckpointSchema.version,
        identityDigest: String,
        planID: String,
        rootID: String,
        revision: Int,
        splitPolicy: String? = nil,
        nodes: [LocalCheckpointNode]
    ) {
        self.schemaVersion = schemaVersion
        self.identityDigest = identityDigest
        self.planID = planID
        self.rootID = rootID
        self.revision = revision
        self.splitPolicy = splitPolicy
        self.nodes = nodes
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, identityDigest, planID, rootID, revision, splitPolicy, nodes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = Int(
            try StrictCheckpointDecoding.int64(container, .schemaVersion, field: "rootState.schemaVersion")
        )
        identityDigest = try container.decode(String.self, forKey: .identityDigest)
        planID = try container.decode(String.self, forKey: .planID)
        rootID = try container.decode(String.self, forKey: .rootID)
        revision = Int(try StrictCheckpointDecoding.int64(container, .revision, field: "rootState.revision"))
        splitPolicy = try container.decodeIfPresent(String.self, forKey: .splitPolicy)
        nodes = try container.decode([LocalCheckpointNode].self, forKey: .nodes)
    }

    public func node(_ nodeID: String) -> LocalCheckpointNode? {
        nodes.first { $0.nodeID == nodeID }
    }

    /// An interrupted `running` node is unproven work, never a completion.
    public func demotingUncommittedRunning() -> LocalRootState {
        var copy = self
        copy.nodes = nodes.map { node in
            guard node.state == .running else { return node }
            var demoted = node
            demoted.state = .pending
            demoted.result = nil
            return demoted
        }
        return copy
    }
}

/// Derived from the terminal leaves; never read from a stored flag.
public enum LocalRootOutcome: String, Equatable, Sendable {
    case completed
    case completedWithGaps
    case incomplete
}

/// Checks decoded integer values and gives them field-specific diagnostics.
/// JSONDecoder can still accept integral floating tokens such as `1.0`; a
/// persisted contract requiring lexical integers must check the raw JSON first
/// (as LocalSilencePlan.decodePersisted does).
enum StrictCheckpointDecoding {
    static func int64<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        _ key: Key,
        field: String
    ) throws -> Int64 {
        if (try? container.decode(Bool.self, forKey: key)) != nil {
            throw LocalCheckpointError.invalidField(
                field: field,
                reason: "布林值不可當作整數 sample 座標。"
            )
        }
        do {
            return try container.decode(Int64.self, forKey: key)
        } catch {
            throw LocalCheckpointError.invalidField(
                field: field,
                reason: "必須是整數，不接受浮點或缺值。"
            )
        }
    }
}

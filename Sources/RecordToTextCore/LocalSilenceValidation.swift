import Foundation

/// Constructed only after the analysis has been bound to the frozen identity.
/// No audio cache or model runtime is needed to verify previously committed leaves.
public struct VerifiedLocalSilence: Sendable {
    public let plan: LocalSilencePlan
    public let digest: String
    private let planID: String
    private let identityDigest: String
    private let thresholdDB: Double
    private let index: LocalSilenceCandidateIndex

    fileprivate init(plan: LocalSilencePlan, digest: String, manifest: LocalCheckpointManifest, thresholdDB: Double) {
        self.plan = plan
        self.digest = digest
        self.planID = manifest.planID
        self.identityDigest = manifest.identityDigest
        self.thresholdDB = thresholdDB
        self.index = plan.candidateIndex
    }

    /// Proves one leaf was silent, on this validator's own terms.
    ///
    /// `LocalCheckpointValidator` checks the same rules from the state-machine
    /// side, and phase 2 will call this without it, so the contradiction that
    /// matters most is enforced here too: a leaf claiming verified silence may
    /// not also carry recognized text.
    func validate(node: LocalCheckpointNode, manifest: LocalCheckpointManifest, root: LocalRootPlan) throws {
        guard planID == manifest.planID, identityDigest == manifest.identityDigest,
              digest == manifest.silencePlanDigest,
              let result = node.result, let evidence = result.silenceEvidence,
              evidence.silencePlanDigest == digest,
              evidence.detector == plan.detector,
              evidence.thresholdDB == thresholdDB,
              evidence.minimumDurationSeconds == plan.thresholds.minimumSilenceDurationSeconds,
              evidence.coveredSpan == node.span,
              result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.pcmSHA256 == root.pcmSHA256,
              result.textSHA256 == LocalDigest.sha256(result.text),
              index.covers(node.span)
        else { throw LocalCheckpointError.emptyUnverified(nodeID: node.nodeID) }
    }
}

public enum LocalSilenceValidation {
    static func invalid(_ field: String) -> LocalCheckpointError {
        .invalidField(field: field, reason: "靜音計畫缺少有效證據或與凍結契約不符；保留原資料，不自動改寫。")
    }

    static func isDigest(_ value: String?) -> Bool {
        guard let value, value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func validateReference(_ manifest: LocalCheckpointManifest) throws {
        switch manifest.plannerVersion {
        case LocalPlannerStrategy.fixed:
            guard manifest.silencePlanDigest == nil, manifest.silencePlanRelativePath == nil else {
                throw invalid("fixed.silencePlan")
            }
        case LocalPlannerStrategy.silence:
            guard isDigest(manifest.silencePlanDigest), isDigest(manifest.normalizedPCMSHA256),
                  let path = manifest.silencePlanRelativePath, !path.isEmpty else {
                throw invalid("manifest.silencePlan")
            }
        default: throw invalid("plannerVersion")
        }
    }

    public static func load(layout: LocalCheckpointLayout, manifest: LocalCheckpointManifest, identity: LocalIdentityDocument) throws -> VerifiedLocalSilence? {
        try validateReference(manifest)
        guard let relative = manifest.silencePlanRelativePath, let expected = manifest.silencePlanDigest else { return nil }
        let url = try layout.resolve(relativePath: relative)
        let bytes = try LocalCheckpointValidator.readBytes(at: url)
        let actual = LocalDigest.sha256(bytes)
        guard actual == expected else {
            throw LocalCheckpointError.digestMismatch(kind: "silence-plan.json", expected: expected, actual: actual)
        }
        let plan: LocalSilencePlan
        do { plan = try LocalSilencePlan.decodePersisted(from: bytes) }
        catch let error as LocalCheckpointError { throw error }
        catch { throw LocalCheckpointError.invalidJSON(path: url.path, reason: error.localizedDescription) }
        return try validate(plan: plan, manifest: manifest, identity: identity, digest: actual)
    }

    public static func validate(plan: LocalSilencePlan?, manifest: LocalCheckpointManifest, identity: LocalIdentityDocument, digest: String?) throws -> VerifiedLocalSilence? {
        try validateReference(manifest)
        guard manifest.plannerVersion == LocalPlannerStrategy.silence else {
            guard plan == nil else { throw invalid("fixed.silencePlan") }
            return nil
        }
        guard let plan, let digest, digest == manifest.silencePlanDigest,
              plan.schemaVersion == LocalCheckpointSchema.version,
              plan.plannerVersion == manifest.plannerVersion, plan.enabled,
              plan.detector == LocalSilencePlan.ffmpegDetector,
              plan.coveredStartSample >= 0, plan.coveredSpan == manifest.workSpan,
              plan.coveredEndSample > plan.coveredStartSample else { throw invalid("silencePlan") }
        for (name, actual, expected) in [
            ("sourceSHA256", plan.sourceSHA256, identity.source.sourceSHA256),
            ("normalizationDigest", plan.normalizationDigest, manifest.normalizationDigest),
            ("scanPCMSHA256", plan.scanPCMSHA256, manifest.normalizedPCMSHA256 ?? "")
        ] {
            guard isDigest(actual), actual == expected else {
                throw LocalCheckpointError.digestMismatch(kind: name, expected: expected, actual: actual)
            }
        }
        let t = plan.thresholds
        let positive = [t.maximumRootSeconds, t.displayGroupSeconds, t.chunkSeconds, t.minimumChildSeconds, t.minimumSilenceDurationSeconds]
        let windows = [t.outerSearchSeconds, t.displaySearchSeconds, t.innerSearchSeconds, t.recursiveSearchSeconds]
        guard positive.allSatisfy({ $0.isFinite && $0 > 0 }),
              windows.allSatisfy({ $0.isFinite && $0 >= 0 }),
              t.maximumRootSeconds <= 1200, t.displayGroupSeconds == 600, t.chunkSeconds == 120,
              t.minimumChildSeconds == 30, t.outerSearchSeconds <= 30,
              t.displaySearchSeconds <= 5, t.innerSearchSeconds <= 5, t.recursiveSearchSeconds <= 5,
              t.maximumIntervalCount > 0, t.maximumIntervalCount <= 100_000,
              plan.intervals.count <= t.maximumIntervalCount,
              !plan.truncated || plan.intervals.isEmpty else { throw invalid("thresholds/intervals") }
        let profile = t.noiseProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard profile.lowercased().hasSuffix("db"),
              let db = Double(profile.dropLast(2)), db.isFinite, db <= 0 else { throw invalid("noiseProfile") }
        var previousEnd: Int64?
        for interval in plan.intervals {
            guard interval.startSample >= plan.coveredStartSample,
                  interval.endSample <= plan.coveredEndSample, interval.endSample > interval.startSample,
                  previousEnd.map({ interval.startSample > $0 }) ?? true else { throw invalid("intervals") }
            previousEnd = interval.endSample
        }
        guard [plan.scanCount, plan.cacheHitCount, plan.outerSilenceCuts, plan.outerFallbacks, plan.innerSilenceCuts, plan.innerFallbacks].allSatisfy({ $0 >= 0 }),
              [plan.scannedAudioSeconds, plan.scanElapsedMilliseconds].allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw invalid("metrics") }
        return VerifiedLocalSilence(plan: plan, digest: digest, manifest: manifest, thresholdDB: db)
    }
}

extension OutputContractValidator {
    /// The only exception to the nonempty root TXT contract: independently
    /// verified silence covering the entire root. File and event checks remain.
    public static func readLocalTranscript(at url: URL, checkpoint: ASRCheckpointV2, prompt: String? = nil) throws -> String {
        let layout = LocalCheckpointLayout(recoveryDirectory: URL(fileURLWithPath: checkpoint.directory).deletingLastPathComponent())
        guard let manifest = try LocalCheckpointPlanner.loadFrozenManifest(layout: layout),
              manifest.identityDigest == checkpoint.identityDigest, manifest.planID == checkpoint.planID,
              manifest.sampleRate == checkpoint.sampleRate,
              manifest.workStartSample == checkpoint.workStartSample, manifest.workEndSample == checkpoint.workEndSample,
              let root = manifest.roots.first(where: { $0.rootID == checkpoint.rootID }),
              root.startSample == checkpoint.audioStartSample else { throw LocalSilenceValidation.invalid("request.checkpointV2") }
        let identity = try LocalCheckpointValidator.loadIdentity(at: layout.identityURL).document
        let silence = try LocalSilenceValidation.load(layout: layout, manifest: manifest, identity: identity)
        let state = try LocalCheckpointValidator.loadRootState(at: layout.resolve(relativePath: root.stateRelativePath))
        let outcome = try LocalCheckpointValidator.validate(rootState: state, plan: root, manifest: manifest, silence: silence)
        guard outcome != .incomplete else { throw LocalCheckpointError.coverageFailure(reason: "root 尚未完成。") }
        do { return try readTranscript(at: url, prompt: prompt) }
        catch TextFileValidationError.empty {
            let leaves = LocalCheckpointValidator.effectiveLeaves(in: state)
            guard !leaves.isEmpty, leaves.allSatisfy({ $0.state == .verifiedSilence }) else { throw TextFileValidationError.empty(url.path) }
            return ""
        }
    }
}

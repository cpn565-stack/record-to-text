import Foundation

/// One decoded root WAV plus the evidence describing exactly what it contains.
///
/// `sampleCount` is the decoded PCM sample count, never a container duration,
/// and `pcmSHA256` covers only the data chunk so it stays stable across
/// metadata differences.
public struct LocalRootSource: Equatable, Sendable {
    public let order: Int
    public let audioURL: URL
    public let sampleCount: Int64
    public let pcmSHA256: String

    public init(order: Int, audioURL: URL, sampleCount: Int64, pcmSHA256: String) {
        self.order = order
        self.audioURL = audioURL
        self.sampleCount = sampleCount
        self.pcmSHA256 = pcmSHA256
    }
}

/// A root's frozen span, before its chunks are planned.
///
/// Split out because §4 fixes an order: root spans first, then display groups
/// that may snap to them, then chunks that may not cross either.
public struct LocalRootSpan: Equatable, Sendable {
    public let order: Int
    public let startSample: Int64
    public let endSample: Int64
    public let pcmSHA256: String

    public var span: LocalSampleSpan {
        LocalSampleSpan(start: startSample, end: endSample)
    }
}

/// How many boundaries each layer moved onto a pause (§7).
public struct LocalPlannerCutTally: Equatable, Sendable {
    public var innerSilenceCuts = 0
    public var innerFallbacks = 0
    public var displaySnappedToRoot = 0
    public var displayMovedBySilence = 0
}

public enum LocalPlannerError: LocalizedError, Equatable {
    case noRoots
    case orderGap(expected: Int, found: Int)
    case emptyRoot(order: Int)
    case workStartMismatch(expected: Int64, found: Int64)
    case workEndMismatch(expected: Int64, found: Int64)
    case chunkWindowTooSmall(seconds: Double)
    case frozenPlanAlreadyExists(path: String)
    case frozenIdentityChanged(path: String)
    case frozenPlanUnusable(reason: String)

    public var errorDescription: String? {
        switch self {
        case .noRoots:
            return "沒有任何 root 音訊可規劃。"
        case let .orderGap(expected, found):
            return "root 順序不連續：預期 \(expected)，實際 \(found)。"
        case let .emptyRoot(order):
            return "root \(order) 的解碼 sample 數為 0。"
        case let .workStartMismatch(expected, found):
            return "規劃的工作起點 \(found) 與音訊身分記錄的 \(expected) 不符。"
        case let .workEndMismatch(expected, found):
            return "規劃的工作終點 \(found) 與音訊身分記錄的 \(expected) 不符。"
        case let .chunkWindowTooSmall(seconds):
            return "chunk 窗口 \(seconds) 秒太短，無法規劃。"
        case let .frozenPlanAlreadyExists(path):
            return "已存在凍結的 checkpoint 計畫，不可覆寫：\(path)"
        case let .frozenIdentityChanged(path):
            return "凍結的音訊身分與本次重新計算的結果不符：\(path)"
        case let .frozenPlanUnusable(reason):
            return "已凍結的 v2 分段計畫無法沿用：\(reason)"
        }
    }
}

/// Builds and freezes the v2 plan from measured audio, never from arithmetic.
///
/// Root boundaries are the cumulative sum of *decoded* sample counts, so an
/// ffmpeg cut that lands a few samples off a round number is recorded as it
/// actually is instead of being assumed away.
public enum LocalCheckpointPlanner {
    /// §4 step 1: root spans only. Display groups need them before chunks can
    /// be planned, so the spans are produced on their own.
    public static func makeRootSpans(
        workStartSample: Int64,
        sources: [LocalRootSource]
    ) throws -> [LocalRootSpan] {
        guard !sources.isEmpty else {
            throw LocalPlannerError.noRoots
        }
        var spans: [LocalRootSpan] = []
        var cursor = workStartSample
        for (index, source) in sources.enumerated() {
            guard source.order == index else {
                throw LocalPlannerError.orderGap(expected: index, found: source.order)
            }
            guard source.sampleCount > 0 else {
                throw LocalPlannerError.emptyRoot(order: index)
            }
            let start = cursor
            let (end, overflow) = start.addingReportingOverflow(source.sampleCount)
            guard !overflow else {
                throw LocalCoordinateError.overflow(field: "root.\(index)")
            }
            spans.append(
                LocalRootSpan(
                    order: index,
                    startSample: start,
                    endSample: end,
                    pcmSHA256: source.pcmSHA256
                )
            )
            cursor = end
        }
        return spans
    }

    /// §4 step 2: the ten-minute display grid.
    ///
    /// Targets are `workStart + k×600s`, never `previousEnd + 600s`. §5 forbids
    /// accumulating drift, so a group snapped five seconds early must not push
    /// every later heading five seconds early too.
    ///
    /// With no root boundaries and no candidates this reduces to the exact grid.
    public static func makeDisplayGroups(
        workStartSample: Int64,
        workEndSample: Int64,
        rootBoundaries: [Int64] = [],
        candidates: LocalSilenceCandidateIndex = .empty,
        thresholds: LocalSilenceThresholds = .current,
        tally: inout LocalPlannerCutTally?
    ) throws -> [LocalDisplayGroup] {
        try makeDisplayGroupsInternal(
            workStartSample: workStartSample,
            workEndSample: workEndSample,
            rootBoundaries: rootBoundaries,
            candidates: candidates,
            thresholds: thresholds,
            tally: &tally
        )
    }

    public static func makeDisplayGroups(
        workStartSample: Int64,
        workEndSample: Int64,
        rootBoundaries: [Int64] = [],
        candidates: LocalSilenceCandidateIndex = .empty,
        thresholds: LocalSilenceThresholds = .current
    ) throws -> [LocalDisplayGroup] {
        var unused: LocalPlannerCutTally?
        return try makeDisplayGroupsInternal(
            workStartSample: workStartSample,
            workEndSample: workEndSample,
            rootBoundaries: rootBoundaries,
            candidates: candidates,
            thresholds: thresholds,
            tally: &unused
        )
    }

    private static func makeDisplayGroupsInternal(
        workStartSample: Int64,
        workEndSample: Int64,
        rootBoundaries: [Int64],
        candidates: LocalSilenceCandidateIndex,
        thresholds: LocalSilenceThresholds,
        tally: inout LocalPlannerCutTally?
    ) throws -> [LocalDisplayGroup] {
        let step = try LocalAudioCoordinates.quantize(seconds: thresholds.displayGroupSeconds)
        guard step > 0 else {
            throw LocalCoordinateError.nonFiniteSeconds(thresholds.displayGroupSeconds)
        }
        let search = try LocalAudioCoordinates.quantize(seconds: thresholds.displaySearchSeconds)
        var groups: [LocalDisplayGroup] = []
        var cursor = workStartSample
        var order = 0
        var targetIndex: Int64 = 1
        while cursor < workEndSample {
            let end: Int64
            let target = workStartSample.addingReportingOverflow(step * targetIndex)
            if target.overflow || target.partialValue >= workEndSample {
                end = workEndSample
            } else {
                let nominal = target.partialValue
                let lower = cursor + 1
                let upper = workEndSample - 1
                if let snapped = LocalSilenceBoundarySelector.nearestRootBoundary(
                    to: nominal,
                    searchSamples: search,
                    rootBoundaries: rootBoundaries,
                    lowerBound: lower,
                    upperBound: upper
                ) {
                    end = snapped
                    tally?.displaySnappedToRoot += 1
                } else {
                    let decision = LocalSilenceBoundarySelector.nearestBoundary(
                        target: nominal,
                        searchSamples: search,
                        lowerBound: lower,
                        upperBound: upper,
                        candidates: candidates
                    )
                    end = decision.boundary
                    if decision.usedSilence {
                        tally?.displayMovedBySilence += 1
                    }
                }
            }
            // Termination guard: a snapped boundary can never regress past the
            // cursor, but if it somehow did the group would consume the rest of
            // the work rather than spin forever.
            let groupEnd = end > cursor ? end : workEndSample
            groups.append(
                LocalDisplayGroup(
                    groupID: LocalCheckpointID.displayGroup(
                        order: order,
                        startSample: cursor,
                        endSample: groupEnd
                    ),
                    startSample: cursor,
                    endSample: groupEnd
                )
            )
            cursor = groupEnd
            order += 1
            targetIndex += 1
        }
        return groups
    }

    /// §4 steps 3–4: sub-intervals from the union of root and display-group
    /// boundaries, then chunks of at most `chunkSeconds` inside each.
    ///
    /// A chunk never crosses a display group, which is what lets §5 promise the
    /// merger never has to split one recognized block of text across two
    /// headings. Boundary and final tails may be shorter than 30 seconds — the
    /// 30-second floor belongs to recursion, not to tail deletion.
    ///
    /// `displayGroups` is required rather than derived here because the same
    /// groups must appear in the manifest; computing them twice would let the
    /// chunks and the headings disagree about where a group starts.
    public static func makeRootPlans(
        workStartSample: Int64,
        sources: [LocalRootSource],
        chunkSeconds: Double,
        displayGroups: [LocalDisplayGroup],
        candidates: LocalSilenceCandidateIndex = .empty,
        thresholds: LocalSilenceThresholds = .current,
        tally: inout LocalPlannerCutTally?
    ) throws -> [LocalRootPlan] {
        let spans = try makeRootSpans(
            workStartSample: workStartSample,
            sources: sources
        )
        let stepSamples = chunkSeconds * Double(LocalAudioCoordinates.sampleRate)
        guard stepSamples.isFinite, stepSamples >= 1 else {
            throw LocalPlannerError.chunkWindowTooSmall(seconds: chunkSeconds)
        }
        let step = max(Int64(stepSamples.rounded(.down)), 1)
        let search = try LocalAudioCoordinates.quantize(seconds: thresholds.innerSearchSeconds)

        var plans: [LocalRootPlan] = []
        for (index, span) in spans.enumerated() {
            let rootID = LocalCheckpointID.root(
                order: index,
                startSample: span.startSample,
                endSample: span.endSample
            )
            plans.append(
                LocalRootPlan(
                    rootID: rootID,
                    order: index,
                    startSample: span.startSample,
                    endSample: span.endSample,
                    pcmSHA256: span.pcmSHA256,
                    audioRelativePath: "\(LocalCheckpointSchema.audioDirectoryName)/\(rootID).wav",
                    stateRelativePath: "\(LocalCheckpointSchema.rootsDirectoryName)/\(rootID).json",
                    initialChunks: makeChunkPlans(
                        rootID: rootID,
                        span: span.span,
                        displayGroups: displayGroups,
                        step: step,
                        searchSamples: search,
                        candidates: candidates,
                        tally: &tally
                    )
                )
            )
        }
        return plans
    }

    /// Fixed-grid chunk planning, for callers that move no boundary at all.
    ///
    /// Uses the exact ten-minute grid so the chunks line up with what `freeze`
    /// records when it is given no display groups of its own.
    public static func makeRootPlans(
        workStartSample: Int64,
        sources: [LocalRootSource],
        chunkSeconds: Double
    ) throws -> [LocalRootPlan] {
        let spans = try makeRootSpans(
            workStartSample: workStartSample,
            sources: sources
        )
        let groups = try LocalCheckpointManifest.makeDisplayGroups(
            workStartSample: workStartSample,
            workEndSample: spans[spans.count - 1].endSample
        )
        var unused: LocalPlannerCutTally?
        return try makeRootPlans(
            workStartSample: workStartSample,
            sources: sources,
            chunkSeconds: chunkSeconds,
            displayGroups: groups,
            tally: &unused
        )
    }

    private static func makeChunkPlans(
        rootID: String,
        span: LocalSampleSpan,
        displayGroups: [LocalDisplayGroup],
        step: Int64,
        searchSamples: Int64,
        candidates: LocalSilenceCandidateIndex,
        tally: inout LocalPlannerCutTally?
    ) -> [LocalChunkPlan] {
        var cuts: Set<Int64> = [span.start, span.end]
        for group in displayGroups {
            if group.startSample > span.start, group.startSample < span.end {
                cuts.insert(group.startSample)
            }
            if group.endSample > span.start, group.endSample < span.end {
                cuts.insert(group.endSample)
            }
        }
        let boundaries = cuts.sorted()

        var chunks: [LocalChunkPlan] = []
        var order = 0
        for (position, subIntervalStart) in boundaries.enumerated()
        where position + 1 < boundaries.count {
            let subIntervalEnd = boundaries[position + 1]
            var cursor = subIntervalStart
            while cursor < subIntervalEnd {
                let nominal = cursor.addingReportingOverflow(step)
                let chunkEnd: Int64
                if nominal.overflow || nominal.partialValue >= subIntervalEnd {
                    chunkEnd = subIntervalEnd
                } else {
                    let decision = LocalSilenceBoundarySelector.limitBoundary(
                        limit: nominal.partialValue,
                        searchSamples: searchSamples,
                        lowerBound: cursor,
                        upperBound: subIntervalEnd,
                        candidates: candidates
                    )
                    chunkEnd = decision.boundary
                    if decision.usedSilence {
                        tally?.innerSilenceCuts += 1
                    } else {
                        tally?.innerFallbacks += 1
                    }
                }
                chunks.append(
                    LocalChunkPlan(
                        nodeID: LocalCheckpointID.chunk(
                            rootID: rootID,
                            order: order,
                            startSample: cursor,
                            endSample: chunkEnd
                        ),
                        startSample: cursor,
                        endSample: chunkEnd
                    )
                )
                cursor = chunkEnd
                order += 1
            }
        }
        return chunks
    }

    /// Validate the plan, then publish `identity.json` and `manifest.json`.
    ///
    /// The manifest records the digest of the identity file's exact bytes, so
    /// the identity is written first and the manifest second. Both writes are
    /// atomic and 0600. The silence plan, when there is one, is written before
    /// the manifest so the digest the manifest records already exists on disk.
    @discardableResult
    public static func freeze(
        layout: LocalCheckpointLayout,
        identity: LocalIdentityDocument,
        roots: [LocalRootPlan],
        createdAt: String,
        plannerVersion: String = LocalPlannerStrategy.fixed,
        displayGroups: [LocalDisplayGroup]? = nil,
        silencePlan: LocalSilencePlan? = nil,
        normalizedPCMSHA256: String? = nil,
        fileManager: FileManager = .default
    ) throws -> LocalCheckpointManifest {
        guard !roots.isEmpty else {
            throw LocalPlannerError.noRoots
        }
        guard roots[0].startSample == identity.source.workStartSample else {
            throw LocalPlannerError.workStartMismatch(
                expected: identity.source.workStartSample,
                found: roots[0].startSample
            )
        }
        guard roots[roots.count - 1].endSample == identity.source.workEndSample else {
            throw LocalPlannerError.workEndMismatch(
                expected: identity.source.workEndSample,
                found: roots[roots.count - 1].endSample
            )
        }

        // Build and prove the whole pair in memory first. Writing identity.json
        // before knowing the manifest validates would leave a half-written plan
        // on disk that a later resume has to reject by hand.
        let identityBytes = identity.canonicalBytes()
        let identityDigest = LocalDigest.sha256(identityBytes)
        let groups: [LocalDisplayGroup]
        if let displayGroups {
            groups = displayGroups
        } else {
            groups = try LocalCheckpointManifest.makeDisplayGroups(
                workStartSample: identity.source.workStartSample,
                workEndSample: identity.source.workEndSample
            )
        }
        let manifest = LocalCheckpointManifest(
            jobID: identity.jobID,
            identityDigest: identityDigest,
            inferenceDigest: identity.inference.digest,
            normalizationDigest: LocalDigest.sha256(identity.normalizationProfile),
            workStartSample: identity.source.workStartSample,
            workEndSample: identity.source.workEndSample,
            planID: LocalCheckpointManifest.computePlanID(
                plannerVersion: plannerVersion,
                workStartSample: identity.source.workStartSample,
                workEndSample: identity.source.workEndSample,
                roots: roots,
                displayGroups: groups
            ),
            plannerVersion: plannerVersion,
            roots: roots,
            displayGroups: groups,
            silencePlanDigest: silencePlan?.digest,
            silencePlanRelativePath: silencePlan.map { _ in
                LocalCheckpointSchema.silencePlanFileName
            },
            normalizedPCMSHA256: normalizedPCMSHA256,
            createdAt: createdAt
        )
        try LocalCheckpointValidator.validate(
            manifest: manifest,
            identity: identity,
            identityDigest: identityDigest
        )

        _ = try LocalSilenceValidation.validate(plan: silencePlan, manifest: manifest, identity: identity, digest: silencePlan?.digest)
        try layout.createDirectories(fileManager: fileManager)
        try AtomicFileWriter.write(identityBytes, to: layout.identityURL)
        if let silencePlan {
            try LocalSilencePlanStore.write(
                silencePlan,
                to: layout,
                fileManager: fileManager
            )
        }
        try AtomicFileWriter.write(manifest.canonicalBytes(), to: layout.manifestURL)
        return manifest
    }

    /// Load a previously frozen plan, or freeze a new one when none exists.
    ///
    /// A resume must never rewrite the plan it is resuming from: the persisted
    /// root states are only interpretable against the original `planID`. An
    /// identity that recomputes differently means the audio or the inference
    /// settings moved, which is a hard stop rather than a silent re-plan.
    ///
    /// Returns the persisted manifest together with a flag saying whether it was
    /// loaded or freshly frozen, because §2 makes the persisted `planID`
    /// authoritative and the caller must then discard the boundaries it just
    /// recomputed instead of quietly mixing the two.
    public static func openOrFreeze(
        layout: LocalCheckpointLayout,
        identity: LocalIdentityDocument,
        roots: [LocalRootPlan],
        createdAt: String,
        plannerVersion: String = LocalPlannerStrategy.fixed,
        displayGroups: [LocalDisplayGroup]? = nil,
        silencePlan: LocalSilencePlan? = nil,
        normalizedPCMSHA256: String? = nil,
        fileManager: FileManager = .default
    ) throws -> (manifest: LocalCheckpointManifest, loadedExisting: Bool) {
        let hasIdentity = fileManager.fileExists(atPath: layout.identityURL.path)
        let hasManifest = fileManager.fileExists(atPath: layout.manifestURL.path)
        guard hasIdentity || hasManifest else {
            let manifest = try freeze(
                layout: layout,
                identity: identity,
                roots: roots,
                createdAt: createdAt,
                plannerVersion: plannerVersion,
                displayGroups: displayGroups,
                silencePlan: silencePlan,
                normalizedPCMSHA256: normalizedPCMSHA256,
                fileManager: fileManager
            )
            return (manifest, false)
        }
        guard hasIdentity, hasManifest else {
            throw LocalCheckpointError.invalidField(
                field: "checkpoint",
                reason: "identity.json 與 manifest.json 必須同時存在，只找到其中一個。"
            )
        }

        let loaded = try LocalCheckpointValidator.loadIdentity(
            at: layout.identityURL,
            fileManager: fileManager
        )
        guard loaded.digest == LocalDigest.sha256(identity.canonicalBytes()) else {
            throw LocalPlannerError.frozenIdentityChanged(path: layout.identityURL.path)
        }
        let manifest = try LocalCheckpointValidator.loadManifest(
            at: layout.manifestURL,
            fileManager: fileManager
        )
        try LocalCheckpointValidator.validate(
            manifest: manifest,
            identity: loaded.document,
            identityDigest: loaded.digest
        )
        _ = try LocalSilenceValidation.load(layout: layout, manifest: manifest, identity: loaded.document)
        return (manifest, true)
    }

    /// Read a frozen manifest without freezing anything.
    ///
    /// A resume uses this to re-extract exactly the audio the persisted root
    /// states describe. Re-deriving the outer boundaries instead would let a
    /// changed setting or a differently-behaving detector move them, and then
    /// the committed leaves would sit next to audio they were never made from.
    public static func loadFrozenManifest(
        layout: LocalCheckpointLayout,
        fileManager: FileManager = .default
    ) throws -> LocalCheckpointManifest? {
        let hasIdentity = fileManager.fileExists(atPath: layout.identityURL.path)
        let hasManifest = fileManager.fileExists(atPath: layout.manifestURL.path)
        guard hasIdentity || hasManifest else {
            return nil
        }
        guard hasIdentity, hasManifest else {
            throw LocalCheckpointError.invalidField(
                field: "checkpoint",
                reason: "identity.json 與 manifest.json 必須同時存在，只找到其中一個。"
            )
        }
        let loaded = try LocalCheckpointValidator.loadIdentity(
            at: layout.identityURL,
            fileManager: fileManager
        )
        let manifest = try LocalCheckpointValidator.loadManifest(
            at: layout.manifestURL,
            fileManager: fileManager
        )
        try LocalCheckpointValidator.validate(
            manifest: manifest,
            identity: loaded.document,
            identityDigest: loaded.digest
        )
        _ = try LocalSilenceValidation.load(layout: layout, manifest: manifest, identity: loaded.document)
        return manifest
    }
}

extension LocalCheckpointPlanner {
    /// Turn a frozen manifest back into the outer segmentation the extractor
    /// needs, so a resume cuts where the plan says and nowhere else.
    ///
    /// Boundaries are converted from absolute samples to normalized-audio
    /// seconds by subtracting `workStartSample`; the slice offset is already
    /// baked into that value and must not be applied twice.
    public static func segmentPlan(
        from manifest: LocalCheckpointManifest,
        maximumSegmentDuration: TimeInterval
    ) throws -> AudioSegmentationPlan {
        guard !manifest.roots.isEmpty else {
            throw LocalPlannerError.frozenPlanUnusable(reason: "計畫沒有任何 root。")
        }
        let rate = Double(LocalAudioCoordinates.sampleRate)
        var segments: [PlannedAudioSegment] = []
        segments.reserveCapacity(manifest.roots.count)
        for (index, root) in manifest.roots.enumerated() {
            guard root.order == index else {
                throw LocalPlannerError.frozenPlanUnusable(
                    reason: "root 順序不連續：第 \(index) 個的 order 是 \(root.order)。"
                )
            }
            guard root.endSample > root.startSample else {
                throw LocalPlannerError.frozenPlanUnusable(
                    reason: "root \(root.rootID) 範圍為空。"
                )
            }
            let start = Double(root.startSample - manifest.workStartSample) / rate
            let end = Double(root.endSample - manifest.workStartSample) / rate
            segments.append(
                PlannedAudioSegment(
                    index: index + 1,
                    startSeconds: start,
                    durationSeconds: end - start
                )
            )
        }
        let workSeconds = Double(
            manifest.workEndSample - manifest.workStartSample
        ) / rate
        return AudioSegmentationPlan(
            sourceDurationSeconds: workSeconds,
            maximumSegmentDurationSeconds: maximumSegmentDuration,
            segments: segments
        )
    }
}

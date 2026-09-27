import Foundation

/// Failure reasons for the local v2 checkpoint, using the phase 0 §7 taxonomy.
public enum LocalCheckpointError: LocalizedError, Equatable {
    case missingFile(path: String)
    case unreadable(path: String, reason: String)
    case invalidJSON(path: String, reason: String)
    case unknownSchemaVersion(found: Int, path: String)
    case legacyV1Detected(path: String)
    case invalidField(field: String, reason: String)
    case digestMismatch(kind: String, expected: String, actual: String)
    case identityMismatch(field: String, expected: String, actual: String)
    case unverifiableModelManifest(modelID: String)
    case sourceChanged(path: String)
    case pcmMismatch(rootID: String, expected: String, actual: String)
    case coverageFailure(reason: String)
    case revisionRegression(previous: Int, found: Int)
    case pathEscape(path: String, reason: String)
    case incompleteEvidence(nodeID: String, reason: String)
    case emptyUnverified(nodeID: String)
    case duplicateNode(nodeID: String)
    case unknownNode(reference: String, from: String)
    case splitInvariant(nodeID: String, reason: String)
    case planMismatch(field: String, expected: String, actual: String)

    /// Stable machine-readable code, safe to persist and to log.
    public var code: String {
        switch self {
        case .sourceChanged, .digestMismatch(kind: "sourceSHA256", _, _):
            return "local_source_changed"
        case .digestMismatch, .identityMismatch, .unverifiableModelManifest, .planMismatch:
            return "local_identity_mismatch"
        case .legacyV1Detected:
            return "local_checkpoint_legacy_unverified"
        case .pcmMismatch:
            return "local_pcm_mismatch"
        case .emptyUnverified, .incompleteEvidence:
            return "local_empty_unverified"
        default:
            return "local_checkpoint_invalid"
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .missingFile(path):
            return "找不到 checkpoint 檔案：\(path)"
        case let .unreadable(path, reason):
            return "無法讀取 checkpoint 檔案：\(path)\n\(reason)"
        case let .invalidJSON(path, reason):
            return "checkpoint 內容無法解析：\(path)\n\(reason)"
        case let .unknownSchemaVersion(found, path):
            return "不支援的 checkpoint 版本 \(found)：\(path)。拒絕沿用既有資料，可另建完整新工作。"
        case let .legacyV1Detected(path):
            return "偵測到舊版 v1 checkpoint：\(path)。只能取回既有草稿，不自動續跑，也不補寫目前來源 hash。"
        case let .invalidField(field, reason):
            return "checkpoint 欄位 \(field) 不合法：\(reason)"
        case let .digestMismatch(kind, expected, actual):
            return "\(kind) 摘要不符（記錄 \(expected.prefix(12))…，實際 \(actual.prefix(12))…）。"
        case let .identityMismatch(field, expected, actual):
            return "推論身分欄位 \(field) 已改變（記錄 \(expected)，目前 \(actual)），拒絕沿用既有結果。"
        case let .unverifiableModelManifest(modelID):
            return "模型 \(modelID) 沒有可驗證的內容 manifest，無法證明權重未變，拒絕跨執行沿用既有結果。"
        case let .sourceChanged(path):
            return "來源音檔內容與 checkpoint 記錄不符：\(path)"
        case let .pcmMismatch(rootID, expected, actual):
            return "root \(rootID) 的 PCM digest 不符（記錄 \(expected.prefix(12))…，實際 \(actual.prefix(12))…）。"
        case let .coverageFailure(reason):
            return "已完成 leaf 未精確覆蓋工作範圍：\(reason)"
        case let .revisionRegression(previous, found):
            return "root revision 由 \(previous) 退回 \(found)，拒絕採用較舊的提交。"
        case let .pathEscape(path, reason):
            return "checkpoint 相對路徑不合法：\(path)\n\(reason)"
        case let .incompleteEvidence(nodeID, reason):
            return "leaf \(nodeID) 缺少完成證據：\(reason)"
        case let .emptyUnverified(nodeID):
            return "leaf \(nodeID) 沒有文字，也沒有與範圍相符的靜音證據，不能當成完成。"
        case let .duplicateNode(nodeID):
            return "root state 內 nodeID 重複：\(nodeID)"
        case let .unknownNode(reference, from):
            return "node \(from) 引用了不存在的節點 \(reference)。"
        case let .splitInvariant(nodeID, reason):
            return "split 節點 \(nodeID) 不合法：\(reason)"
        case let .planMismatch(field, expected, actual):
            return "root plan 與 root state 的 \(field) 不符（plan \(expected)，state \(actual)）。"
        }
    }
}

/// Read-and-prove logic for the local v2 checkpoint.
///
/// Swift only ever reads root state; the Python helper is the single writer.
/// Nothing here loads the model or touches MLX, so structural validation must
/// succeed even when the runtime is unavailable.
public enum LocalCheckpointValidator {
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    // MARK: Loading

    public static func readBytes(at url: URL, fileManager: FileManager = .default) throws -> Data {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw LocalCheckpointError.missingFile(path: url.path)
        }
        guard !isDirectory.boolValue else {
            throw LocalCheckpointError.unreadable(path: url.path, reason: "路徑是目錄。")
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw LocalCheckpointError.pathEscape(path: url.path, reason: "不接受 symbolic link。")
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw LocalCheckpointError.unreadable(path: url.path, reason: error.localizedDescription)
        }
    }

    /// Returns the document plus the digest of the exact bytes on disk, which is
    /// what the manifest records.
    public static func loadIdentity(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> (document: LocalIdentityDocument, digest: String) {
        let bytes = try readBytes(at: url, fileManager: fileManager)
        try requireSchemaVersion(bytes: bytes, path: url.path)
        let document: LocalIdentityDocument
        do {
            document = try decoder.decode(LocalIdentityDocument.self, from: bytes)
        } catch let error as LocalCheckpointError {
            throw error
        } catch {
            throw LocalCheckpointError.invalidJSON(path: url.path, reason: error.localizedDescription)
        }
        return (document, LocalDigest.sha256(bytes))
    }

    public static func loadManifest(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> LocalCheckpointManifest {
        let bytes = try readBytes(at: url, fileManager: fileManager)
        try requireSchemaVersion(bytes: bytes, path: url.path)
        do {
            return try decoder.decode(LocalCheckpointManifest.self, from: bytes)
        } catch let error as LocalCheckpointError {
            throw error
        } catch {
            throw LocalCheckpointError.invalidJSON(path: url.path, reason: error.localizedDescription)
        }
    }

    public static func loadRootState(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> LocalRootState {
        let bytes = try readBytes(at: url, fileManager: fileManager)
        try requireSchemaVersion(bytes: bytes, path: url.path)
        do {
            return try decoder.decode(LocalRootState.self, from: bytes)
        } catch let error as LocalCheckpointError {
            throw error
        } catch {
            throw LocalCheckpointError.invalidJSON(path: url.path, reason: error.localizedDescription)
        }
    }

    private struct SchemaVersionProbe: Decodable {
        let schemaVersion: Int
    }

    /// A future v3 must be refused, not optimistically re-read as v2, so the
    /// version is checked before the typed payload is decoded. A document with
    /// no readable version falls through to the typed decode, which reports the
    /// real structural problem instead of a bogus version error.
    private static func requireSchemaVersion(bytes: Data, path: String) throws {
        guard let probe = try? decoder.decode(SchemaVersionProbe.self, from: bytes) else {
            return
        }
        try requireSchemaVersion(probe.schemaVersion, path: path)
    }

    private static func requireSchemaVersion(_ found: Int, path: String) throws {
        guard found == LocalCheckpointSchema.version else {
            throw LocalCheckpointError.unknownSchemaVersion(found: found, path: path)
        }
    }

    // MARK: Legacy v1

    /// Locates a v1 `chunk-checkpoints` directory. Retrieval stays allowed;
    /// automatic resume does not.
    public static func detectLegacyV1(
        in recoveryDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let directory = recoveryDirectory.appendingPathComponent(
            LocalChunkCheckpoint.directoryName,
            isDirectory: true
        )
        guard LocalChunkCheckpoint.containsUsableCheckpoint(
            in: recoveryDirectory,
            fileManager: fileManager
        ) else {
            return nil
        }
        return directory
    }

    // MARK: Manifest validation

    public static func validate(
        manifest: LocalCheckpointManifest,
        identity: LocalIdentityDocument,
        identityDigest: String
    ) throws {
        try validateSpan(
            LocalSampleSpan(start: manifest.workStartSample, end: manifest.workEndSample),
            field: "manifest.work"
        )

        guard manifest.identityDigest == identityDigest else {
            throw LocalCheckpointError.digestMismatch(
                kind: "identity.json",
                expected: manifest.identityDigest,
                actual: identityDigest
            )
        }
        guard manifest.inferenceDigest == identity.inference.digest else {
            throw LocalCheckpointError.digestMismatch(
                kind: "inferenceIdentity",
                expected: manifest.inferenceDigest,
                actual: identity.inference.digest
            )
        }
        try LocalSilenceValidation.validateReference(manifest)
        guard manifest.normalizationDigest
            == LocalDigest.sha256(identity.normalizationProfile)
        else {
            throw LocalCheckpointError.digestMismatch(
                kind: "normalizationIdentity",
                expected: manifest.normalizationDigest,
                actual: LocalDigest.sha256(identity.normalizationProfile)
            )
        }
        guard manifest.jobID == identity.jobID else {
            throw LocalCheckpointError.planMismatch(
                field: "jobID",
                expected: manifest.jobID,
                actual: identity.jobID
            )
        }
        guard manifest.sampleRate == LocalAudioCoordinates.sampleRate else {
            throw LocalCheckpointError.invalidField(
                field: "manifest.sampleRate",
                reason: "只支援 \(LocalAudioCoordinates.sampleRate) Hz，實際 \(manifest.sampleRate)。"
            )
        }
        guard manifest.workStartSample == identity.source.workStartSample,
              manifest.workEndSample == identity.source.workEndSample
        else {
            throw LocalCheckpointError.planMismatch(
                field: "workRange",
                expected: "[\(manifest.workStartSample), \(manifest.workEndSample))",
                actual: "[\(identity.source.workStartSample), \(identity.source.workEndSample))"
            )
        }
        guard identity.inference.canReuseAcrossRuns else {
            throw LocalCheckpointError.unverifiableModelManifest(
                modelID: identity.inference.modelID
            )
        }

        let recomputed = LocalCheckpointManifest.computePlanID(
            plannerVersion: manifest.plannerVersion,
            sampleRate: manifest.sampleRate,
            workStartSample: manifest.workStartSample,
            workEndSample: manifest.workEndSample,
            roots: manifest.roots,
            displayGroups: manifest.displayGroups
        )
        guard recomputed == manifest.planID else {
            throw LocalCheckpointError.digestMismatch(
                kind: "planID",
                expected: manifest.planID,
                actual: recomputed
            )
        }

        var seenRootIDs = Set<String>()
        var previousRootEnd = manifest.workStartSample
        for (index, root) in manifest.roots.enumerated() {
            guard root.order == index else {
                throw LocalCheckpointError.invalidField(
                    field: "root.order",
                    reason: "root 順序必須由 0 連續遞增，第 \(index) 個的 order 是 \(root.order)。"
                )
            }
            guard seenRootIDs.insert(root.rootID).inserted else {
                throw LocalCheckpointError.duplicateNode(nodeID: root.rootID)
            }
            guard root.startSample == previousRootEnd else {
                throw LocalCheckpointError.coverageFailure(
                    reason: "root 未連續覆蓋工作範圍：前段結束 \(previousRootEnd)，\(root.rootID) 起始 \(root.startSample)。"
                )
            }
            try validateSpan(root.span, field: "root.\(root.rootID)", within: manifest.workSpan)
            previousRootEnd = root.endSample

            var seenNodeIDs = Set<String>()
            var previousEnd = root.startSample
            for chunk in root.initialChunks {
                guard seenNodeIDs.insert(chunk.nodeID).inserted else {
                    throw LocalCheckpointError.duplicateNode(nodeID: chunk.nodeID)
                }
                guard chunk.startSample == previousEnd else {
                    throw LocalCheckpointError.coverageFailure(
                        reason: "root \(root.rootID) 的初始 chunk 未連續：前段結束 \(previousEnd)，下一段起始 \(chunk.startSample)。"
                    )
                }
                try validateSpan(chunk.span, field: "chunk.\(chunk.nodeID)", within: root.span)
                previousEnd = chunk.endSample
            }
            guard previousEnd == root.endSample else {
                throw LocalCheckpointError.coverageFailure(
                    reason: "root \(root.rootID) 的初始 chunk 未覆蓋到終點（\(previousEnd) ≠ \(root.endSample)）。"
                )
            }

            guard !root.audioRelativePath.isEmpty, !root.stateRelativePath.isEmpty else {
                throw LocalCheckpointError.invalidField(
                    field: "root.\(root.rootID).relativePath",
                    reason: "路徑不可為空。"
                )
            }
        }
        guard previousRootEnd == manifest.workEndSample else {
            throw LocalCheckpointError.coverageFailure(
                reason: "root 未覆蓋到工作終點（\(previousRootEnd) ≠ \(manifest.workEndSample)）。"
            )
        }

        var seenGroupIDs = Set<String>()
        var previousGroupEnd = manifest.workStartSample
        for group in manifest.displayGroups {
            guard seenGroupIDs.insert(group.groupID).inserted else {
                throw LocalCheckpointError.duplicateNode(nodeID: group.groupID)
            }
            guard group.startSample == previousGroupEnd else {
                throw LocalCheckpointError.coverageFailure(
                    reason: "displayGroup 未連續：前段結束 \(previousGroupEnd)，下一段起始 \(group.startSample)。"
                )
            }
            try validateSpan(group.span, field: "displayGroup.\(group.groupID)", within: manifest.workSpan)
            previousGroupEnd = group.endSample
        }
        guard previousGroupEnd == manifest.workEndSample else {
            throw LocalCheckpointError.coverageFailure(
                reason: "displayGroup 未覆蓋到工作終點（\(previousGroupEnd) ≠ \(manifest.workEndSample)）。"
            )
        }

        // §5: a chunk straddling a group boundary would put one recognized block
        // under two ten-minute headings, and the merger is not allowed to split
        // it by character count to fix that.
        let interiorGroupBoundaries = manifest.displayGroups.dropFirst().map(\.startSample)
        for root in manifest.roots {
            for chunk in root.initialChunks {
                guard let crossed = interiorGroupBoundaries.first(where: {
                    chunk.startSample < $0 && $0 < chunk.endSample
                }) else {
                    continue
                }
                throw LocalCheckpointError.invalidField(
                    field: "chunk.\(chunk.nodeID)",
                    reason: "初始 chunk（\(chunk.startSample)–\(chunk.endSample)）跨越 displayGroup 邊界 \(crossed)。"
                )
            }
        }
    }

    // MARK: Root state validation

    /// Proves the tree is structurally sound and reports what it actually covers.
    ///
    /// Throws only on corruption. Legitimately unfinished work returns
    /// `.incomplete` so a resume can continue from it.
    @discardableResult
    public static func validate(
        rootState: LocalRootState,
        plan: LocalRootPlan,
        manifest: LocalCheckpointManifest,
        silence: VerifiedLocalSilence? = nil
    ) throws -> LocalRootOutcome {
        guard rootState.rootID == plan.rootID else {
            throw LocalCheckpointError.planMismatch(
                field: "rootID",
                expected: plan.rootID,
                actual: rootState.rootID
            )
        }
        guard rootState.planID == manifest.planID else {
            throw LocalCheckpointError.planMismatch(
                field: "planID",
                expected: manifest.planID,
                actual: rootState.planID
            )
        }
        guard rootState.identityDigest == manifest.identityDigest else {
            throw LocalCheckpointError.digestMismatch(
                kind: "identityDigest",
                expected: manifest.identityDigest,
                actual: rootState.identityDigest
            )
        }
        guard rootState.revision >= 0 else {
            throw LocalCheckpointError.invalidField(
                field: "rootState.revision",
                reason: "不可為負：\(rootState.revision)。"
            )
        }

        var nodesByID: [String: LocalCheckpointNode] = [:]
        for node in rootState.nodes {
            guard nodesByID[node.nodeID] == nil else {
                throw LocalCheckpointError.duplicateNode(nodeID: node.nodeID)
            }
            nodesByID[node.nodeID] = node
        }

        let plannedIDs = Set(plan.initialChunks.map(\.nodeID))
        for node in rootState.nodes {
            if let parentID = node.parentID {
                guard let parent = nodesByID[parentID] else {
                    throw LocalCheckpointError.unknownNode(reference: parentID, from: node.nodeID)
                }
                guard parent.childrenIDs.contains(node.nodeID) else {
                    throw LocalCheckpointError.splitInvariant(
                        nodeID: parentID,
                        reason: "childrenIDs 未包含 \(node.nodeID)。"
                    )
                }
                guard node.splitDepth == parent.splitDepth + 1 else {
                    throw LocalCheckpointError.splitInvariant(
                        nodeID: node.nodeID,
                        reason: "splitDepth 必須是父節點 +1（父 \(parent.splitDepth)，子 \(node.splitDepth)）。"
                    )
                }
                try validateSpan(node.span, field: "node.\(node.nodeID)", within: parent.span)
            } else {
                guard plannedIDs.contains(node.nodeID) else {
                    throw LocalCheckpointError.unknownNode(
                        reference: node.nodeID,
                        from: "root plan"
                    )
                }
                guard node.splitDepth == 0 else {
                    throw LocalCheckpointError.invalidField(
                        field: "node.\(node.nodeID).splitDepth",
                        reason: "根層 chunk 的 splitDepth 必須為 0。"
                    )
                }
                try validateSpan(node.span, field: "node.\(node.nodeID)", within: plan.span)
            }

            if node.state == .split {
                try validateSplit(node, nodesByID: nodesByID)
            } else {
                guard node.childrenIDs.isEmpty else {
                    throw LocalCheckpointError.splitInvariant(
                        nodeID: node.nodeID,
                        reason: "狀態 \(node.state.rawValue) 不可有子節點。"
                    )
                }
                try validateTerminalEvidence(node)
                if node.state == .verifiedSilence {
                    guard let silence else { throw LocalCheckpointError.emptyUnverified(nodeID: node.nodeID) }
                    try silence.validate(node: node, manifest: manifest, root: plan)
                }
            }
        }

        return outcome(of: rootState, plan: plan)
    }

    private static func validateSplit(
        _ node: LocalCheckpointNode,
        nodesByID: [String: LocalCheckpointNode]
    ) throws {
        guard node.childrenIDs.count == 2 else {
            throw LocalCheckpointError.splitInvariant(
                nodeID: node.nodeID,
                reason: "必須恰好有兩個子節點，實際 \(node.childrenIDs.count) 個。"
            )
        }
        guard Set(node.childrenIDs).count == 2 else {
            throw LocalCheckpointError.splitInvariant(
                nodeID: node.nodeID,
                reason: "子節點 ID 重複。"
            )
        }

        var children: [LocalCheckpointNode] = []
        for childID in node.childrenIDs {
            guard let child = nodesByID[childID] else {
                throw LocalCheckpointError.unknownNode(reference: childID, from: node.nodeID)
            }
            children.append(child)
        }
        children.sort { $0.startSample < $1.startSample }

        guard children[0].startSample == node.startSample,
              children[0].endSample == children[1].startSample,
              children[1].endSample == node.endSample
        else {
            throw LocalCheckpointError.splitInvariant(
                nodeID: node.nodeID,
                reason: "兩個子節點的聯集必須精確等於父範圍 [\(node.startSample), \(node.endSample))，"
                    + "實際 [\(children[0].startSample), \(children[0].endSample)) + "
                    + "[\(children[1].startSample), \(children[1].endSample))。"
            )
        }
        // A split parent's truncated text must never be published.
        guard node.result == nil || node.result?.text.isEmpty == true else {
            throw LocalCheckpointError.splitInvariant(
                nodeID: node.nodeID,
                reason: "split 父節點不可保存可用文字。"
            )
        }
    }

    private static func validateTerminalEvidence(_ node: LocalCheckpointNode) throws {
        switch node.state {
        case .pending, .running:
            guard node.result == nil else {
                throw LocalCheckpointError.incompleteEvidence(
                    nodeID: node.nodeID,
                    reason: "尚未完成的節點不可帶有 leaf 結果。"
                )
            }
        case .completed:
            guard let result = node.result else {
                throw LocalCheckpointError.incompleteEvidence(
                    nodeID: node.nodeID,
                    reason: "缺少 leaf 結果。"
                )
            }
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalCheckpointError.emptyUnverified(nodeID: node.nodeID)
            }
            guard result.textSHA256 == LocalDigest.sha256(result.text) else {
                throw LocalCheckpointError.digestMismatch(
                    kind: "leaf.\(node.nodeID).text",
                    expected: result.textSHA256,
                    actual: LocalDigest.sha256(result.text)
                )
            }
            guard let evidence = result.finishEvidence else {
                // The old behaviour treated a missing token count as zero, which
                // let a truncated leaf masquerade as a finished one.
                throw LocalCheckpointError.incompleteEvidence(
                    nodeID: node.nodeID,
                    reason: "缺少 generationTokens／finish 證據。"
                )
            }
            guard !evidence.reachedTokenLimit else {
                throw LocalCheckpointError.incompleteEvidence(
                    nodeID: node.nodeID,
                    reason: "已達 token 上限，應記錄為 gap 而不是 completed。"
                )
            }
            guard evidence.generationTokens > 0 else {
                throw LocalCheckpointError.incompleteEvidence(
                    nodeID: node.nodeID,
                    reason: "generationTokens 為 0，不足以證明完成。"
                )
            }
        case .verifiedSilence:
            guard let result = node.result,
                  let silence = result.silenceEvidence
            else {
                throw LocalCheckpointError.emptyUnverified(nodeID: node.nodeID)
            }
            guard result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalCheckpointError.incompleteEvidence(
                    nodeID: node.nodeID,
                    reason: "verifiedSilence 不可帶有文字。"
                )
            }
            guard silence.coveredSpan == node.span else {
                throw LocalCheckpointError.incompleteEvidence(
                    nodeID: node.nodeID,
                    reason: "靜音證據範圍 [\(silence.coveredStartSample), \(silence.coveredEndSample)) "
                        + "未完整涵蓋 leaf 範圍 [\(node.startSample), \(node.endSample))。"
                )
            }
        case .gap:
            guard let result = node.result,
                  let reason = result.gapReason,
                  !reason.isEmpty
            else {
                throw LocalCheckpointError.incompleteEvidence(
                    nodeID: node.nodeID,
                    reason: "gap 必須記錄範圍與原因。"
                )
            }
        case .failed:
            break
        case .split:
            break
        }
    }

    // MARK: Outcome and ordering

    /// Effective leaves: everything that is not a `split` parent.
    public static func effectiveLeaves(in state: LocalRootState) -> [LocalCheckpointNode] {
        state.nodes.filter { $0.state != .split }
    }

    public static func outcome(
        of state: LocalRootState,
        plan: LocalRootPlan
    ) -> LocalRootOutcome {
        let leaves = effectiveLeaves(in: state)
        guard leaves.allSatisfy({ $0.state.isTerminal }) else {
            return .incomplete
        }
        guard !leaves.contains(where: { $0.state == .failed }) else {
            return .incomplete
        }
        let spans = leaves
            .sorted { $0.startSample < $1.startSample }
            .map(\.span)
        do {
            try spans.validatedTiling(of: plan.span)
        } catch {
            return .incomplete
        }
        return leaves.contains(where: { $0.state == .gap }) ? .completedWithGaps : .completed
    }

    /// Leaves in absolute time order, ready for the merger. Positions come from
    /// the recorded spans, never from `index * chunkSeconds`.
    public static func orderedCompletedLeaves(in state: LocalRootState) -> [LocalCheckpointNode] {
        effectiveLeaves(in: state)
            .filter { $0.state == .completed || $0.state == .verifiedSilence || $0.state == .gap }
            .sorted { $0.startSample < $1.startSample }
    }

    private static func validateSpan(
        _ span: LocalSampleSpan,
        field: String,
        within work: LocalSampleSpan? = nil
    ) throws {
        if let work {
            _ = try span.validatedWithin(work: work, field: field)
        } else {
            _ = try span.validated(field: field)
        }
    }
}

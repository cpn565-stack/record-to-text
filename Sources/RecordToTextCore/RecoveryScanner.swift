import Foundation

/// Classification for leftover App-managed temp / recovery directories.
public enum RecoveryItemKind: String, Codable, Equatable, Sendable {
    /// A valid item whose partial text can be retrieved and/or whose original
    /// source can be re-enqueued. It does not imply automatic checkpoint resume.
    case recoverable
    /// UUID job directory under App roots, but incomplete or leftover work temp.
    case orphaned
    /// UUID-named directory under App roots with broken / unexpected schema.
    case damaged
}

public enum RecoveryItemLocation: String, Codable, Equatable, Sendable {
    case systemTemp
    case tempRecovery
}

public struct RecoveryScanItem: Equatable, Identifiable, Sendable {
    public var id: String { directoryPath }
    public let jobID: UUID?
    public let location: RecoveryItemLocation
    public let kind: RecoveryItemKind
    public let directoryPath: String
    public let summary: String
    public let detail: String
    public let sourcePath: String?
    public let sourceSlice: TranscriptionSourceSlice?
    public let failureStage: String?
    public let hasNormalizedWAV: Bool
    public let hasRecoveryJSON: Bool
    public let hasSegmentManifest: Bool
    public let recognizedFileNames: [String]
    public let unknownEntryNames: [String]
    public let hasPartialTranscript: Bool

    public init(
        jobID: UUID?,
        location: RecoveryItemLocation,
        kind: RecoveryItemKind,
        directoryPath: String,
        summary: String,
        detail: String,
        sourcePath: String? = nil,
        sourceSlice: TranscriptionSourceSlice? = nil,
        failureStage: String? = nil,
        hasNormalizedWAV: Bool,
        hasRecoveryJSON: Bool,
        hasSegmentManifest: Bool,
        recognizedFileNames: [String],
        unknownEntryNames: [String],
        hasPartialTranscript: Bool = false
    ) {
        self.jobID = jobID
        self.location = location
        self.kind = kind
        self.directoryPath = directoryPath
        self.summary = summary
        self.detail = detail
        self.sourcePath = sourcePath
        self.sourceSlice = sourceSlice
        self.failureStage = failureStage
        self.hasNormalizedWAV = hasNormalizedWAV
        self.hasRecoveryJSON = hasRecoveryJSON
        self.hasSegmentManifest = hasSegmentManifest
        self.recognizedFileNames = recognizedFileNames
        self.unknownEntryNames = unknownEntryNames
        self.hasPartialTranscript = hasPartialTranscript
    }
}

public struct RecoveryScanReport: Equatable, Sendable {
    public let scannedAt: Date
    public let systemTempRoot: String
    public let tempRecoveryRoot: String
    public let items: [RecoveryScanItem]
    public let ignoredNonUUIDDirectoryCount: Int

    public init(
        scannedAt: Date = Date(),
        systemTempRoot: String,
        tempRecoveryRoot: String,
        items: [RecoveryScanItem],
        ignoredNonUUIDDirectoryCount: Int
    ) {
        self.scannedAt = scannedAt
        self.systemTempRoot = systemTempRoot
        self.tempRecoveryRoot = tempRecoveryRoot
        self.items = items
        self.ignoredNonUUIDDirectoryCount = ignoredNonUUIDDirectoryCount
    }

    public var isEmpty: Bool { items.isEmpty }

    public var recoverableCount: Int {
        items.filter { $0.kind == .recoverable }.count
    }

    public var orphanedCount: Int {
        items.filter { $0.kind == .orphaned }.count
    }

    public var damagedCount: Int {
        items.filter { $0.kind == .damaged }.count
    }
}

/// Read-only inventory of App-managed temp and Temp-Recovery directories.
///
/// Never deletes or modifies files. Only inspects:
/// - `{tmpdir}/record-to-text/<UUID>/`
/// - `{Application Support}/record-to-text/Temp-Recovery/<UUID>/`
public enum RecoveryScanner {
    public static let recoveryJSONFileName = "recovery.json"
    public static let normalizedWAVFileName = "normalized.wav"
    public static let segmentManifestFileName = "segment-manifest.json"
    public static let segmentsDirectoryName = "segments"
    public static let partialTranscriptFileName = "partial-transcript.txt"

    /// Files the pipeline may leave in a system-temp job directory.
    public static let knownTempJobFileNames: Set<String> = [
        "normalized.wav",
        "raw.txt",
        "traditional.txt",
        "request.json",
        segmentManifestFileName,
        partialTranscriptFileName
    ]

    public static let knownRecoveryFileNames: Set<String> = [
        recoveryJSONFileName,
        normalizedWAVFileName,
        segmentManifestFileName,
        segmentsDirectoryName,
        partialTranscriptFileName
    ]

    public struct RecoveryMetadata: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let jobID: UUID
        public let sourcePath: String
        public let sourceSlice: TranscriptionSourceSlice?
        public let failureStage: String
        public let createdAt: Date
        public let technicalError: String
        /// Version 2 cloud failures/cancellations may preserve completed text
        /// without a normalized WAV. This is retrieval metadata, not an
        /// automatic-resume contract. All fields remain optional so version 1
        /// metadata continues to decode unchanged.
        public let recoveryKind: String?
        public let backendType: ASRBackendType?
        public let checkpointFile: String?
        public let segmentsDirectory: String?
        public let partialTranscriptFile: String?

        public init(
            schemaVersion: Int,
            jobID: UUID,
            sourcePath: String,
            sourceSlice: TranscriptionSourceSlice? = nil,
            failureStage: String,
            createdAt: Date,
            technicalError: String,
            recoveryKind: String? = nil,
            backendType: ASRBackendType? = nil,
            checkpointFile: String? = nil,
            segmentsDirectory: String? = nil,
            partialTranscriptFile: String? = nil
        ) {
            self.schemaVersion = schemaVersion
            self.jobID = jobID
            self.sourcePath = sourcePath
            self.sourceSlice = sourceSlice
            self.failureStage = failureStage
            self.createdAt = createdAt
            self.technicalError = technicalError
            self.recoveryKind = recoveryKind
            self.backendType = backendType
            self.checkpointFile = checkpointFile
            self.segmentsDirectory = segmentsDirectory
            self.partialTranscriptFile = partialTranscriptFile
        }
    }

    public static func systemTempJobsRoot(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("record-to-text", isDirectory: true)
    }

    public static func scan(
        paths: ApplicationPaths,
        fileManager: FileManager = .default,
        systemTempRoot: URL? = nil
    ) -> RecoveryScanReport {
        let tempRoot = (systemTempRoot ?? systemTempJobsRoot(fileManager: fileManager))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let recoveryRoot = paths.tempRecovery
            .standardizedFileURL
            .resolvingSymlinksInPath()

        var items: [RecoveryScanItem] = []
        var ignored = 0

        let tempScan = scanRoot(
            root: tempRoot,
            location: .systemTemp,
            fileManager: fileManager
        )
        items.append(contentsOf: tempScan.items)
        ignored += tempScan.ignoredNonUUID

        let recoveryScan = scanRoot(
            root: recoveryRoot,
            location: .tempRecovery,
            fileManager: fileManager
        )
        items.append(contentsOf: recoveryScan.items)
        ignored += recoveryScan.ignoredNonUUID

        items.sort { lhs, rhs in
            if lhs.kind != rhs.kind {
                return kindSortRank(lhs.kind) < kindSortRank(rhs.kind)
            }
            return lhs.directoryPath < rhs.directoryPath
        }

        return RecoveryScanReport(
            systemTempRoot: tempRoot.path,
            tempRecoveryRoot: recoveryRoot.path,
            items: items,
            ignoredNonUUIDDirectoryCount: ignored
        )
    }

    public static func parseJobDirectoryName(_ name: String) -> UUID? {
        UUID(uuidString: name)
    }

    public static func isPathInsideManagedRoot(
        _ path: URL,
        roots: [URL]
    ) -> Bool {
        let standardized = path.standardizedFileURL.resolvingSymlinksInPath()
        return roots.contains { root in
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
            let candidate = standardized.path
            return candidate == rootPath
                || candidate.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }
    }

    public static func managedRoots(
        paths: ApplicationPaths,
        fileManager: FileManager = .default,
        systemTempRoot: URL? = nil
    ) -> [URL] {
        let tempRoot = (systemTempRoot ?? systemTempJobsRoot(fileManager: fileManager))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let recoveryRoot = paths.tempRecovery
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return [tempRoot, recoveryRoot]
    }

    /// Validates that `item.directoryPath` is exactly one UUID child of a managed root.
    public static func validatedManagedJobDirectory(
        for item: RecoveryScanItem,
        paths: ApplicationPaths,
        fileManager: FileManager = .default,
        systemTempRoot: URL? = nil
    ) throws -> URL {
        let roots = managedRoots(
            paths: paths,
            fileManager: fileManager,
            systemTempRoot: systemTempRoot
        )
        let target = URL(fileURLWithPath: item.directoryPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard parseJobDirectoryName(target.lastPathComponent) != nil else {
            throw RecoveryCleanupError.notUUIDDirectory(target.path)
        }

        let parent = target.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let parentMatches = roots.contains { root in
            root.standardizedFileURL.resolvingSymlinksInPath().path == parent.path
        }
        guard parentMatches else {
            throw RecoveryCleanupError.pathOutsideManagedRoots(target.path)
        }

        // Exact match: directory must be direct child of root, not a nested path.
        guard isPathInsideManagedRoot(target, roots: roots) else {
            throw RecoveryCleanupError.pathOutsideManagedRoots(target.path)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw RecoveryCleanupError.directoryMissing(target.path)
        }

        return target
    }

    /// Deletes one scanned leftover directory after path validation.
    /// Never touches paths outside App-managed temp / Temp-Recovery roots.
    public static func deleteItem(
        _ item: RecoveryScanItem,
        paths: ApplicationPaths,
        fileManager: FileManager = .default,
        systemTempRoot: URL? = nil
    ) throws {
        let target = try validatedManagedJobDirectory(
            for: item,
            paths: paths,
            fileManager: fileManager,
            systemTempRoot: systemTempRoot
        )
        try fileManager.removeItem(at: target)
    }

    /// Deletes orphaned and damaged items only (never recoverable unless included).
    public static func deleteItems(
        _ items: [RecoveryScanItem],
        paths: ApplicationPaths,
        fileManager: FileManager = .default,
        systemTempRoot: URL? = nil
    ) throws -> (deleted: Int, failures: [(RecoveryScanItem, Error)]) {
        var deleted = 0
        var failures: [(RecoveryScanItem, Error)] = []
        for item in items {
            do {
                try deleteItem(
                    item,
                    paths: paths,
                    fileManager: fileManager,
                    systemTempRoot: systemTempRoot
                )
                deleted += 1
            } catch {
                failures.append((item, error))
            }
        }
        return (deleted, failures)
    }

    // MARK: - Private

    private static func kindSortRank(_ kind: RecoveryItemKind) -> Int {
        switch kind {
        case .recoverable: return 0
        case .orphaned: return 1
        case .damaged: return 2
        }
    }

    private static func scanRoot(
        root: URL,
        location: RecoveryItemLocation,
        fileManager: FileManager
    ) -> (items: [RecoveryScanItem], ignoredNonUUID: Int) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return ([], 0)
        }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return ([], 0)
        }

        var items: [RecoveryScanItem] = []
        var ignored = 0

        for child in children {
            var childIsDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: child.path,
                isDirectory: &childIsDirectory
            ), childIsDirectory.boolValue else {
                continue
            }

            let name = child.lastPathComponent
            guard let jobID = parseJobDirectoryName(name) else {
                ignored += 1
                continue
            }

            items.append(
                classifyDirectory(
                    at: child,
                    expectedJobID: jobID,
                    location: location,
                    fileManager: fileManager
                )
            )
        }

        return (items, ignored)
    }

    private static func classifyDirectory(
        at directory: URL,
        expectedJobID: UUID,
        location: RecoveryItemLocation,
        fileManager: FileManager
    ) -> RecoveryScanItem {
        let listing = listEntries(at: directory, fileManager: fileManager)
        let known: Set<String>
        switch location {
        case .systemTemp:
            known = knownTempJobFileNames.union([segmentsDirectoryName])
        case .tempRecovery:
            known = knownRecoveryFileNames
        }

        let recognized = listing.names.filter { known.contains($0) }.sorted()
        let unknown = listing.names.filter { !known.contains($0) }.sorted()

        let hasWAV = listing.names.contains(normalizedWAVFileName)
        let hasRecoveryJSON = listing.names.contains(recoveryJSONFileName)
        let hasManifest = listing.names.contains(segmentManifestFileName)

        switch location {
        case .tempRecovery:
            return classifyTempRecovery(
                directory: directory,
                expectedJobID: expectedJobID,
                hasWAV: hasWAV,
                hasRecoveryJSON: hasRecoveryJSON,
                hasManifest: hasManifest,
                recognized: recognized,
                unknown: unknown,
                fileManager: fileManager
            )
        case .systemTemp:
            return classifySystemTemp(
                directory: directory,
                expectedJobID: expectedJobID,
                hasWAV: hasWAV,
                hasManifest: hasManifest,
                hasRecoveryJSON: hasRecoveryJSON,
                listing: listing,
                recognized: recognized,
                unknown: unknown,
                fileManager: fileManager
            )
        }
    }

    private static func classifyTempRecovery(
        directory: URL,
        expectedJobID: UUID,
        hasWAV: Bool,
        hasRecoveryJSON: Bool,
        hasManifest: Bool,
        recognized: [String],
        unknown: [String],
        fileManager: FileManager
    ) -> RecoveryScanItem {
        if hasRecoveryJSON {
            let jsonURL = directory.appendingPathComponent(recoveryJSONFileName)
            do {
                let data = try Data(contentsOf: jsonURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let metadata = try decoder.decode(RecoveryMetadata.self, from: data)
                if metadata.schemaVersion < 1 {
                    return makeItem(
                        jobID: expectedJobID,
                        location: .tempRecovery,
                        kind: .damaged,
                        directory: directory,
                        summary: "復原 metadata 版本不支援",
                        detail: "schemaVersion=\(metadata.schemaVersion)",
                        sourcePath: metadata.sourcePath,
                        sourceSlice: metadata.sourceSlice,
                        failureStage: metadata.failureStage,
                        hasWAV: hasWAV,
                        hasRecoveryJSON: true,
                        hasManifest: hasManifest,
                        recognized: recognized,
                        unknown: unknown
                    )
                }
                if metadata.jobID != expectedJobID {
                    return makeItem(
                        jobID: expectedJobID,
                        location: .tempRecovery,
                        kind: .damaged,
                        directory: directory,
                        summary: "recovery.json 的 jobID 與資料夾名稱不符",
                        detail: "資料夾 \(expectedJobID.uuidString)，metadata \(metadata.jobID.uuidString)",
                        sourcePath: metadata.sourcePath,
                        sourceSlice: metadata.sourceSlice,
                        failureStage: metadata.failureStage,
                        hasWAV: hasWAV,
                        hasRecoveryJSON: true,
                        hasManifest: hasManifest,
                        recognized: recognized,
                        unknown: unknown
                    )
                }
                if metadata.recoveryKind == "cloudCheckpoint" {
                    guard metadata.schemaVersion >= 2, hasManifest else {
                        return makeItem(
                            jobID: expectedJobID,
                            location: .tempRecovery,
                            kind: .damaged,
                            directory: directory,
                            summary: "雲端部分稿資料不完整",
                            detail: hasManifest
                                ? "recovery.json 版本或類型不受支援。"
                                : "缺少 \(segmentManifestFileName)。",
                            sourcePath: metadata.sourcePath,
                            sourceSlice: metadata.sourceSlice,
                            failureStage: metadata.failureStage,
                            hasWAV: hasWAV,
                            hasRecoveryJSON: true,
                            hasManifest: hasManifest,
                            recognized: recognized,
                            unknown: unknown
                        )
                    }
                    let backend = metadata.backendType?.displayName ?? "雲端"
                    let hasPartial = hasUsablePartialTranscript(
                        in: directory,
                        fileManager: fileManager
                    )
                    return makeItem(
                        jobID: expectedJobID,
                        location: .tempRecovery,
                        kind: .recoverable,
                        directory: directory,
                        summary: hasPartial
                            ? "雲端工作留下可取回的部分稿"
                            : "雲端工作已停止，沒有可取回文字",
                        detail: hasPartial
                            ? "\(backend)；可人工取回已完成片段，不會自動從剩餘片段續跑。重新加入原始錄音會從頭轉錄。\n\(metadata.technicalError)"
                            : "\(backend)；只有工作記錄與分段 manifest，沒有已完成的文字可取回。如原始錄音仍存在，可重新加入並從頭轉錄。\n\(metadata.technicalError)",
                        sourcePath: metadata.sourcePath,
                        sourceSlice: metadata.sourceSlice,
                        failureStage: metadata.failureStage,
                        hasWAV: hasWAV,
                        hasRecoveryJSON: true,
                        hasManifest: true,
                        recognized: recognized,
                        unknown: unknown,
                        hasPartialTranscript: hasPartial
                    )
                }
                if hasWAV {
                    return makeItem(
                        jobID: expectedJobID,
                        location: .tempRecovery,
                        kind: .recoverable,
                        directory: directory,
                        summary: "可復原的失敗工作資料",
                        detail: metadata.technicalError,
                        sourcePath: metadata.sourcePath,
                        sourceSlice: metadata.sourceSlice,
                        failureStage: metadata.failureStage,
                        hasWAV: true,
                        hasRecoveryJSON: true,
                        hasManifest: hasManifest,
                        recognized: recognized,
                        unknown: unknown
                    )
                }
                return makeItem(
                    jobID: expectedJobID,
                    location: .tempRecovery,
                    kind: .damaged,
                    directory: directory,
                    summary: "有 recovery.json 但缺少 normalized.wav",
                    detail: metadata.technicalError,
                    sourcePath: metadata.sourcePath,
                    sourceSlice: metadata.sourceSlice,
                    failureStage: metadata.failureStage,
                    hasWAV: false,
                    hasRecoveryJSON: true,
                    hasManifest: hasManifest,
                    recognized: recognized,
                    unknown: unknown
                )
            } catch {
                return makeItem(
                    jobID: expectedJobID,
                    location: .tempRecovery,
                    kind: .damaged,
                    directory: directory,
                    summary: "recovery.json 無法解析",
                    detail: error.localizedDescription,
                    hasWAV: hasWAV,
                    hasRecoveryJSON: true,
                    hasManifest: hasManifest,
                    recognized: recognized,
                    unknown: unknown
                )
            }
        }

        if hasWAV || hasManifest || !recognized.isEmpty {
            return makeItem(
                jobID: expectedJobID,
                location: .tempRecovery,
                kind: .orphaned,
                directory: directory,
                summary: "Temp-Recovery 殘留資料（無完整 recovery.json）",
                detail: "辨識到的檔案：\(recognized.joined(separator: ", ").ifEmpty("（無）"))",
                hasWAV: hasWAV,
                hasRecoveryJSON: false,
                hasManifest: hasManifest,
                recognized: recognized,
                unknown: unknown
            )
        }

        if !unknown.isEmpty {
            return makeItem(
                jobID: expectedJobID,
                location: .tempRecovery,
                kind: .damaged,
                directory: directory,
                summary: "Temp-Recovery 目錄內容不符合 schema",
                detail: "未知項目：\(unknown.joined(separator: ", "))",
                hasWAV: false,
                hasRecoveryJSON: false,
                hasManifest: false,
                recognized: recognized,
                unknown: unknown
            )
        }

        return makeItem(
            jobID: expectedJobID,
            location: .tempRecovery,
            kind: .orphaned,
            directory: directory,
            summary: "空的 Temp-Recovery 工作目錄",
            detail: "沒有 recovery.json 或 normalized.wav",
            hasWAV: false,
            hasRecoveryJSON: false,
            hasManifest: false,
            recognized: recognized,
            unknown: unknown
        )
    }

    private static func classifySystemTemp(
        directory: URL,
        expectedJobID: UUID,
        hasWAV: Bool,
        hasManifest: Bool,
        hasRecoveryJSON: Bool,
        listing: (names: [String], fileCount: Int),
        recognized: [String],
        unknown: [String],
        fileManager: FileManager
    ) -> RecoveryScanItem {
        // recovery.json is not expected in system temp; treat as schema noise.
        if hasRecoveryJSON {
            return makeItem(
                jobID: expectedJobID,
                location: .systemTemp,
                kind: .damaged,
                directory: directory,
                summary: "系統暫存出現非預期的 recovery.json",
                detail: "正式復原資料應只在 Temp-Recovery。",
                hasWAV: hasWAV,
                hasRecoveryJSON: true,
                hasManifest: hasManifest,
                recognized: recognized,
                unknown: unknown
            )
        }

        if !unknown.isEmpty && recognized.isEmpty {
            return makeItem(
                jobID: expectedJobID,
                location: .systemTemp,
                kind: .damaged,
                directory: directory,
                summary: "系統暫存目錄內容不符合 schema",
                detail: "未知項目：\(unknown.joined(separator: ", "))",
                hasWAV: false,
                hasRecoveryJSON: false,
                hasManifest: false,
                recognized: recognized,
                unknown: unknown
            )
        }

        let hasPartial = hasUsablePartialTranscript(
            in: directory,
            fileManager: fileManager
        )
        if hasManifest, hasPartial
        {
            return makeItem(
                jobID: expectedJobID,
                location: .systemTemp,
                kind: .recoverable,
                directory: directory,
                summary: "App 中斷後留下可取回的雲端部分稿",
                detail: "已保留 \(partialTranscriptFileName) 與分段 manifest；可人工取回已完成片段，不會自動斷點續跑。由於系統暫存沒有來源路徑，請自行重新選擇原始錄音從頭轉錄。",
                hasWAV: hasWAV,
                hasRecoveryJSON: false,
                hasManifest: true,
                recognized: recognized,
                unknown: unknown,
                hasPartialTranscript: true
            )
        }

        if hasWAV || hasManifest || listing.names.contains(segmentsDirectoryName)
            || !recognized.isEmpty
        {
            var detailParts: [String] = []
            if hasWAV { detailParts.append("normalized.wav") }
            if hasManifest { detailParts.append("segment-manifest.json") }
            if listing.names.contains(segmentsDirectoryName) {
                detailParts.append("segments/")
            }
            return makeItem(
                jobID: expectedJobID,
                location: .systemTemp,
                kind: .orphaned,
                directory: directory,
                summary: "未完成工作留下的系統暫存",
                detail: "殘留：\(detailParts.joined(separator: ", ").ifEmpty(recognized.joined(separator: ", ")))",
                hasWAV: hasWAV,
                hasRecoveryJSON: false,
                hasManifest: hasManifest,
                recognized: recognized,
                unknown: unknown
            )
        }

        return makeItem(
            jobID: expectedJobID,
            location: .systemTemp,
            kind: .orphaned,
            directory: directory,
            summary: "空的系統暫存工作目錄",
            detail: "沒有可辨識的管線產物",
            hasWAV: false,
            hasRecoveryJSON: false,
            hasManifest: false,
            recognized: recognized,
            unknown: unknown
        )
    }

    private static func listEntries(
        at directory: URL,
        fileManager: FileManager
    ) -> (names: [String], fileCount: Int) {
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return ([], 0)
        }
        let names = urls.map(\.lastPathComponent).sorted()
        return (names, names.count)
    }

    /// A filename alone is not enough to promise a retrievable transcript.
    /// Reject directories, symlinks, invalid UTF-8, and empty/whitespace files.
    private static func hasUsablePartialTranscript(
        in directory: URL,
        fileManager: FileManager
    ) -> Bool {
        let partialURL = directory.appendingPathComponent(
            partialTranscriptFileName
        )
        guard
            let attributes = try? fileManager.attributesOfItem(
                atPath: partialURL.path
            ),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let data = try? Data(contentsOf: partialURL),
            let text = String(data: data, encoding: .utf8)
        else {
            return false
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func makeItem(
        jobID: UUID?,
        location: RecoveryItemLocation,
        kind: RecoveryItemKind,
        directory: URL,
        summary: String,
        detail: String,
        sourcePath: String? = nil,
        sourceSlice: TranscriptionSourceSlice? = nil,
        failureStage: String? = nil,
        hasWAV: Bool,
        hasRecoveryJSON: Bool,
        hasManifest: Bool,
        recognized: [String],
        unknown: [String],
        hasPartialTranscript: Bool = false
    ) -> RecoveryScanItem {
        RecoveryScanItem(
            jobID: jobID,
            location: location,
            kind: kind,
            directoryPath: directory.path,
            summary: summary,
            detail: detail,
            sourcePath: sourcePath,
            sourceSlice: sourceSlice,
            failureStage: failureStage,
            hasNormalizedWAV: hasWAV,
            hasRecoveryJSON: hasRecoveryJSON,
            hasSegmentManifest: hasManifest,
            recognizedFileNames: recognized,
            unknownEntryNames: unknown,
            hasPartialTranscript: hasPartialTranscript
        )
    }
}

public enum RecoveryCleanupError: LocalizedError, Equatable {
    case pathOutsideManagedRoots(String)
    case notUUIDDirectory(String)
    case directoryMissing(String)

    public var errorDescription: String? {
        switch self {
        case let .pathOutsideManagedRoots(path):
            return "拒絕操作：路徑不在 record-to-text 管理的暫存／復原範圍內（\(path)）。"
        case let .notUUIDDirectory(path):
            return "拒絕操作：不是 UUID 工作目錄（\(path)）。"
        case let .directoryMissing(path):
            return "目錄已不存在（\(path)）。"
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

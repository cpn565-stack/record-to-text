import Foundation

/// Content manifest for the locally downloaded ASR model.
///
/// A folder path or a pinned revision alone cannot prove the weights are the
/// ones that produced an existing checkpoint, so the digest covers every file's
/// bytes. Without it, cross-run reuse is refused rather than assumed.
public struct LocalModelFileEntry: Codable, Equatable, Sendable, CanonicalJSONRepresentable {
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String
    /// HF cache snapshots are directories of symlinks into `blobs/`.
    public let isSymbolicLink: Bool

    public init(relativePath: String, byteCount: Int64, sha256: String, isSymbolicLink: Bool) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.isSymbolicLink = isSymbolicLink
    }

    public var canonicalValue: CanonicalJSONValue {
        .object([
            "byteCount": .integer(byteCount),
            "isSymbolicLink": .bool(isSymbolicLink),
            "relativePath": .string(relativePath),
            "sha256": .string(sha256)
        ])
    }
}

public struct LocalModelManifest: Codable, Equatable, Sendable, CanonicalJSONRepresentable {
    public static let schemaVersionValue = 1

    public let schemaVersion: Int
    public let modelID: String
    public let revision: String?
    public let snapshotPath: String
    public let totalByteCount: Int64
    public let files: [LocalModelFileEntry]

    public init(
        schemaVersion: Int = LocalModelManifest.schemaVersionValue,
        modelID: String,
        revision: String?,
        snapshotPath: String,
        totalByteCount: Int64,
        files: [LocalModelFileEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.revision = revision
        self.snapshotPath = snapshotPath
        self.totalByteCount = totalByteCount
        self.files = files
    }

    public var fileCount: Int { files.count }

    public var digest: String { LocalDigest.sha256(self) }

    public var canonicalValue: CanonicalJSONValue {
        .object([
            "files": .representables(files),
            "modelID": .string(modelID),
            "revision": .optionalString(revision),
            "schemaVersion": .integer(Int64(schemaVersion)),
            "snapshotPath": .string(snapshotPath),
            "totalByteCount": .integer(totalByteCount)
        ])
    }
}

public enum LocalModelManifestError: LocalizedError, Equatable {
    case snapshotMissing(modelID: String, path: String)
    case revisionRequired(modelID: String)
    case emptySnapshot(path: String)

    public var errorDescription: String? {
        switch self {
        case let .snapshotMissing(modelID, path):
            return "找不到模型 \(modelID) 的本機 snapshot：\(path)。請先完成模型下載。"
        case let .revisionRequired(modelID):
            return "模型 \(modelID) 沒有 pinned revision，無法建立可驗證的內容 manifest。"
        case let .emptySnapshot(path):
            return "模型 snapshot 內沒有可讀取的檔案：\(path)。"
        }
    }
}

public enum LocalModelManifestStore {
    /// Hugging Face cache layout: `<cache>/models--<org>--<name>/snapshots/<revision>`.
    public static func snapshotDirectory(
        cacheDirectory: URL,
        modelID: String,
        revision: String
    ) -> URL {
        cacheDirectory
            .appendingPathComponent("models--" + modelID.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots")
            .appendingPathComponent(revision)
    }

    /// Hashes every file in the snapshot. Runs off the main actor and honours
    /// cancellation between files and between 1 MiB batches.
    public static func compute(
        modelID: String,
        revision: String?,
        cacheDirectory: URL,
        fileManager: FileManager = .default
    ) async throws -> LocalModelManifest {
        guard let revision, !revision.isEmpty else {
            throw LocalModelManifestError.revisionRequired(modelID: modelID)
        }
        let snapshot = snapshotDirectory(
            cacheDirectory: cacheDirectory,
            modelID: modelID,
            revision: revision
        )

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: snapshot.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw LocalModelManifestError.snapshotMissing(
                modelID: modelID,
                path: snapshot.path
            )
        }

        var files: [LocalModelFileEntry] = []
        var total: Int64 = 0
        let entries = try fileManager.contentsOfDirectory(
            at: snapshot,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).sorted { lhs, rhs in
            lhs.lastPathComponent.utf8.lexicographicallyPrecedes(
                rhs.lastPathComponent.utf8
            )
        }

        for entry in entries {
            try Task.checkCancellation()
            let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            // HF snapshots are flat; anything nested is not part of the weights.
            if values.isDirectory == true { continue }

            let attributes = try fileManager.attributesOfItem(atPath: entry.path)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeRegular else { continue }

            let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            // The digest follows the link to the blob, describing the bytes the
            // runtime actually loads rather than the link itself.
            let sha256 = try await LocalContentHasher.sha256(of: entry, fileManager: fileManager)
            files.append(
                LocalModelFileEntry(
                    relativePath: entry.lastPathComponent,
                    byteCount: byteCount,
                    sha256: sha256,
                    isSymbolicLink: values.isSymbolicLink == true
                )
            )
            total += byteCount
        }

        guard !files.isEmpty else {
            throw LocalModelManifestError.emptySnapshot(path: snapshot.path)
        }

        return LocalModelManifest(
            modelID: modelID,
            revision: revision,
            snapshotPath: snapshot.path,
            totalByteCount: total,
            files: files
        )
    }
}

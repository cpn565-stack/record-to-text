import Foundation

/// Locates Hugging Face hub snapshots under the App-managed model cache.
public enum ModelCache {
    public static func hubRoot(modelsDirectory: URL) -> URL {
        modelsDirectory.appendingPathComponent("hub", isDirectory: true)
    }

    public static func defaultHuggingFaceHub(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
    }

    public static func repositoryFolderName(modelID: String) -> String {
        "models--" + modelID.replacingOccurrences(of: "/", with: "--")
    }

    public static func repositoryDirectory(
        modelID: String,
        hubRoot: URL
    ) -> URL {
        hubRoot.appendingPathComponent(
            repositoryFolderName(modelID: modelID),
            isDirectory: true
        )
    }

    public static func snapshotDirectory(
        modelID: String,
        revision: String?,
        hubRoot: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let snapshots = repositoryDirectory(modelID: modelID, hubRoot: hubRoot)
            .appendingPathComponent("snapshots", isDirectory: true)
        guard fileManager.fileExists(atPath: snapshots.path) else {
            return nil
        }

        if let revision, !revision.isEmpty {
            let pinned = snapshots.appendingPathComponent(revision, isDirectory: true)
            if isUsableSnapshot(pinned, fileManager: fileManager) {
                return pinned
            }
            return nil
        }

        let children = (try? fileManager.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.first { isUsableSnapshot($0, fileManager: fileManager) }
    }

    public static func isDownloaded(
        modelID: String,
        revision: String?,
        modelsDirectory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        snapshotDirectory(
            modelID: modelID,
            revision: revision,
            hubRoot: hubRoot(modelsDirectory: modelsDirectory),
            fileManager: fileManager
        ) != nil
    }

    public static func isDownloadedInDefaultCache(
        modelID: String,
        revision: String?,
        fileManager: FileManager = .default
    ) -> Bool {
        snapshotDirectory(
            modelID: modelID,
            revision: revision,
            hubRoot: defaultHuggingFaceHub(fileManager: fileManager),
            fileManager: fileManager
        ) != nil
    }

    public static func isUsableSnapshot(
        _ directory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return false
        }

        let config = directory.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: config.path) else {
            return false
        }

        let weightCandidates = [
            "model.safetensors",
            "model.safetensors.index.json",
            "pytorch_model.bin",
            "pytorch_model.bin.index.json"
        ]
        return weightCandidates.contains {
            fileManager.fileExists(
                atPath: directory.appendingPathComponent($0).path
            )
        }
    }
}

import Foundation

/// Discovery and filesystem rules for resumable local-Qwen chunk checkpoints.
///
/// The Python helper remains responsible for checking the full fingerprint
/// against the current audio/model/prompt before reusing any text. Swift only
/// performs a conservative structural check to decide whether the resume UI
/// should be offered.
public enum LocalChunkCheckpoint {
    public static let directoryName = "chunk-checkpoints"
    public static let fileSuffix = ".chunks.json"

    public static func directory(
        in recoveryDirectory: URL
    ) -> URL {
        recoveryDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func createSecureDirectory(
        in recoveryDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let checkpointDirectory = directory(in: recoveryDirectory)
        try fileManager.createDirectory(
            at: checkpointDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // createDirectory may reuse an existing directory, so always enforce
        // the permissions after creation too.
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: checkpointDirectory.path
        )
        return checkpointDirectory
    }

    public static func containsUsableCheckpoint(
        in recoveryDirectory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let checkpointDirectory = directory(in: recoveryDirectory)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: checkpointDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return entries.contains { url in
            url.lastPathComponent.hasSuffix(fileSuffix)
                && isStructurallyUsable(url, fileManager: fileManager)
        }
    }

    private struct Payload: Decodable {
        struct CompletedChunk: Decodable {
            let index: Int
            let text: String
            let containsSkippedAudio: Bool
        }

        let schemaVersion: Int
        let fingerprint: String
        let totalChunks: Int
        let completedChunks: [CompletedChunk]
    }

    private static func isStructurallyUsable(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == 1,
              payload.totalChunks > 0,
              !payload.completedChunks.isEmpty,
              payload.completedChunks.count <= payload.totalChunks,
              payload.fingerprint.count == 64,
              payload.fingerprint.allSatisfy({ $0.isHexDigit })
        else {
            return false
        }

        return payload.completedChunks.enumerated().allSatisfy { offset, chunk in
            chunk.index == offset && !chunk.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        }
    }
}

import Darwin
import Foundation

public enum AtomicFileWriterError: LocalizedError {
    case posix(operation: String, code: Int32)
    case destinationExists(String)

    public var errorDescription: String? {
        switch self {
        case let .posix(operation, code):
            return "\(operation) 失敗：\(String(cString: strerror(code)))"
        case let .destinationExists(path):
            return "目的檔案已存在，為避免覆寫已停止：\(path)"
        }
    }
}

public enum AtomicFileWriter {
    public static func write(_ data: Data, to destination: URL) throws {
        try write(data, to: destination, replaceExisting: true)
    }

    public static func writeNew(_ data: Data, to destination: URL) throws {
        try write(data, to: destination, replaceExisting: false)
    }

    private static func write(
        _ data: Data,
        to destination: URL,
        replaceExisting: Bool
    ) throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )

        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw AtomicFileWriterError.posix(operation: "建立暫存檔", code: EEXIST)
        }

        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary {
                try? fileManager.removeItem(at: temporary)
            }
        }

        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        let renameResult: Int32 = temporary.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                if replaceExisting {
                    return Darwin.rename(sourcePath, destinationPath)
                }
                return Darwin.renamex_np(
                    sourcePath,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renameResult == 0 else {
            let code = errno
            if !replaceExisting, code == EEXIST {
                throw AtomicFileWriterError.destinationExists(destination.path)
            }
            throw AtomicFileWriterError.posix(operation: "完成原子寫入", code: code)
        }

        shouldRemoveTemporary = false
    }

    public static func writeText(_ text: String, to destination: URL) throws {
        try writeText(text, to: destination, replaceExisting: true)
    }

    public static func writeTextNew(_ text: String, to destination: URL) throws {
        try writeText(text, to: destination, replaceExisting: false)
    }

    private static func writeText(
        _ text: String,
        to destination: URL,
        replaceExisting: Bool
    ) throws {
        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        if normalized.unicodeScalars.first?.value == 0xFEFF {
            normalized.removeFirst()
        }

        guard let data = normalized.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try write(data, to: destination, replaceExisting: replaceExisting)
    }
}

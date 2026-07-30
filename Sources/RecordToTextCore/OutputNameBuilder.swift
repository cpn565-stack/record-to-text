import Foundation

public enum OutputNameBuilder {
    public static func sanitizedStem(for sourceURL: URL) -> String {
        let rawStem = sourceURL.deletingPathExtension().lastPathComponent
        let invalid = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "/:"))

        let scalars = rawStem.unicodeScalars.filter { !invalid.contains($0) }
        let value = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "轉錄結果" : value
    }

    public static func availableOutputURL(
        sourceURL: URL,
        directory: URL,
        suffix: String = "_繁體",
        fileExtension: String = "txt",
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL {
        let stem = sanitizedStem(for: sourceURL)
        var index = 1

        while true {
            let increment = index == 1 ? "" : "_\(index)"
            let name = "\(stem)\(suffix)\(increment).\(fileExtension)"
            let candidate = directory.appendingPathComponent(name, isDirectory: false)
            if !fileExists(candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    public static func rawTranscriptURL(
        sourceURL: URL,
        directory: URL,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL {
        availableOutputURL(
            sourceURL: sourceURL,
            directory: directory,
            suffix: "_Qwen原始",
            fileExists: fileExists
        )
    }
}

import Foundation

public enum OutputNameBuilder {
    public static let defaultFinalSuffix = "_繁體"
    public static let defaultRawSuffix = "_Qwen原始"

    public static func sanitizedStem(for sourceURL: URL) -> String {
        let rawStem = sourceURL.deletingPathExtension().lastPathComponent
        let invalid = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "/:"))

        let scalars = rawStem.unicodeScalars.filter { !invalid.contains($0) }
        let value = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "轉錄結果" : value
    }

    /// Removes path separators and control characters from a user-supplied suffix.
    public static func sanitizedSuffix(
        _ raw: String?,
        fallback: String = defaultFinalSuffix
    ) -> String {
        let invalid = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "/:\\"))
        let trimmed = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars.filter { !invalid.contains($0) }
        let value = String(String.UnicodeScalarView(scalars))
        return value.isEmpty ? fallback : value
    }

    public static func previewFileName(
        sampleStem: String = "原檔名",
        suffix: String,
        fileExtension: String = "txt"
    ) -> String {
        let safeSuffix = sanitizedSuffix(suffix, fallback: defaultFinalSuffix)
        return "\(sampleStem)\(safeSuffix).\(fileExtension)"
    }

    public static func availableOutputURL(
        sourceURL: URL,
        directory: URL,
        suffix: String = defaultFinalSuffix,
        fileExtension: String = "txt",
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL {
        let stem = sanitizedStem(for: sourceURL)
        let safeSuffix = sanitizedSuffix(suffix, fallback: defaultFinalSuffix)
        var index = 1

        while true {
            let increment = index == 1 ? "" : "_\(index)"
            let name = "\(stem)\(safeSuffix)\(increment).\(fileExtension)"
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
        suffix: String = defaultRawSuffix,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL {
        availableOutputURL(
            sourceURL: sourceURL,
            directory: directory,
            suffix: sanitizedSuffix(suffix, fallback: defaultRawSuffix),
            fileExists: fileExists
        )
    }
}

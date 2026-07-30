import Foundation

public enum TextFileValidationError: LocalizedError, Equatable {
    case missing(String)
    case empty(String)
    case invalidUTF8(String)

    public var errorDescription: String? {
        switch self {
        case let .missing(path):
            return "找不到預期文字輸出：\(path)"
        case let .empty(path):
            return "文字輸出是空白的：\(path)"
        case let .invalidUTF8(path):
            return "文字輸出不是有效的 UTF-8：\(path)"
        }
    }
}

public enum TextFileValidator {
    @discardableResult
    public static func readNonEmptyUTF8(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else {
            throw TextFileValidationError.missing(url.path)
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0 else {
            throw TextFileValidationError.empty(url.path)
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let text = String(data: data, encoding: .utf8) else {
            throw TextFileValidationError.invalidUTF8(url.path)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TextFileValidationError.empty(url.path)
        }
        return text
    }
}

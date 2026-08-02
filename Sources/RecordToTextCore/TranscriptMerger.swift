import Foundation

public struct TranscriptMergeResult: Equatable, Sendable {
    public let outputURL: URL
    public let inputURLs: [URL]

    public init(outputURL: URL, inputURLs: [URL]) {
        self.outputURL = outputURL
        self.inputURLs = inputURLs
    }
}

public enum TranscriptMergeError: LocalizedError, Equatable {
    case insufficientFiles
    case duplicateInput(String)
    case unsupportedExtension(String)
    case emptyMergedTranscript

    public var errorDescription: String? {
        switch self {
        case .insufficientFiles:
            return "至少需要選取兩份 TXT 才能合併。"
        case let .duplicateInput(path):
            return "同一份 TXT 被選取多次：\(path)"
        case let .unsupportedExtension(fileExtension):
            return "只能合併 .txt 文字檔，無法處理 .\(fileExtension) 。"
        case .emptyMergedTranscript:
            return "合併後沒有可用的文字內容。"
        }
    }
}

public enum TranscriptMerger {
    public static func merge(
        _ urls: [URL],
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> TranscriptMergeResult {
        guard urls.count >= 2 else {
            throw TranscriptMergeError.insufficientFiles
        }

        let normalizedURLs = urls.map(\.standardizedFileURL)
        var seen = Set<String>()
        for url in normalizedURLs {
            guard seen.insert(url.path).inserted else {
                throw TranscriptMergeError.duplicateInput(url.path)
            }
            guard url.pathExtension.lowercased() == "txt" else {
                throw TranscriptMergeError.unsupportedExtension(url.pathExtension)
            }
        }

        let orderedURLs = orderedInputURLs(normalizedURLs)
        let parts = try orderedURLs.map {
            try OutputContractValidator.readTranscript(at: $0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let mergedText = parts
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !mergedText.isEmpty else {
            throw TranscriptMergeError.emptyMergedTranscript
        }

        let outputDirectory = directory
            ?? orderedURLs[0].deletingLastPathComponent()
        try fileManager.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let firstStem = orderedURLs[0]
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(
                of: #"_第\d+-\d+段$"#,
                with: "",
                options: .regularExpression
            )
        let baseURL = outputDirectory.appendingPathComponent(
            "\(firstStem).txt",
            isDirectory: false
        )

        while true {
            let candidate = OutputNameBuilder.availableOutputURL(
                sourceURL: baseURL,
                directory: outputDirectory,
                suffix: "_合併",
                fileExists: fileManager.fileExists(atPath:)
            )
            do {
                try AtomicFileWriter.writeTextNew(mergedText, to: candidate)
                return TranscriptMergeResult(
                    outputURL: candidate,
                    inputURLs: orderedURLs
                )
            } catch AtomicFileWriterError.destinationExists {
                continue
            }
        }
    }

    public static func orderedInputURLs(_ urls: [URL]) -> [URL] {
        let metadata = urls.map { (url: $0, part: partMetadata(for: $0)) }
        let parsed = metadata.compactMap(\.part)
        let partCounts = Set(parsed.map(\.count))
        let partIndices = Set(parsed.map(\.index))
        let hasCompletePartMetadata = parsed.count == urls.count
            && partCounts.count == 1
            && partIndices.count == urls.count

        if hasCompletePartMetadata {
            return metadata
                .sorted { lhs, rhs in
                    guard let left = lhs.part, let right = rhs.part else {
                        return lhs.url.lastPathComponent.localizedStandardCompare(
                            rhs.url.lastPathComponent
                        ) == .orderedAscending
                    }
                    if left.index != right.index {
                        return left.index < right.index
                    }
                    return lhs.url.lastPathComponent.localizedStandardCompare(
                        rhs.url.lastPathComponent
                    ) == .orderedAscending
                }
                .map(\.url)
        }

        return urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending
        }
    }

    private static func partMetadata(
        for url: URL
    ) -> (index: Int, count: Int)? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard
            let marker = stem.range(of: "_第", options: .backwards),
            stem.hasSuffix("段")
        else {
            return nil
        }

        let value = stem[marker.upperBound...].dropLast()
        let numbers = value.split(separator: "-")
        guard
            numbers.count == 2,
            let index = Int(numbers[0]),
            let count = Int(numbers[1]),
            index > 0,
            count > 0
        else {
            return nil
        }
        return (index: index, count: count)
    }
}

import Foundation

public struct GeminiStreamingLimits: Equatable, Sendable {
    public var maxSingleEventBytes: Int
    public var maxTotalResponseBytes: Int
    public var maxPublishableTextBytes: Int

    public init(
        maxSingleEventBytes: Int = 4 * 1024 * 1024,
        maxTotalResponseBytes: Int = 32 * 1024 * 1024,
        maxPublishableTextBytes: Int = 4 * 1024 * 1024
    ) {
        self.maxSingleEventBytes = max(1, maxSingleEventBytes)
        self.maxTotalResponseBytes = max(1, maxTotalResponseBytes)
        self.maxPublishableTextBytes = max(1, maxPublishableTextBytes)
    }

    public static let `default` = Self()
}

public enum GeminiSSEError: LocalizedError, Equatable, Sendable {
    case invalidUTF8
    case invalidEventJSON
    case incompleteEventAtEOF
    case contradictoryFinishReason(first: String, second: String)
    case textAfterFinishReason(String)
    case singleEventTooLarge(limitBytes: Int)
    case totalResponseTooLarge(limitBytes: Int)
    case publishableTextTooLarge(limitBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "Vertex AI 串流包含無效的 UTF-8 位元組。"
        case .invalidEventJSON:
            return "Vertex AI 串流事件無法解讀為有效 JSON。"
        case .incompleteEventAtEOF:
            return "Vertex AI 串流在未結束的 SSE 事件處中斷。"
        case let .contradictoryFinishReason(first, second):
            return "Vertex AI 串流回報互相矛盾的終止原因（\(first) 與 \(second)）。"
        case let .textAfterFinishReason(reason):
            return "Vertex AI 串流在回報終止（\(reason)）後仍輸出非空文字。"
        case let .singleEventTooLarge(limitBytes):
            return "Vertex AI 單一串流事件超過保護上限（\(limitBytes) bytes）。"
        case let .totalResponseTooLarge(limitBytes):
            return "Vertex AI 串流回應總量超過保護上限（\(limitBytes) bytes）。"
        case let .publishableTextTooLarge(limitBytes):
            return "Vertex AI 串流累積文字超過保護上限（\(limitBytes) bytes）。"
        }
    }
}

/// Byte-preserving WHATWG SSE framing parser with bounded memory limits.
public final class GeminiSSEParser {
    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    public let limits: GeminiStreamingLimits
    private let onEvent: (String) throws -> Void

    public private(set) var totalReceivedBytes: Int = 0
    public private(set) var dispatchedEventCount: Int = 0

    private var bomChecked = false
    private var bomBuffer: [UInt8] = []
    private var skipNextLF = false
    private var lineBuffer = Data()
    private var currentEventBytes: Int = 0
    private var currentEventDataLines: [String] = []
    private var currentEventHasField = false

    public init(
        limits: GeminiStreamingLimits = .default,
        onEvent: @escaping (String) throws -> Void
    ) {
        self.limits = limits
        self.onEvent = onEvent
    }

    public func append(_ chunk: Data) throws {
        guard !chunk.isEmpty else { return }
        if totalReceivedBytes + chunk.count > limits.maxTotalResponseBytes {
            throw GeminiSSEError.totalResponseTooLarge(limitBytes: limits.maxTotalResponseBytes)
        }
        totalReceivedBytes += chunk.count

        var index = chunk.startIndex
        if !bomChecked {
            while index < chunk.endIndex && !bomChecked {
                let byte = chunk[index]
                let expected = Self.utf8BOM[bomBuffer.count]
                if byte == expected {
                    bomBuffer.append(byte)
                    index = chunk.index(after: index)
                    if bomBuffer.count == Self.utf8BOM.count {
                        bomChecked = true
                        bomBuffer.removeAll()
                    }
                } else {
                    bomChecked = true
                    if !bomBuffer.isEmpty {
                        let prefix = Data(bomBuffer)
                        bomBuffer.removeAll()
                        try consumePostBOMBytes(prefix[...])
                    }
                }
            }
        }

        if index < chunk.endIndex {
            try consumePostBOMBytes(chunk[index...])
        }
    }

    public func finish() throws {
        if !bomChecked {
            bomChecked = true
            if !bomBuffer.isEmpty {
                let prefix = Data(bomBuffer)
                bomBuffer.removeAll()
                try consumePostBOMBytes(prefix[...])
            }
        }
        skipNextLF = false

        if !lineBuffer.isEmpty {
            guard let tail = String(data: lineBuffer, encoding: .utf8) else {
                throw GeminiSSEError.invalidUTF8
            }
            let isOnlyHorizontalWhitespace = tail.allSatisfy { $0 == " " || $0 == "\t" }
            if isOnlyHorizontalWhitespace && currentEventDataLines.isEmpty && !currentEventHasField {
                lineBuffer.removeAll()
                currentEventBytes = 0
                return
            }
            throw GeminiSSEError.incompleteEventAtEOF
        }

        if !currentEventDataLines.isEmpty || currentEventHasField {
            throw GeminiSSEError.incompleteEventAtEOF
        }
    }

    private func consumePostBOMBytes(_ slice: Data.SubSequence) throws {
        var cursor = slice.startIndex
        let end = slice.endIndex

        if skipNextLF, cursor < end {
            skipNextLF = false
            if slice[cursor] == 0x0A {
                cursor = slice.index(after: cursor)
            }
        }

        var segmentStart = cursor
        while cursor < end {
            let byte = slice[cursor]
            if byte == 0x0D || byte == 0x0A {
                if segmentStart < cursor {
                    try appendToCurrentLine(slice[segmentStart..<cursor])
                }
                try processCompletedLine()
                if byte == 0x0D {
                    let next = slice.index(after: cursor)
                    if next < end {
                        if slice[next] == 0x0A {
                            cursor = slice.index(after: next)
                            segmentStart = cursor
                            continue
                        }
                    } else {
                        skipNextLF = true
                    }
                }
                cursor = slice.index(after: cursor)
                segmentStart = cursor
            } else {
                cursor = slice.index(after: cursor)
            }
        }

        if segmentStart < end {
            try appendToCurrentLine(slice[segmentStart..<end])
        }
    }

    private func appendToCurrentLine(_ bytes: Data.SubSequence) throws {
        let count = bytes.count
        if currentEventBytes + count > limits.maxSingleEventBytes {
            throw GeminiSSEError.singleEventTooLarge(limitBytes: limits.maxSingleEventBytes)
        }
        currentEventBytes += count
        lineBuffer.append(contentsOf: bytes)
    }

    private func processCompletedLine() throws {
        if lineBuffer.isEmpty {
            currentEventBytes = 0
            if !currentEventDataLines.isEmpty {
                let payload = currentEventDataLines.joined(separator: "\n")
                currentEventDataLines.removeAll(keepingCapacity: true)
                currentEventHasField = false
                dispatchedEventCount += 1
                try onEvent(payload)
            } else {
                currentEventHasField = false
            }
            return
        }

        if currentEventBytes + 1 > limits.maxSingleEventBytes {
            throw GeminiSSEError.singleEventTooLarge(limitBytes: limits.maxSingleEventBytes)
        }
        currentEventBytes += 1

        guard let line = String(data: lineBuffer, encoding: .utf8) else {
            throw GeminiSSEError.invalidUTF8
        }
        lineBuffer.removeAll(keepingCapacity: true)

        if line.hasPrefix(":") {
            if currentEventDataLines.isEmpty && !currentEventHasField {
                currentEventBytes = 0
            }
            return
        }

        let field: Substring
        var value: Substring
        if let colonIndex = line.firstIndex(of: ":") {
            field = line[..<colonIndex]
            value = line[line.index(after: colonIndex)...]
            if value.first == " " {
                value = value.dropFirst()
            }
        } else {
            field = line[...]
            value = ""
        }

        currentEventHasField = true
        if field == "data" {
            currentEventDataLines.append(String(value))
        }
    }
}

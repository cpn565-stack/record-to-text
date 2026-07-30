import Foundation

public struct HelperEvent: Codable, Equatable, Sendable {
    public let type: String
    public let value: String?
    public let current: Double?
    public let total: Double?
    public let unit: String?
    public let level: String?
    public let message: String?
    public let code: String?
    public let recoverable: Bool?
    public let outputPath: String?
    public let durationSeconds: Double?
    public let supportsSystemPrompt: Bool?
    public let supportsContext: Bool?

    public init(
        type: String,
        value: String? = nil,
        current: Double? = nil,
        total: Double? = nil,
        unit: String? = nil,
        level: String? = nil,
        message: String? = nil,
        code: String? = nil,
        recoverable: Bool? = nil,
        outputPath: String? = nil,
        durationSeconds: Double? = nil,
        supportsSystemPrompt: Bool? = nil,
        supportsContext: Bool? = nil
    ) {
        self.type = type
        self.value = value
        self.current = current
        self.total = total
        self.unit = unit
        self.level = level
        self.message = message
        self.code = code
        self.recoverable = recoverable
        self.outputPath = outputPath
        self.durationSeconds = durationSeconds
        self.supportsSystemPrompt = supportsSystemPrompt
        self.supportsContext = supportsContext
    }
}

public enum JSONLParserError: LocalizedError {
    case invalidUTF8
    case invalidJSON(line: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "Helper 回傳了無法解讀的 UTF-8 資料。"
        case let .invalidJSON(line, underlying):
            return "Helper 回傳了無效的 JSONL：\(line)（\(underlying.localizedDescription)）"
        }
    }
}

public struct JSONLStreamParser {
    private var buffer = Data()
    private let decoder: JSONDecoder

    public init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    public mutating func append(_ data: Data) throws -> [HelperEvent] {
        buffer.append(data)
        var events: [HelperEvent] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[..<newline]
            if lineData.last == 0x0D {
                lineData = lineData.dropLast()
            }
            buffer.removeSubrange(...newline)
            guard !lineData.isEmpty else {
                continue
            }
            events.append(try decode(Data(lineData)))
        }

        return events
    }

    public mutating func finish() throws -> [HelperEvent] {
        guard !buffer.isEmpty else {
            return []
        }
        defer { buffer.removeAll(keepingCapacity: false) }
        return [try decode(buffer)]
    }

    private func decode(_ data: Data) throws -> HelperEvent {
        guard let line = String(data: data, encoding: .utf8) else {
            throw JSONLParserError.invalidUTF8
        }
        do {
            return try decoder.decode(HelperEvent.self, from: data)
        } catch {
            throw JSONLParserError.invalidJSON(line: line, underlying: error)
        }
    }
}

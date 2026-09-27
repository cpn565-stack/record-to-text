import Foundation

/// A value in the restricted JSON subset used for integrity digests.
///
/// Floating point is deliberately unrepresentable: two implementations must be
/// able to agree on bytes, and number formatting is the easiest way to lose
/// that agreement. Every quantity in the local checkpoint contract is either a
/// 64-bit integer sample coordinate or a string.
public indirect enum CanonicalJSONValue: Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case string(String)
    case array([CanonicalJSONValue])
    case object([String: CanonicalJSONValue])

    public static func representables<T: CanonicalJSONRepresentable>(
        _ values: [T]
    ) -> CanonicalJSONValue {
        .array(values.map(\.canonicalValue))
    }

    public static func optional(_ value: (any CanonicalJSONRepresentable)?) -> CanonicalJSONValue {
        value?.canonicalValue ?? .null
    }

    public static func optionalInteger(_ value: Int?) -> CanonicalJSONValue {
        value.map { .integer(Int64($0)) } ?? .null
    }

    public static func optionalInt64(_ value: Int64?) -> CanonicalJSONValue {
        value.map { .integer($0) } ?? .null
    }

    public static func optionalString(_ value: String?) -> CanonicalJSONValue {
        value.map { .string($0) } ?? .null
    }

    public static func optionalBool(_ value: Bool?) -> CanonicalJSONValue {
        value.map { .bool($0) } ?? .null
    }
}

public protocol CanonicalJSONRepresentable {
    var canonicalValue: CanonicalJSONValue { get }
}

public extension CanonicalJSONRepresentable {
    func canonicalBytes() -> Data {
        CanonicalJSONEncoder.encode(canonicalValue)
    }

    func canonicalString() -> String {
        String(decoding: canonicalBytes(), as: UTF8.self)
    }
}

/// Deterministic serializer for `CanonicalJSONValue`.
///
/// Keys are ordered by UTF-8 byte value, separators carry no whitespace, and
/// strings use the same escape set as Python's `json.dumps(ensure_ascii=False)`.
/// The phase 0 contract requires the Python helper to digest these bytes
/// verbatim rather than re-encode and hope for a match, so this output is part
/// of the on-disk format and must not change casually.
public enum CanonicalJSONEncoder {
    public static func encode(_ value: CanonicalJSONValue) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(256)
        append(value, to: &bytes)
        return Data(bytes)
    }

    public static func encode<T: CanonicalJSONRepresentable>(_ value: T) -> Data {
        encode(value.canonicalValue)
    }

    private static func append(_ value: CanonicalJSONValue, to bytes: inout [UInt8]) {
        switch value {
        case .null:
            bytes.append(contentsOf: "null".utf8)
        case let .bool(flag):
            bytes.append(contentsOf: (flag ? "true" : "false").utf8)
        case let .integer(number):
            bytes.append(contentsOf: String(number).utf8)
        case let .string(text):
            appendString(text, to: &bytes)
        case let .array(items):
            bytes.append(UInt8(ascii: "["))
            for (index, item) in items.enumerated() {
                if index > 0 { bytes.append(UInt8(ascii: ",")) }
                append(item, to: &bytes)
            }
            bytes.append(UInt8(ascii: "]"))
        case let .object(members):
            bytes.append(UInt8(ascii: "{"))
            let ordered = members.sorted { lhs, rhs in
                lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
            }
            for (index, member) in ordered.enumerated() {
                if index > 0 { bytes.append(UInt8(ascii: ",")) }
                appendString(member.key, to: &bytes)
                bytes.append(UInt8(ascii: ":"))
                append(member.value, to: &bytes)
            }
            bytes.append(UInt8(ascii: "}"))
        }
    }

    private static func appendString(_ text: String, to bytes: inout [UInt8]) {
        bytes.append(UInt8(ascii: "\""))
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: bytes.append(contentsOf: [0x5C, 0x22])
            case 0x5C: bytes.append(contentsOf: [0x5C, 0x5C])
            case 0x08: bytes.append(contentsOf: [0x5C, 0x62])
            case 0x09: bytes.append(contentsOf: [0x5C, 0x74])
            case 0x0A: bytes.append(contentsOf: [0x5C, 0x6E])
            case 0x0C: bytes.append(contentsOf: [0x5C, 0x66])
            case 0x0D: bytes.append(contentsOf: [0x5C, 0x72])
            case let value where value < 0x20:
                bytes.append(
                    contentsOf: String(format: "\\u%04x", value).utf8
                )
            case let value:
                appendUTF8(value, to: &bytes)
            }
        }
        bytes.append(UInt8(ascii: "\""))
    }

    private static func appendUTF8(_ value: UInt32, to bytes: inout [UInt8]) {
        if value < 0x80 {
            bytes.append(UInt8(value))
        } else if value < 0x800 {
            bytes.append(UInt8(0xC0 | (value >> 6)))
            bytes.append(UInt8(0x80 | (value & 0x3F)))
        } else if value < 0x10000 {
            bytes.append(UInt8(0xE0 | (value >> 12)))
            bytes.append(UInt8(0x80 | ((value >> 6) & 0x3F)))
            bytes.append(UInt8(0x80 | (value & 0x3F)))
        } else {
            bytes.append(UInt8(0xF0 | (value >> 18)))
            bytes.append(UInt8(0x80 | ((value >> 12) & 0x3F)))
            bytes.append(UInt8(0x80 | ((value >> 6) & 0x3F)))
            bytes.append(UInt8(0x80 | (value & 0x3F)))
        }
    }
}

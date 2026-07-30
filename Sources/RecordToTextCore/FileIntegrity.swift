import CryptoKit
import Foundation

public enum FileIntegrity {
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func isValidSHA256(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...70).contains(byte)
                || (97...102).contains(byte)
        }
    }
}

public struct ModelFileManifest: Codable, Equatable, Sendable {
    public let path: String
    public let size: Int64
    public let sha256: String

    public init(path: String, size: Int64, sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

public struct ModelManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let repositoryID: String
    public let revision: String
    public let license: String
    public let architecture: CPUArchitecture
    public let backend: String
    public let files: [ModelFileManifest]

    public init(
        schemaVersion: Int = 1,
        repositoryID: String,
        revision: String,
        license: String,
        architecture: CPUArchitecture,
        backend: String,
        files: [ModelFileManifest]
    ) {
        self.schemaVersion = schemaVersion
        self.repositoryID = repositoryID
        self.revision = revision
        self.license = license
        self.architecture = architecture
        self.backend = backend
        self.files = files
    }
}

public struct RuntimeManifestValidator {
    public let trustedTeamIdentifier: String
    public let allowedDownloadHosts: Set<String>

    public init(
        trustedTeamIdentifier: String,
        allowedDownloadHosts: Set<String>
    ) {
        self.trustedTeamIdentifier = trustedTeamIdentifier
        self.allowedDownloadHosts = allowedDownloadHosts
    }

    public func validate(
        _ manifest: RuntimeManifest,
        architecture: CPUArchitecture
    ) throws {
        guard manifest.schemaVersion == 1 else {
            throw RuntimeManifestValidationError.unsupportedSchema(manifest.schemaVersion)
        }
        guard manifest.architecture == architecture else {
            throw RuntimeManifestValidationError.architectureMismatch(
                expected: architecture,
                actual: manifest.architecture
            )
        }
        guard
            manifest.downloadURL.scheme?.lowercased() == "https",
            let host = manifest.downloadURL.host?.lowercased(),
            allowedDownloadHosts.contains(host)
        else {
            throw RuntimeManifestValidationError.untrustedDownloadURL(
                manifest.downloadURL.absoluteString
            )
        }
        guard manifest.teamIdentifier == trustedTeamIdentifier else {
            throw RuntimeManifestValidationError.teamIdentifierMismatch
        }
        guard FileIntegrity.isValidSHA256(manifest.sha256) else {
            throw RuntimeManifestValidationError.invalidSHA256
        }
        guard manifest.downloadSize > 0 else {
            throw RuntimeManifestValidationError.invalidDownloadSize
        }
    }
}

public enum RuntimeManifestValidationError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case architectureMismatch(expected: CPUArchitecture, actual: CPUArchitecture)
    case untrustedDownloadURL(String)
    case teamIdentifierMismatch
    case invalidSHA256
    case invalidDownloadSize

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "不支援 Runtime manifest schema \(version)。"
        case let .architectureMismatch(expected, actual):
            return "Runtime 架構不符：需要 \(expected.rawValue)，收到 \(actual.rawValue)。"
        case let .untrustedDownloadURL(url):
            return "Runtime 下載網址不在白名單：\(url)"
        case .teamIdentifierMismatch:
            return "Runtime Team Identifier 與 App 內建信任值不符。"
        case .invalidSHA256:
            return "Runtime SHA-256 格式無效。"
        case .invalidDownloadSize:
            return "Runtime 下載大小無效。"
        }
    }
}

import Foundation
import Security

protocol GoogleAIStudioCredentialStoring {
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ apiKey: String?) throws
}

enum GoogleAIStudioCredentialStoreError: LocalizedError {
    case unexpectedKeychainStatus(OSStatus)
    case invalidStoredValue

    var errorDescription: String? {
        switch self {
        case let .unexpectedKeychainStatus(status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain 作業失敗（\(detail ?? "OSStatus \(status)")）。"
        case .invalidStoredValue:
            return "Keychain 中的 Google AI Studio API Key 格式無法讀取。"
        }
    }
}

struct KeychainGoogleAIStudioCredentialStore: GoogleAIStudioCredentialStoring {
    private let service: String
    private let account: String

    init(
        service: String = "com.specifique.record-to-text",
        account: String = "google-ai-studio-api-key"
    ) {
        self.service = service
        self.account = account
    }

    func loadAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw GoogleAIStudioCredentialStoreError.unexpectedKeychainStatus(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw GoogleAIStudioCredentialStoreError.invalidStoredValue
        }
        return Self.normalized(value)
    }

    func saveAPIKey(_ apiKey: String?) throws {
        guard let normalized = Self.normalized(apiKey) else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw GoogleAIStudioCredentialStoreError.unexpectedKeychainStatus(status)
            }
            return
        }

        let data = Data(normalized.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            update as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw GoogleAIStudioCredentialStoreError.unexpectedKeychainStatus(updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        // Use the traditional macOS login Keychain defaults. The
        // kSecAttrAccessible family is only supported here with the Data
        // Protection Keychain (which requires a correctly signed/entitled App)
        // or synchronizable items; ThisDeviceOnly cannot be synchronizable.
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GoogleAIStudioCredentialStoreError.unexpectedKeychainStatus(addStatus)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}

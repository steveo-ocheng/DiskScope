import Foundation
import Security

/// Where the Anthropic API key lives. Abstracted so tests never need the real Keychain.
protocol APIKeyStore: Sendable {
    func read() -> String?
    func save(_ key: String) throws
    func delete() throws
}

struct KeychainError: LocalizedError, Equatable {
    let status: OSStatus
    var errorDescription: String? {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "Keychain: \(text)"
    }
}

/// A generic-password item in the login Keychain: readable only while the Mac is unlocked,
/// never synced to iCloud or other devices.
struct KeychainStore: APIKeyStore {
    static let apiKey = KeychainStore(service: "com.diskscope.app.anthropic-api-key")

    let service: String
    var account = "default"

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    func save(_ key: String) throws {
        let data = Data(key.utf8)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecAttrLabel as String] = "DiskScope – Anthropic API key"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

enum APIKeyValidation {
    enum Problem: LocalizedError, Equatable {
        case empty, wrongPrefix, badCharacters, wrongLength
        var errorDescription: String? {
            switch self {
            case .empty: return "Paste your API key first."
            case .wrongPrefix: return "That doesn't look like an Anthropic API key (they start with “sk-ant-”)."
            case .badCharacters: return "The key contains spaces or unexpected characters. Copy it again from the Claude Console."
            case .wrongLength: return "The key looks incomplete. Copy it again from the Claude Console."
            }
        }
    }

    /// Trims surrounding whitespace (keys are often pasted with a trailing newline) and checks the shape.
    static func normalize(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw Problem.empty }
        guard key.hasPrefix("sk-ant-") else { throw Problem.wrongPrefix }
        guard key.unicodeScalars.allSatisfy({ $0.isASCII && $0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" })
        else { throw Problem.badCharacters }
        guard (20...400).contains(key.count) else { throw Problem.wrongLength }
        return key
    }
}

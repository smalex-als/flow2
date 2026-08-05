import Foundation
import Security

/// A single named secret, kept somewhere other than the app's own files.
///
/// Reading is fallible on purpose: the keychain can refuse, and a caller that cannot tell "no
/// secret stored" from "could not ask" has no way to avoid destroying one it simply failed to read.
protocol SecretStore {
    func load() throws -> String?
    func save(_ secret: String) throws
    func delete() throws
}

enum KeychainError: LocalizedError {
    case operationFailed(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .operationFailed(let operation, let status):
            let explanation = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain \(operation) failed: \(explanation) (\(status))"
        }
    }
}

/// Stores a secret as a generic password in the login keychain.
///
/// The data protection keychain is deliberately not requested. It needs an `application-identifier`
/// or `keychain-access-groups` entitlement, and Flow2 ships with neither — asking for it would fail
/// with `errSecMissingEntitlement` instead of storing anything.
///
/// Access survives rebuilds for the same reason the Accessibility grant does: the keychain records
/// the designated requirement of the app it trusts, and Flow2's names its signing certificate
/// rather than a `cdhash`. Verify with `codesign -d -r-` — a requirement mentioning `cdhash` would
/// make every build a different app, and the user would be asked to unlock the key again each time.
struct KeychainSecretStore: SecretStore {
    private let service: String
    private let account: String
    private let label: String

    init(service: String = "com.smalex.Flow2",
         account: String = "openai-api-key",
         label: String = "Flow2 OpenAI API key") {
        self.service = service
        self.account = account
        self.label = label
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func load() throws -> String? {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.operationFailed(operation: "read", status: status)
        }
    }

    func save(_ secret: String) throws {
        let data = Data(secret.utf8)
        let updateStatus = SecItemUpdate(itemQuery as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.operationFailed(operation: "update", status: updateStatus)
        }

        var query = itemQuery
        query[kSecValueData as String] = data
        query[kSecAttrLabel as String] = label
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.operationFailed(operation: "write", status: addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.operationFailed(operation: "delete", status: status)
        }
    }
}

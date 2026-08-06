import Foundation
import Security

nonisolated enum KeychainError: LocalizedError, Sendable {
    case notFound
    case unexpectedData
    case missingPersistentReference
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Claude Code credentials not found in the Keychain. Sign in with `claude` first."
        case .unexpectedData:
            return "The Keychain item did not contain valid JSON."
        case .missingPersistentReference:
            return "The Keychain did not return a stable reference for the Claude Code credentials."
        case .osStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

/// Read/write access to the generic-password item Claude Code stores its OAuth tokens in.
///
/// The initial lookup is intentionally service-only so the app keeps working if Claude Code's
/// account attribute changes. Every lookup returns the item's persistent reference, and updates
/// use that reference so a write can never affect a different item sharing the service name.
nonisolated enum Keychain {
    static let service = "Claude Code-credentials"

    struct Item: Sendable {
        let data: Data
        let persistentReference: Data
    }

    static func read() throws -> Item {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        return try read(matching: query)
    }

    /// Re-reads the exact item captured by `read()`. This is used immediately before a token
    /// write so changes made while the network request was in flight can be detected.
    static func read(persistentReference: Data) throws -> Item {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchItemList as String: [persistentReference],
            kSecReturnData as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        return try read(matching: query)
    }

    static func write(_ data: Data, persistentReference: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchItemList as String: [persistentReference],
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    private static func read(matching query: [String: Any]) throws -> Item {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        guard let values = result as? [String: Any] else {
            throw KeychainError.unexpectedData
        }
        guard let data = values[kSecValueData as String] as? Data else {
            throw KeychainError.unexpectedData
        }
        guard let persistentReference = values[kSecValuePersistentRef as String] as? Data else {
            throw KeychainError.missingPersistentReference
        }
        return Item(data: data, persistentReference: persistentReference)
    }
}

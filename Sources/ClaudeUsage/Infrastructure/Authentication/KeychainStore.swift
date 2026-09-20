import Foundation
import Security

nonisolated enum KeychainError: LocalizedError, Sendable {
    case notFound
    case unexpectedData
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Not signed in — sign in from Settings."
        case .unexpectedData:
            return "The stored sign-in could not be read — sign in again."
        case .osStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

public enum KeychainAccount: String, Sendable, CaseIterable {
    case claude
    case codex
}

public struct AuthCredentials: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scopes: [String]?
    public var accountId: String?
    public var email: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        scopes: [String]? = nil,
        accountId: String? = nil,
        email: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.accountId = accountId
        self.email = email
    }

    public func isExpiring(within window: TimeInterval = 120, relativeTo now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= window
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    /// An expired access token is only recoverable while a refresh token survives alongside it.
    public var isUsable: Bool {
        !isExpired || refreshToken != nil
    }
}

public enum KeychainStore: Sendable {
    public static let service = "ClaudeUsage-credentials"

    public static func save(_ credentials: AuthCredentials, for account: KeychainAccount) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try write(try encoder.encode(credentials), account: account)
    }

    public static func load(for account: KeychainAccount) throws -> AuthCredentials {
        let data = try read(account: account)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let credentials = try? decoder.decode(AuthCredentials.self, from: data) else {
            throw KeychainError.unexpectedData
        }
        return credentials
    }

    public static func delete(for account: KeychainAccount) throws {
        let status = SecItemDelete(query(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    private static func write(_ data: Data, account: KeychainAccount) throws {
        let query = query(for: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        guard updateStatus == errSecItemNotFound else {
            guard updateStatus == errSecSuccess else { throw KeychainError.osStatus(updateStatus) }
            return
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.osStatus(addStatus) }
    }

    private static func read(account: KeychainAccount) throws -> Data {
        var query = query(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        guard let data = result as? Data else { throw KeychainError.unexpectedData }
        return data
    }

    private static func query(for account: KeychainAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }
}

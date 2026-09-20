import Foundation
import Security

/// Represents authenticated OAuth credentials for a service.
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
}

/// Secure storage and retrieval of credentials in the macOS Keychain,
/// with automatic migration/fallback for legacy Claude Code and Codex credentials.
public enum KeychainStore: Sendable {
    public static let service = "ClaudeUsage-credentials"

    public static func save(_ credentials: AuthCredentials, for account: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(credentials)
        try writeData(data, service: service, account: account)
    }

    public static func load(for account: String) throws -> AuthCredentials {
        // 1. Try reading the app-owned credentials from Keychain
        if let data = try? readData(service: service, account: account) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let creds = try? decoder.decode(AuthCredentials.self, from: data) {
                return creds
            }
        }

        // 2. Fallback to legacy credential sources if app credentials not yet saved
        if account == "claude" {
            if let legacyCreds = tryLegacyClaudeCodeCredentials() {
                return legacyCreds
            }
        } else if account == "codex" {
            if let legacyCreds = tryLegacyCodexCredentials() {
                return legacyCreds
            }
        }

        throw KeychainError.notFound
    }

    public static func delete(for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    // MARK: - Low-level Keychain primitives

    public static func writeData(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addAttributes = query
            addAttributes[kSecValueData as String] = data
            let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.osStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.osStatus(updateStatus)
        }
    }

    public static func readData(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        guard let data = result as? Data else { throw KeychainError.unexpectedData }
        return data
    }

    // MARK: - Legacy Fallback Helpers

    private static func tryLegacyClaudeCodeCredentials() -> AuthCredentials? {
        // Query "Claude Code-credentials"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String
        else {
            return nil
        }

        let refreshToken = oauth["refreshToken"] as? String
        var expiresAt: Date?
        if let millis = oauth["expiresAt"] as? Double {
            expiresAt = Date(timeIntervalSince1970: millis / 1000)
        }

        return AuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scopes: oauth["scopes"] as? [String]
        )
    }

    private static func tryLegacyCodexCredentials() -> AuthCredentials? {
        let authPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: authPath) else { return nil }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = root["tokens"] as? [String: Any],
            let accessToken = tokens["access_token"] as? String
        else {
            return nil
        }

        let refreshToken = tokens["refresh_token"] as? String
        let accountId = tokens["account_id"] as? String

        return AuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountId: accountId
        )
    }
}

import Foundation

nonisolated enum AuthError: LocalizedError, Sendable {
    case malformedCredentials
    case refreshTokenExpired
    case refreshBusy
    case refreshFailed(status: Int)

    var errorDescription: String? {
        switch self {
        case .malformedCredentials:
            return "Claude Code credentials in the Keychain are not in the expected format."
        case .refreshTokenExpired:
            return "Sign-in has fully expired. Run `claude` once to sign in again."
        case .refreshBusy:
            return "Another process is refreshing the sign-in. Will retry shortly."
        case .refreshFailed(let status):
            return "Token refresh failed (HTTP \(status))."
        }
    }
}

/// The subset of the Keychain payload we care about, plus the raw JSON so unknown fields
/// (`scopes`, `subscriptionType`, `rateLimitTier`, …) survive a write-back untouched.
nonisolated struct Credentials: Sendable {
    static let containerKey = "claudeAiOauth"

    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var refreshTokenExpiresAt: Date?

    private var encodedRoot: Data
    private var persistentReference: Data?

    init(data: Data) throws {
        try self.init(data: data, persistentReference: nil)
    }

    private init(data: Data, persistentReference: Data?) throws {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root[Self.containerKey] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String,
            let refreshToken = oauth["refreshToken"] as? String,
            let expiresAtMillis = oauth["expiresAt"] as? Double
        else {
            throw AuthError.malformedCredentials
        }

        self.encodedRoot = data
        self.persistentReference = persistentReference
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = Date(timeIntervalSince1970: expiresAtMillis / 1000)
        if let millis = oauth["refreshTokenExpiresAt"] as? Double {
            self.refreshTokenExpiresAt = Date(timeIntervalSince1970: millis / 1000)
        }
    }

    static func load() throws -> Credentials {
        let item = try Keychain.read()
        return try Credentials(data: item.data, persistentReference: item.persistentReference)
    }

    var isExpired: Bool { expiresAt <= Date.now }

    func isExpiring(within window: TimeInterval) -> Bool {
        expiresAt.timeIntervalSinceNow <= window
    }

    /// Re-reads and updates the exact Keychain item this value came from. A changed token pair
    /// means another process won the refresh race, in which case its credentials are adopted and
    /// the refresh response is deliberately discarded. Unknown JSON fields are copied from the
    /// latest Keychain value before the refreshed fields are merged.
    @discardableResult
    mutating func applyAndPersist(_ refreshed: TokenResponse) throws -> Bool {
        guard let persistentReference else {
            throw KeychainError.missingPersistentReference
        }

        let item: Keychain.Item
        do {
            item = try Keychain.read(persistentReference: persistentReference)
        } catch KeychainError.notFound {
            // Claude Code may have replaced rather than updated the item. Capture the replacement
            // precisely before deciding whether the response is still safe to persist.
            item = try Keychain.read()
        }

        var latest = try Credentials(
            data: item.data,
            persistentReference: item.persistentReference
        )
        guard latest.accessToken == accessToken, latest.refreshToken == refreshToken else {
            self = latest
            return false
        }

        guard
            var root = try JSONSerialization.jsonObject(with: latest.encodedRoot) as? [String: Any],
            var oauth = root[Self.containerKey] as? [String: Any]
        else {
            throw AuthError.malformedCredentials
        }

        latest.accessToken = refreshed.accessToken
        oauth["accessToken"] = refreshed.accessToken

        if let newRefresh = refreshed.refreshToken {
            latest.refreshToken = newRefresh
            oauth["refreshToken"] = newRefresh
        }

        let newExpiry = Date.now.addingTimeInterval(refreshed.expiresIn)
        latest.expiresAt = newExpiry
        oauth["expiresAt"] = newExpiry.timeIntervalSince1970 * 1000

        root[Self.containerKey] = oauth
        let data = try JSONSerialization.data(withJSONObject: root)
        try Keychain.write(data, persistentReference: item.persistentReference)
        latest.encodedRoot = data
        self = latest
        return true
    }
}

nonisolated struct TokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresIn = try container.decodeIfPresent(TimeInterval.self, forKey: .expiresIn) ?? 8 * 3600
    }
}

/// Hands out a usable access token, refreshing only when genuinely necessary.
///
/// Claude Code refreshes this same Keychain item whenever it runs, and refresh tokens rotate.
/// Rotating one out from under a running Claude Code session would break its next refresh, so
/// this deliberately does the least possible work:
///
/// 1. Serve polls from the last known credentials, so a steady state costs no Keychain reads.
/// 2. Refresh only once the token is actually expired (or within `nearExpiryWindow`).
/// 3. Re-read the Keychain under the lock first — if another process already refreshed, use that.
/// 4. Collapse concurrent in-process callers onto a single refresh task.
/// 5. Serialise cooperating copies of this app with `flock`.
///
/// A cached copy can be stale when Claude Code rotates the token; the 401 retry path forces a
/// reload, so staleness costs one rejected request rather than a wrong answer.
///
/// The lock is app-owned and advisory: Claude Code does not participate in it. The exact
/// Keychain item is therefore re-read again before every write to detect external rotation and
/// reduce (but not eliminate) the remaining compare/write race with non-cooperating processes.
actor AuthManager {
    static let shared = AuthManager()

    private let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let nearExpiryWindow: TimeInterval = 120
    private var inFlight: RefreshOperation?
    private var cached: Credentials?

    func accessToken() async throws -> String {
        let credentials = try currentCredentials(reloading: false)
        guard credentials.isExpiring(within: nearExpiryWindow) else {
            return credentials.accessToken
        }
        return try await refreshLocked(reason: .expiring)
    }

    private func currentCredentials(reloading: Bool) throws -> Credentials {
        if !reloading, let cached {
            return cached
        }
        let loaded = try Credentials.load()
        cached = loaded
        return loaded
    }

    /// Refreshes after a 401 only if the rejected token is still current. If another process
    /// replaced it while this caller was waiting for the lock, the replacement is used directly
    /// instead of rotating the refresh token a second time.
    func forceRefresh(rejectedAccessToken: String) async throws -> String {
        try await refreshLocked(reason: .rejectedAccessToken(rejectedAccessToken))
    }

    /// Collapses concurrent callers onto one refresh. Without this, actor reentrancy across the
    /// network `await` would let a second caller reach the file lock and stall the executor.
    private func refreshLocked(reason: RefreshReason) async throws -> String {
        if let operation = inFlight {
            let token = try await operation.task.value

            // A refresh for a different reason can legitimately return the token this caller
            // just had rejected (for example, an expiry check can decide it is still fresh).
            // In that case start, or join, a refresh that specifically handles this rejection.
            if operation.reason != reason,
                case .rejectedAccessToken(let rejectedAccessToken) = reason,
                token == rejectedAccessToken
            {
                if inFlight?.id == operation.id {
                    inFlight = nil
                }
                return try await refreshLocked(reason: reason)
            }
            return token
        }

        let id = UUID()
        let task = Task { try await performRefresh(reason: reason) }
        inFlight = RefreshOperation(id: id, reason: reason, task: task)
        defer {
            if inFlight?.id == id {
                inFlight = nil
            }
        }
        return try await task.value
    }

    private func performRefresh(reason: RefreshReason) async throws -> String {
        let lock = try FileLock(url: AppPaths.refreshLock)
        guard try await lock.acquire(timeout: 30) else { throw AuthError.refreshBusy }
        defer { lock.unlock() }

        // A cooperating app process may have refreshed while this task waited for the lock.
        var credentials = try currentCredentials(reloading: true)
        switch reason {
        case .expiring:
            guard credentials.isExpiring(within: nearExpiryWindow) else {
                return credentials.accessToken
            }
        case .rejectedAccessToken(let rejectedAccessToken):
            guard credentials.accessToken == rejectedAccessToken else {
                return credentials.accessToken
            }
        }

        if let refreshExpiry = credentials.refreshTokenExpiresAt, refreshExpiry <= Date.now {
            throw AuthError.refreshTokenExpired
        }

        let refreshed = try await requestToken(refreshToken: credentials.refreshToken)
        _ = try credentials.applyAndPersist(refreshed)
        cached = credentials
        return credentials.accessToken
    }

    private struct RefreshOperation: Sendable {
        let id: UUID
        let reason: RefreshReason
        let task: Task<String, Error>
    }

    private enum RefreshReason: Equatable, Sendable {
        case expiring
        case rejectedAccessToken(String)
    }

    private func requestToken(refreshToken: String) async throws -> TokenResponse {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Do not surface or persist arbitrary response bodies from the credential endpoint.
            throw AuthError.refreshFailed(status: status)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
}

nonisolated enum FileLockError: LocalizedError, Sendable {
    case systemCallFailed(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .systemCallFailed(let operation, let code):
            return "Refresh lock \(operation) failed (errno \(code))."
        }
    }
}

/// An advisory lock shared only by cooperating copies of this app. It does not coordinate with
/// Claude Code or any other process that does not explicitly acquire the same lock file.
nonisolated final class FileLock: Sendable {
    private let descriptor: Int32

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            throw FileLockError.systemCallFailed(operation: "open", code: errno)
        }
    }

    /// Polls non-blockingly so a lock held by another process suspends this task rather than
    /// parking the thread it happens to be running on.
    func acquire(timeout: TimeInterval) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))

        while true {
            try Task.checkCancellation()
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return true
            }

            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN {
                guard clock.now < deadline else { return false }
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            if code == EINTR {
                continue
            }
            throw FileLockError.systemCallFailed(operation: "acquire", code: code)
        }
    }

    func unlock() { flock(descriptor, LOCK_UN) }
    deinit { close(descriptor) }
}

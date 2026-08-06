import Foundation

enum AuthError: LocalizedError {
    case malformedCredentials
    case refreshTokenExpired
    case refreshBusy
    case refreshFailed(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .malformedCredentials:
            return "Claude Code credentials in the Keychain are not in the expected format."
        case .refreshTokenExpired:
            return "Sign-in has fully expired. Run `claude` once to sign in again."
        case .refreshBusy:
            return "Another process is refreshing the sign-in. Will retry shortly."
        case .refreshFailed(let status, let body):
            let detail = body.isEmpty ? "" : " — \(body.prefix(160))"
            return "Token refresh failed (HTTP \(status))\(detail)"
        }
    }
}

/// The subset of the Keychain payload we care about, plus the raw JSON so unknown fields
/// (`scopes`, `subscriptionType`, `rateLimitTier`, …) survive a write-back untouched.
struct Credentials {
    static let containerKey = "claudeAiOauth"

    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var refreshTokenExpiresAt: Date?

    private var root: [String: Any]

    init(data: Data) throws {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root[Self.containerKey] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String,
            let refreshToken = oauth["refreshToken"] as? String,
            let expiresAtMillis = oauth["expiresAt"] as? Double
        else {
            throw AuthError.malformedCredentials
        }

        self.root = root
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = Date(timeIntervalSince1970: expiresAtMillis / 1000)
        if let millis = oauth["refreshTokenExpiresAt"] as? Double {
            self.refreshTokenExpiresAt = Date(timeIntervalSince1970: millis / 1000)
        }
    }

    static func load() throws -> Credentials {
        try Credentials(data: Keychain.read())
    }

    var isExpired: Bool { expiresAt <= Date() }

    func isExpiring(within window: TimeInterval) -> Bool {
        expiresAt.timeIntervalSinceNow <= window
    }

    /// Merges refreshed tokens into the existing JSON and writes it back, preserving every
    /// other key Claude Code put there.
    mutating func applyAndPersist(_ refreshed: TokenResponse) throws {
        var oauth = root[Self.containerKey] as? [String: Any] ?? [:]

        accessToken = refreshed.accessToken
        oauth["accessToken"] = refreshed.accessToken

        if let newRefresh = refreshed.refreshToken {
            refreshToken = newRefresh
            oauth["refreshToken"] = newRefresh
        }

        let newExpiry = Date().addingTimeInterval(refreshed.expiresIn)
        expiresAt = newExpiry
        oauth["expiresAt"] = newExpiry.timeIntervalSince1970 * 1000

        root[Self.containerKey] = oauth
        try Keychain.write(try JSONSerialization.data(withJSONObject: root))
    }
}

struct TokenResponse: Decodable {
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
/// 1. Refresh only once the token is actually expired (or within `nearExpiryWindow`).
/// 2. Re-read the Keychain under the lock first — if Claude Code already refreshed, use that.
/// 3. Collapse concurrent in-process callers onto a single refresh task.
/// 4. Serialise across processes with an flock so two copies never refresh at once.
actor AuthManager {
    static let shared = AuthManager()

    private let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let nearExpiryWindow: TimeInterval = 120
    private var inFlight: Task<String, Error>?

    func accessToken() async throws -> String {
        let credentials = try Credentials.load()
        guard credentials.isExpiring(within: nearExpiryWindow) else {
            return credentials.accessToken
        }
        return try await refreshLocked()
    }

    /// Forces a refresh regardless of the cached expiry — used after the API answers 401,
    /// which means the token died earlier than `expiresAt` claimed.
    func forceRefresh() async throws -> String {
        try await refreshLocked(ignoringExpiry: true)
    }

    /// Collapses concurrent callers onto one refresh. Without this, actor reentrancy across the
    /// network `await` would let a second caller reach the file lock and stall the executor.
    private func refreshLocked(ignoringExpiry: Bool = false) async throws -> String {
        if let inFlight { return try await inFlight.value }

        let task = Task { try await performRefresh(ignoringExpiry: ignoringExpiry) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func performRefresh(ignoringExpiry: Bool) async throws -> String {
        let lock = try FileLock(url: AppPaths.refreshLock)
        guard await lock.acquire(timeout: 30) else { throw AuthError.refreshBusy }
        defer { lock.unlock() }

        // Someone else (most likely Claude Code itself) may have refreshed while we waited.
        var credentials = try Credentials.load()
        if !ignoringExpiry, !credentials.isExpiring(within: nearExpiryWindow) {
            return credentials.accessToken
        }

        if let refreshExpiry = credentials.refreshTokenExpiresAt, refreshExpiry <= Date() {
            throw AuthError.refreshTokenExpired
        }

        let refreshed = try await requestToken(refreshToken: credentials.refreshToken)
        try credentials.applyAndPersist(refreshed)
        return credentials.accessToken
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
            throw AuthError.refreshFailed(
                status: status,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
}

/// A cross-process advisory lock so a second copy of the app (or a leftover instance) cannot
/// race us into rotating the refresh token twice.
final class FileLock {
    private let descriptor: Int32

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// Polls non-blockingly so a lock held by another process suspends this task rather than
    /// parking the thread it happens to be running on.
    func acquire(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    func unlock() { flock(descriptor, LOCK_UN) }
    deinit { close(descriptor) }
}

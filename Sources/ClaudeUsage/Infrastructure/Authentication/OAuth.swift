import Foundation

nonisolated enum AuthError: LocalizedError, Sendable {
    case malformedCredentials
    case refreshTokenExpired
    case refreshBusy
    case refreshFailed(status: Int, detail: String?)

    var errorDescription: String? {
        switch self {
        case .malformedCredentials:
            return "The identity provider returned a sign-in response in an unexpected format."
        case .refreshTokenExpired:
            return "The sign-in expired — sign in again from Settings."
        case .refreshBusy:
            return "Another process is refreshing the sign-in — will retry shortly."
        case .refreshFailed(let status, let detail):
            guard let detail else { return "The sign-in service returned HTTP \(status)." }
            return "The sign-in service returned HTTP \(status): \(detail)"
        }
    }
}

nonisolated enum TokenErrorBody {
    static func describe(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : String(text.prefix(200))
        }

        if let nested = json["error"] as? [String: Any] {
            let parts = [nested["type"], nested["message"]].compactMap { $0 as? String }
            return parts.isEmpty ? nil : parts.joined(separator: ": ")
        }

        guard let code = json["error"] as? String else { return nil }
        guard let description = json["error_description"] as? String else { return code }
        return "\(code): \(description)"
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

nonisolated struct ClaudeProfile: Sendable {
    let email: String?

    init(data: Data) {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let account = json["account"] as? [String: Any]
        else {
            email = nil
            return
        }
        email = account["email"] as? String
    }
}

actor AuthManager {
    static let shared = AuthManager()

    private static let scopes = [
        "user:file_upload",
        "user:inference",
        "user:mcp_servers",
        "user:plugins",
        "user:profile",
        "user:sessions:claude_code",
    ]

    private let tokenURL: URL
    private let clientID: String
    private let authorizeURL: URL
    private let profileURL: URL
    private let nearExpiryWindow: TimeInterval = 120
    private var inFlightRefresh: RefreshOperation?
    private var inFlightSignIn: Task<AuthCredentials, Error>?
    private var cached: AuthCredentials?
    private var backfillAttempted = false

    init(environment: AppEnvironment = .shared) {
        self.tokenURL = environment.claudeTokenURL
        self.clientID = environment.claudeClientID
        self.authorizeURL = environment.claudeAuthorizeURL
        self.profileURL = environment.claudeProfileEndpoint
    }

    var isSignedIn: Bool {
        (try? currentCredentials(reloading: false))?.isUsable ?? false
    }

    var userEmail: String? {
        (try? currentCredentials(reloading: false))?.email
    }

    /// The signed-in account's email, backfilling it once for sessions saved before it was captured.
    func accountLabel() async -> String? {
        if let email = userEmail { return email }
        guard !backfillAttempted, isSignedIn else { return nil }
        backfillAttempted = true
        return await backfillEmail()
    }

    @discardableResult
    func startSignIn() async throws -> AuthCredentials {
        if let inFlightSignIn {
            return try await inFlightSignIn.value
        }

        let task = Task { try await performSignIn() }
        inFlightSignIn = task
        defer {
            if inFlightSignIn == task { inFlightSignIn = nil }
        }
        return try await task.value
    }

    func cancelSignIn() {
        inFlightSignIn?.cancel()
        inFlightSignIn = nil
    }

    func signOut() throws {
        cancelSignIn()
        cached = nil
        backfillAttempted = false
        try KeychainStore.delete(for: .claude)
    }

    func accessToken() async throws -> String {
        let credentials = try currentCredentials(reloading: false)
        guard credentials.isExpiring(within: nearExpiryWindow) else {
            return credentials.accessToken
        }
        return try await refreshLocked(reason: .expiring)
    }

    func forceRefresh(rejectedAccessToken: String) async throws -> String {
        try await refreshLocked(reason: .rejectedAccessToken(rejectedAccessToken))
    }

    private func performSignIn() async throws -> AuthCredentials {
        let flow = OAuthBrowserFlow(
            providerName: "Claude",
            authorizeURL: authorizeURL,
            clientID: clientID,
            scopes: Self.scopes,
            redirect: .ephemeralPort(path: "/callback")
        )

        let authorization = try await flow.authorize()
        var credentials = try await exchangeCode(authorization)
        credentials.email = try? await fetchProfileEmail(token: credentials.accessToken)
        try KeychainStore.save(credentials, for: .claude)
        cached = credentials
        return credentials
    }

    private func backfillEmail() async -> String? {
        do {
            let token = try await accessToken()
            guard let email = try await fetchProfileEmail(token: token), !email.isEmpty else {
                return nil
            }
            try saveEmail(email)
            return email
        } catch {
            return nil
        }
    }

    private func saveEmail(_ email: String) throws {
        guard var credentials = try? currentCredentials(reloading: true), credentials.email != email else {
            return
        }
        credentials.email = email
        try KeychainStore.save(credentials, for: .claude)
        cached = credentials
    }

    private func fetchProfileEmail(token: String) async throws -> String? {
        var request = URLRequest(url: profileURL)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AuthError.refreshFailed(status: status, detail: TokenErrorBody.describe(data))
        }
        return ClaudeProfile(data: data).email
    }

    private func currentCredentials(reloading: Bool) throws -> AuthCredentials {
        if !reloading, let cached {
            return cached
        }
        let loaded = try KeychainStore.load(for: .claude)
        cached = loaded
        return loaded
    }

    private func exchangeCode(
        _ authorization: OAuthBrowserFlow.Authorization
    ) async throws -> AuthCredentials {
        let response = try await requestToken(form: [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code", value: authorization.code),
            URLQueryItem(name: "redirect_uri", value: authorization.redirectURI),
            URLQueryItem(name: "code_verifier", value: authorization.verifier),
            URLQueryItem(name: "state", value: authorization.state),
        ])

        return AuthCredentials(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: Date.now.addingTimeInterval(response.expiresIn),
            scopes: Self.scopes
        )
    }

    private func refreshLocked(reason: RefreshReason) async throws -> String {
        if let operation = inFlightRefresh {
            let token = try await operation.task.value

            if operation.reason != reason,
                case .rejectedAccessToken(let rejectedAccessToken) = reason,
                token == rejectedAccessToken
            {
                if inFlightRefresh?.id == operation.id {
                    inFlightRefresh = nil
                }
                return try await refreshLocked(reason: reason)
            }
            return token
        }

        let id = UUID()
        let task = Task { try await performRefresh(reason: reason) }
        inFlightRefresh = RefreshOperation(id: id, reason: reason, task: task)
        defer {
            if inFlightRefresh?.id == id {
                inFlightRefresh = nil
            }
        }
        return try await task.value
    }

    private func performRefresh(reason: RefreshReason) async throws -> String {
        let lock = try FileLock(url: AppPaths.refreshLock)
        guard try await lock.acquire(timeout: 30) else { throw AuthError.refreshBusy }
        defer { lock.unlock() }

        let credentials = try currentCredentials(reloading: true)
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

        guard let refreshToken = credentials.refreshToken else {
            throw AuthError.refreshTokenExpired
        }

        let response = try await requestToken(form: [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ])

        var refreshed = credentials
        refreshed.accessToken = response.accessToken
        refreshed.refreshToken = response.refreshToken ?? refreshToken
        refreshed.expiresAt = Date.now.addingTimeInterval(response.expiresIn)

        try KeychainStore.save(refreshed, for: .claude)
        cached = refreshed
        return refreshed.accessToken
    }

    private func requestToken(form: [URLQueryItem]) async throws -> TokenResponse {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var components = URLComponents()
        components.queryItems = form
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AuthError.refreshFailed(status: status, detail: TokenErrorBody.describe(data))
        }

        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw AuthError.malformedCredentials
        }
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

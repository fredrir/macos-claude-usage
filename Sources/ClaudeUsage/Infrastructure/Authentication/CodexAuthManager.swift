import Foundation

public actor CodexAuthManager {
    public static let shared = CodexAuthManager()

    private static let scopes = ["openid", "profile", "email", "offline_access"]

    private let authorizeURL: URL
    private let tokenURL: URL
    private let clientID: String
    private let redirect: OAuthBrowserFlow.Redirect
    private let nearExpiryWindow: TimeInterval = 120

    private var cached: AuthCredentials?
    private var inFlightSignIn: Task<AuthCredentials, Error>?

    public init(environment: AppEnvironment = .shared) {
        self.authorizeURL = environment.openAIAuthorizeURL
        self.tokenURL = environment.openAITokenURL
        self.clientID = environment.openAIClientID

        let components = URLComponents(string: environment.openAIRedirectURI)
        let path = components?.path ?? ""
        self.redirect = .fixedPort(
            UInt16(components?.port ?? 1455),
            path: path.isEmpty ? "/auth/callback" : path
        )
    }

    public var isSignedIn: Bool {
        (try? currentCredentials(reloading: false))?.isUsable ?? false
    }

    public var userEmail: String? {
        try? currentCredentials(reloading: false).email
    }

    @discardableResult
    public func startSignIn() async throws -> AuthCredentials {
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

    public func cancelSignIn() {
        inFlightSignIn?.cancel()
        inFlightSignIn = nil
    }

    public func signOut() throws {
        cancelSignIn()
        cached = nil
        try KeychainStore.delete(for: .codex)
    }

    public func accessToken() async throws -> String {
        let credentials = try currentCredentials(reloading: false)
        guard credentials.isExpiring(within: nearExpiryWindow) else {
            return credentials.accessToken
        }
        return try await refreshTokens(credentials: credentials)
    }

    public func forceRefresh(rejectedAccessToken: String) async throws -> String {
        let credentials = try currentCredentials(reloading: true)
        guard credentials.accessToken == rejectedAccessToken else {
            return credentials.accessToken
        }
        return try await refreshTokens(credentials: credentials)
    }

    private func performSignIn() async throws -> AuthCredentials {
        let flow = OAuthBrowserFlow(
            providerName: "Codex / ChatGPT",
            authorizeURL: authorizeURL,
            clientID: clientID,
            scopes: Self.scopes,
            redirect: redirect,
            extraQueryItems: [
                URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
                URLQueryItem(name: "id_token_add_organizations", value: "true"),
            ]
        )

        let authorization = try await flow.authorize()
        let credentials = try await exchangeCode(authorization)
        try KeychainStore.save(credentials, for: .codex)
        cached = credentials
        return credentials
    }

    private func currentCredentials(reloading: Bool) throws -> AuthCredentials {
        if !reloading, let cached {
            return cached
        }
        let loaded = try KeychainStore.load(for: .codex)
        cached = loaded
        return loaded
    }

    private func exchangeCode(
        _ authorization: OAuthBrowserFlow.Authorization
    ) async throws -> AuthCredentials {
        try await requestCredentials(form: [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code", value: authorization.code),
            URLQueryItem(name: "redirect_uri", value: authorization.redirectURI),
            URLQueryItem(name: "code_verifier", value: authorization.verifier),
        ])
    }

    private func refreshTokens(credentials: AuthCredentials) async throws -> String {
        guard let refreshToken = credentials.refreshToken else {
            throw AuthError.refreshTokenExpired
        }

        let refreshed = try await requestCredentials(
            form: [
                URLQueryItem(name: "grant_type", value: "refresh_token"),
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "refresh_token", value: refreshToken),
            ],
            fallingBackTo: credentials
        )

        try KeychainStore.save(refreshed, for: .codex)
        cached = refreshed
        return refreshed.accessToken
    }

    private func requestCredentials(
        form: [URLQueryItem],
        fallingBackTo previous: AuthCredentials? = nil
    ) async throws -> AuthCredentials {
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

        return try Self.parseTokenResponse(data, previous: previous)
    }

    static func parseTokenResponse(
        _ data: Data,
        previous: AuthCredentials? = nil
    ) throws -> AuthCredentials {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = json["access_token"] as? String
        else {
            throw AuthError.malformedCredentials
        }

        let identity = IdentityToken(jwt: json["id_token"] as? String)
        let expiresIn = (json["expires_in"] as? Double) ?? 3600

        return AuthCredentials(
            accessToken: accessToken,
            refreshToken: (json["refresh_token"] as? String) ?? previous?.refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn),
            scopes: scopes,
            accountId: identity.subject ?? previous?.accountId,
            email: identity.email ?? previous?.email
        )
    }
}

struct IdentityToken: Sendable {
    var email: String?
    var subject: String?

    init(jwt: String?) {
        guard let jwt else { return }
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }

        guard
            let payload = Data(base64Encoded: base64),
            let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else {
            return
        }

        email = claims["email"] as? String
        subject = claims["sub"] as? String
    }
}

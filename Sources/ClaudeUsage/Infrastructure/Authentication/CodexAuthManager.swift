import AppKit
import Foundation

/// Manages Codex (OpenAI) OAuth 2.0 PKCE authentication lifecycle and token refresh.
public actor CodexAuthManager {
    public static let shared = CodexAuthManager()

    private let authorizeURL: URL
    private let tokenURL: URL
    private let clientID: String
    private let redirectURI: String
    private let expectedPort: UInt16
    private let expectedPath: String
    private let scopes = ["openid", "profile", "email", "offline_access"]
    private let nearExpiryWindow: TimeInterval = 120

    private var cached: AuthCredentials?
    private var inFlightSignIn: Task<AuthCredentials, Error>?

    public init(environment: AppEnvironment = .shared) {
        self.authorizeURL = environment.openAIAuthorizeURL
        self.tokenURL = environment.openAITokenURL
        self.clientID = environment.openAIClientID
        self.redirectURI = environment.openAIRedirectURI

        if let components = URLComponents(string: environment.openAIRedirectURI) {
            self.expectedPort = UInt16(components.port ?? 1455)
            self.expectedPath = components.path.isEmpty ? "/auth/callback" : components.path
        } else {
            self.expectedPort = 1455
            self.expectedPath = "/auth/callback"
        }
    }

    public var isSignedIn: Bool {
        (try? currentCredentials(reloading: false)) != nil
    }

    public var userEmail: String? {
        try? currentCredentials(reloading: false).email
    }

    public func accessToken() async throws -> String {
        let creds = try currentCredentials(reloading: false)
        guard creds.isExpiring(within: nearExpiryWindow) else {
            return creds.accessToken
        }
        return try await refreshTokens(credentials: creds)
    }

    public func forceRefresh(rejectedAccessToken: String) async throws -> String {
        let creds = try currentCredentials(reloading: true)
        if creds.accessToken != rejectedAccessToken {
            return creds.accessToken
        }
        return try await refreshTokens(credentials: creds)
    }

    @discardableResult
    public func startSignIn() async throws -> AuthCredentials {
        if let existing = inFlightSignIn {
            return try await existing.value
        }

        let task = Task { () -> AuthCredentials in
            let server = OAuthCallbackServer()
            let port = try await server.start(preferredPort: expectedPort)
            guard port == expectedPort else {
                await server.stopListening()
                throw OAuthServerError.portUnavailable(expectedPort)
            }

            let verifier = PKCE.generateCodeVerifier()
            let challenge = PKCE.generateCodeChallenge(from: verifier)
            let state = PKCE.generateState()

            var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
                URLQueryItem(name: "id_token_add_organizations", value: "true"),
            ]

            guard let authURL = components.url else {
                throw OAuthServerError.cancelled
            }

            // Open user's default browser
            _ = await MainActor.run {
                NSWorkspace.shared.open(authURL)
            }

            let code = try await server.waitForAuthorizationCode(
                expectedPath: expectedPath,
                expectedState: state,
                providerName: "Codex / ChatGPT"
            )

            // Exchange code for tokens
            let creds = try await exchangeCode(code, verifier: verifier)
            try KeychainStore.save(creds, for: "codex")
            self.cached = creds
            return creds
        }

        inFlightSignIn = task
        defer { inFlightSignIn = nil }
        return try await task.value
    }

    public func signOut() throws {
        try KeychainStore.delete(for: "codex")
        cached = nil
    }

    private func currentCredentials(reloading: Bool) throws -> AuthCredentials {
        if !reloading, let cached {
            return cached
        }
        let creds = try KeychainStore.load(for: "codex")
        cached = creds
        return creds
    }

    private func exchangeCode(_ code: String, verifier: String) async throws -> AuthCredentials {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AuthError.refreshFailed(status: status)
        }

        return try parseTokenResponse(data)
    }

    private func refreshTokens(credentials: AuthCredentials) async throws -> String {
        guard let refreshToken = credentials.refreshToken else {
            throw AuthError.refreshTokenExpired
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "refresh_token", value: refreshToken),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AuthError.refreshFailed(status: status)
        }

        let newCreds = try parseTokenResponse(data, existingRefreshToken: refreshToken)
        try KeychainStore.save(newCreds, for: "codex")
        self.cached = newCreds
        return newCreds.accessToken
    }

    private func parseTokenResponse(_ data: Data, existingRefreshToken: String? = nil) throws -> AuthCredentials {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.malformedCredentials
        }

        guard let accessToken = json["access_token"] as? String else {
            throw AuthError.malformedCredentials
        }

        let refreshToken = (json["refresh_token"] as? String) ?? existingRefreshToken
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let expiresAt = Date().addingTimeInterval(expiresIn)

        var email: String?
        var accountId: String?

        if let idToken = json["id_token"] as? String {
            let parts = idToken.split(separator: ".")
            if parts.count >= 2 {
                let payload = String(parts[1])
                var base64 = payload
                    .replacingOccurrences(of: "-", with: "+")
                    .replacingOccurrences(of: "_", with: "/")
                while base64.count % 4 != 0 {
                    base64.append("=")
                }
                if let payloadData = Data(base64Encoded: base64),
                   let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                    email = claims["email"] as? String
                    accountId = claims["sub"] as? String
                }
            }
        }

        return AuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scopes: scopes,
            accountId: accountId,
            email: email
        )
    }
}

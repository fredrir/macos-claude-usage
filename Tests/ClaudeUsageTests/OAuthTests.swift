import Foundation
import Testing

@testable import ClaudeUsage

@Suite("OAuth PKCE and Loopback Server")
struct OAuthTests {
    @Test("PKCE matches RFC 7636 test vector")
    func pkceRfcTestVector() {
        // RFC 7636 Appendix B test vector
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expectedChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

        let challenge = PKCE.generateCodeChallenge(from: verifier)
        #expect(challenge == expectedChallenge)
    }

    @Test("PKCE verifier and state generation are base64url unpadded")
    func pkceGeneration() {
        let verifier = PKCE.generateCodeVerifier()
        let state = PKCE.generateState()

        #expect(!verifier.contains("+"))
        #expect(!verifier.contains("/"))
        #expect(!verifier.contains("="))
        #expect(verifier.count >= 43)

        #expect(!state.contains("+"))
        #expect(!state.contains("/"))
        #expect(!state.contains("="))
        #expect(state.count >= 20)
    }

    @Test("OAuthCallbackServer receives authorization code over HTTP loopback")
    func loopbackCallbackSuccess() async throws {
        let server = OAuthCallbackServer()
        let port = try await server.start(preferredPort: 0)
        #expect(port > 0)

        let state = "test-state-123"
        let code = "auth-code-xyz"

        async let receivedCode = server.waitForAuthorizationCode(
            expectedPath: "/callback",
            expectedState: state,
            providerName: "Test Provider",
            timeout: 5
        )

        // Make HTTP client request
        let url = URL(string: "http://127.0.0.1:\(port)/callback?code=\(code)&state=\(state)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)

        let responseBody = String(decoding: data, as: UTF8.self)
        #expect(responseBody.contains("Signed In to Test Provider"))

        let result = try await receivedCode
        #expect(result == code)
    }

    @Test("OAuthCallbackServer rejects state mismatch")
    func loopbackStateMismatch() async throws {
        let server = OAuthCallbackServer()
        let port = try await server.start(preferredPort: 0)
        #expect(port > 0)

        let expectedState = "expected-state"
        let wrongState = "wrong-state"

        async let receivedCode = server.waitForAuthorizationCode(
            expectedPath: "/callback",
            expectedState: expectedState,
            providerName: "Test Provider",
            timeout: 5
        )

        let url = URL(string: "http://127.0.0.1:\(port)/callback?code=somecode&state=\(wrongState)")!
        let (_, response) = try await URLSession.shared.data(from: url)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200) // Error HTML returned

        do {
            _ = try await receivedCode
            Issue.record("Expected OAuthServerError.stateMismatch to be thrown")
        } catch let error as OAuthServerError {
            guard case .stateMismatch = error else {
                Issue.record("Expected .stateMismatch, got \(error)")
                return
            }
        }
    }

    @Test("Token failures report what the server actually said")
    func tokenErrorBodyIsSurfaced() {
        let anthropic = Data(#"{"error":{"type":"rate_limit_error","message":"Rate limited."}}"#.utf8)
        #expect(TokenErrorBody.describe(anthropic) == "rate_limit_error: Rate limited.")

        let oauth = Data(#"{"error":"invalid_grant","error_description":"state mismatch"}"#.utf8)
        #expect(TokenErrorBody.describe(oauth) == "invalid_grant: state mismatch")

        #expect(TokenErrorBody.describe(Data("Bad Gateway".utf8)) == "Bad Gateway")
        #expect(TokenErrorBody.describe(Data()) == nil)

        let error = AuthError.refreshFailed(status: 400, detail: "invalid_grant")
        #expect(error.errorDescription?.contains("invalid_grant") == true)
    }

    @Test("The Claude profile response yields the account email")
    func claudeProfileExtractsEmail() {
        let profile = Data(
            #"{"account":{"email":"user@example.com","full_name":"A User"}}"#.utf8
        )
        #expect(ClaudeProfile(data: profile).email == "user@example.com")

        #expect(ClaudeProfile(data: Data(#"{"account":{}}"#.utf8)).email == nil)
        #expect(ClaudeProfile(data: Data("{}".utf8)).email == nil)
        #expect(ClaudeProfile(data: Data("not json".utf8)).email == nil)
    }

    @Test("AuthCredentials encodes and decodes properly")
    func authCredentialsCodable() throws {
        let creds = AuthCredentials(
            accessToken: "test-access-token",
            refreshToken: "test-refresh-token",
            expiresAt: Date(timeIntervalSince1970: 1700000000),
            scopes: ["openid", "profile"],
            accountId: "acc-123",
            email: "user@example.com"
        )

        let data = try JSONEncoder().encode(creds)
        let decoded = try JSONDecoder().decode(AuthCredentials.self, from: data)

        #expect(decoded.accessToken == creds.accessToken)
        #expect(decoded.refreshToken == creds.refreshToken)
        #expect(decoded.accountId == creds.accountId)
        #expect(decoded.email == creds.email)
        #expect(decoded.scopes == creds.scopes)
        #expect(decoded.isExpiring(within: 60) == true)
    }

    @Test("CodexUsageClient decodes both Wham and legacy app-server payloads")
    func codexUsageClientDecode() throws {
        let whamJSON = """
        {
            "user_id": "usr_123",
            "account_id": "acc_456",
            "email": "user@example.com",
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 22.5,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 3600
                },
                "secondary_window": {
                    "used_percent": 55.0,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 86400
                }
            }
        }
        """.data(using: .utf8)!

        let whamDecoded = try CodexUsageClient.decode(whamJSON)
        #expect(whamDecoded.rateLimits?.primary?.usedPercent == 22.5)
        #expect(whamDecoded.rateLimits?.primary?.windowDurationMins == 300)
        #expect(whamDecoded.rateLimits?.secondary?.usedPercent == 55.0)
        #expect(whamDecoded.rateLimits?.secondary?.windowDurationMins == 10080)

        let legacyJSON = """
        {
            "rateLimits": {
                "limitId": "codex",
                "primary": { "usedPercent": 10, "windowDurationMins": 300 },
                "secondary": { "usedPercent": 40, "windowDurationMins": 10080 }
            }
        }
        """.data(using: .utf8)!

        let legacyDecoded = try CodexUsageClient.decode(legacyJSON)
        #expect(legacyDecoded.rateLimits?.primary?.usedPercent == 10)
        #expect(legacyDecoded.rateLimits?.secondary?.usedPercent == 40)
    }

    @Test("A sign-in that fails after the listener starts gives the callback port back")
    func failedSignInReleasesPort() async throws {
        let port: UInt16 = 45_455
        let flow = OAuthBrowserFlow(
            providerName: "Test Provider",
            authorizeURL: URL(string: "https://example.invalid/authorize")!,
            clientID: "test-client",
            scopes: ["openid"],
            redirect: .fixedPort(port, path: "/auth/callback"),
            extraQueryItems: [],
            openURL: { _ in throw OAuthServerError.browserLaunchFailed }
        )

        await #expect(throws: OAuthServerError.self) {
            _ = try await flow.authorize()
        }

        let retry = OAuthCallbackServer()
        #expect(try await retry.start(preferredPort: port) == port)
        await retry.stopListening()
    }

    @Test("An abandoned sign-in gives the callback port back")
    func abandonedSignInReleasesPort() async throws {
        let port: UInt16 = 45_456
        let flow = OAuthBrowserFlow(
            providerName: "Test Provider",
            authorizeURL: URL(string: "https://example.invalid/authorize")!,
            clientID: "test-client",
            scopes: ["openid"],
            redirect: .fixedPort(port, path: "/auth/callback"),
            extraQueryItems: [],
            openURL: { _ in }
        )

        let signIn = Task { try await flow.authorize() }
        try await waitUntilListening(on: port)
        signIn.cancel()

        do {
            _ = try await signIn.value
            Issue.record("Expected the abandoned sign-in to throw")
        } catch let error as OAuthServerError {
            guard case .cancelled = error else {
                Issue.record("Expected .cancelled, got \(error)")
                return
            }
        }

        let retry = OAuthCallbackServer()
        #expect(try await retry.start(preferredPort: port) == port)
        await retry.stopListening()
    }

    private func waitUntilListening(
        on port: UInt16,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let probe = URL(string: "http://127.0.0.1:\(port)/favicon.ico")!
        for _ in 0..<200 {
            if let (_, response) = try? await URLSession.shared.data(from: probe),
                response is HTTPURLResponse
            {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The callback server never started listening", sourceLocation: sourceLocation)
    }
}

import AppKit
import Foundation

/// Runs the browser half of an authorization-code + PKCE sign-in and always tears the
/// loopback listener down, so a failed attempt never leaves the callback port bound.
struct OAuthBrowserFlow: Sendable {
    enum Redirect: Sendable {
        case ephemeralPort(path: String)
        case fixedPort(UInt16, path: String)

        var path: String {
            switch self {
            case .ephemeralPort(let path), .fixedPort(_, let path): path
            }
        }

        var preferredPort: UInt16 {
            switch self {
            case .ephemeralPort: 0
            case .fixedPort(let port, _): port
            }
        }
    }

    struct Authorization: Sendable {
        let code: String
        let state: String
        let verifier: String
        let redirectURI: String
    }

    let providerName: String
    let authorizeURL: URL
    let clientID: String
    let scopes: [String]
    let redirect: Redirect
    var extraQueryItems: [URLQueryItem] = []
    var openURL: @Sendable (URL) async throws -> Void = { url in
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { throw OAuthServerError.browserLaunchFailed }
    }

    func authorize() async throws -> Authorization {
        let server = OAuthCallbackServer()
        let port = try await server.start(preferredPort: redirect.preferredPort)

        do {
            let authorization = try await authorize(on: server, port: port)
            await server.stopListening()
            return authorization
        } catch {
            await server.stopListening()
            throw error
        }
    }

    private func authorize(
        on server: OAuthCallbackServer,
        port: UInt16
    ) async throws -> Authorization {
        if case .fixedPort(let expected, _) = redirect, port != expected {
            throw OAuthServerError.portUnavailable(expected)
        }

        let redirectURI = "http://localhost:\(port)\(redirect.path)"
        let verifier = PKCE.generateCodeVerifier()
        let state = PKCE.generateState()

        guard var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false) else {
            throw OAuthServerError.malformedAuthorizeURL
        }
        components.queryItems =
            [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
                URLQueryItem(name: "code_challenge", value: PKCE.generateCodeChallenge(from: verifier)),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state),
            ] + extraQueryItems

        guard let authURL = components.url else {
            throw OAuthServerError.malformedAuthorizeURL
        }

        try Task.checkCancellation()
        try await openURL(authURL)

        let code = try await server.waitForAuthorizationCode(
            expectedPath: redirect.path,
            expectedState: state,
            providerName: providerName
        )
        return Authorization(code: code, state: state, verifier: verifier, redirectURI: redirectURI)
    }
}

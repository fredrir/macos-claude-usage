import Foundation

protocol ProviderAuthenticating: Sendable {
    func isSignedIn() async -> Bool
    func accountLabel() async -> String?
    func signIn() async throws
    func signOut() async throws
    func cancelSignIn() async
}

struct ClaudeAuthentication: ProviderAuthenticating {
    func isSignedIn() async -> Bool { await AuthManager.shared.isSignedIn }
    func accountLabel() async -> String? { await AuthManager.shared.accountLabel() }
    func signIn() async throws { try await AuthManager.shared.startSignIn() }
    func signOut() async throws { try await AuthManager.shared.signOut() }
    func cancelSignIn() async { await AuthManager.shared.cancelSignIn() }
}

struct CodexAuthentication: ProviderAuthenticating {
    func isSignedIn() async -> Bool { await CodexAuthManager.shared.isSignedIn }
    func accountLabel() async -> String? { await CodexAuthManager.shared.userEmail }
    func signIn() async throws { try await CodexAuthManager.shared.startSignIn() }
    func signOut() async throws { try await CodexAuthManager.shared.signOut() }
    func cancelSignIn() async { await CodexAuthManager.shared.cancelSignIn() }
}

/// Fixed sign-in state for previews, fixtures and tests.
struct FixedAuthentication: ProviderAuthenticating {
    var signedIn = false
    var label: String?

    func isSignedIn() async -> Bool { signedIn }
    func accountLabel() async -> String? { label }
    func signIn() async throws {}
    func signOut() async throws {}
    func cancelSignIn() async {}
}

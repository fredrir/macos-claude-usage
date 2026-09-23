import Foundation
import Testing
import UsageCore

@testable import ClaudeUsage

@Suite("Account sessions")
@MainActor
struct AccountSessionTests {
    private let now = Date(timeIntervalSinceReferenceDate: 40_000)

    @Test("Signing out clears the account's usage and says so")
    func signOutClearsUsageAndReportsBack() async throws {
        let auth = SpyAuthentication(signedIn: true)
        let store = makeStore(claudeAuth: auth)

        #expect(!store.buckets.isEmpty)

        store.signOutClaude()
        #expect(store.isSigningOutClaude)

        try await settle { !store.isSigningOutClaude }

        #expect(!store.claudeIsSignedIn)
        #expect(store.buckets.isEmpty)
        #expect(store.lastUpdated == nil)
        #expect(store.status == .signedOut)
        #expect(store.claudeAuthFeedback == .init(kind: .info, message: "Signed out."))
        #expect(await auth.signOutCount == 1)
    }

    @Test("A signed-out provider shows no usage error, only the signed-out state")
    func signedOutProviderHasNoWarning() async throws {
        let store = makeStore(claudeAuth: SpyAuthentication(signedIn: true))

        store.signOutClaude()
        try await settle { !store.isSigningOutClaude }

        #expect(store.statusMessage == nil)
        #expect(!store.statusIsWarning)
    }

    @Test("A failed sign-out surfaces the reason instead of failing silently")
    func failedSignOutIsReported() async throws {
        let store = makeStore(claudeAuth: RefusingAuthentication())

        store.signOutClaude()
        try await settle { !store.isSigningOutClaude }

        #expect(store.claudeAuthFeedback?.kind == .failure)
        #expect(store.claudeAuthFeedback?.message.contains("Sign-out failed") == true)
    }

    @Test("Cancelling a sign-in is reported as a cancellation, not a failure")
    func cancelledSignInIsNotAnError() async throws {
        let store = makeStore(claudeAuth: CancellingAuthentication())

        store.signInClaude()
        try await settle { !store.isSigningInClaude }

        #expect(store.claudeAuthFeedback == .init(kind: .info, message: "Sign-in cancelled."))
        #expect(!store.claudeIsSignedIn)
    }

    @Test("A signed-in provider exposes the account label for the settings row")
    func signedInProviderExposesLabel() async {
        let store = UsageStore(
            fixture: [],
            lastUpdated: now,
            claudeAuth: FixedAuthentication(signedIn: true, label: "claude@example.com"),
            codexAuth: FixedAuthentication(signedIn: true, label: "codex@example.com"),
            clock: FixedAccountDateProvider(now: now)
        )

        await store.refreshAuthState()

        #expect(store.claudeEmail == "claude@example.com")
        #expect(store.codexEmail == "codex@example.com")
    }

    @Test("Signed-out providers are never fetched")
    func signedOutProvidersAreNotFetched() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let claudeClient = CountingUsageClient()
        let codexClient = CountingCodexClient()
        let store = UsageStore(
            repository: UsageRepository(
                client: claudeClient,
                cacheURL: directory.appendingPathComponent("usage.json"),
                pollingStateURL: directory.appendingPathComponent("polling.json"),
                clock: FixedAccountDateProvider(now: now)
            ),
            codexRepository: CodexUsageRepository(
                client: codexClient,
                cacheURL: directory.appendingPathComponent("codex-usage.json"),
                pollingStateURL: directory.appendingPathComponent("codex-polling.json"),
                clock: FixedAccountDateProvider(now: now)
            ),
            claudeAuth: FixedAuthentication(signedIn: false),
            codexAuth: FixedAuthentication(signedIn: false),
            clock: FixedAccountDateProvider(now: now)
        )

        await store.performRefresh(manual: true)

        #expect(await claudeClient.requestCount == 0)
        #expect(await codexClient.requestCount == 0)
        #expect(store.status == .signedOut)
        #expect(store.codexStatus == .signedOut)
    }

    private func makeStore(claudeAuth: any ProviderAuthenticating) -> UsageStore {
        UsageStore(
            fixture: [
                UsageBucket(
                    id: "claude-session",
                    title: "Current session",
                    utilization: 20,
                    resetsAt: now.addingTimeInterval(3_600),
                    severity: nil,
                    role: .session
                )
            ],
            lastUpdated: now,
            claudeAuth: claudeAuth,
            codexAuth: FixedAuthentication(signedIn: false),
            clock: FixedAccountDateProvider(now: now)
        )
    }

    private func settle(
        until condition: @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The store never settled", sourceLocation: sourceLocation)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

private actor SpyAuthentication: ProviderAuthenticating {
    private var signedIn: Bool
    private(set) var signOutCount = 0

    init(signedIn: Bool) {
        self.signedIn = signedIn
    }

    func isSignedIn() async -> Bool { signedIn }
    func accountLabel() async -> String? { nil }
    func signIn() async throws { signedIn = true }
    func signOut() async throws {
        signedIn = false
        signOutCount += 1
    }
    func cancelSignIn() async {}
}

private struct RefusingAuthentication: ProviderAuthenticating {
    func isSignedIn() async -> Bool { true }
    func accountLabel() async -> String? { nil }
    func signIn() async throws { throw KeychainError.osStatus(errSecAuthFailed) }
    func signOut() async throws { throw KeychainError.osStatus(errSecAuthFailed) }
    func cancelSignIn() async {}
}

private struct CancellingAuthentication: ProviderAuthenticating {
    func isSignedIn() async -> Bool { false }
    func accountLabel() async -> String? { nil }
    func signIn() async throws { throw OAuthServerError.cancelled }
    func signOut() async throws {}
    func cancelSignIn() async {}
}

private actor CountingUsageClient: UsageFetching {
    private(set) var requestCount = 0

    func fetch() async throws -> UsageFetchResult {
        requestCount += 1
        let raw = Data(#"{ "five_hour": { "utilization": 1 } }"#.utf8)
        return UsageFetchResult(
            response: try JSONDecoder().decode(UsageResponseDTO.self, from: raw),
            raw: raw
        )
    }
}

private actor CountingCodexClient: CodexUsageFetching {
    private(set) var requestCount = 0

    func fetch() async throws -> CodexUsageFetchResult {
        requestCount += 1
        let raw = Data(#"{ "rateLimits": { "primary": { "usedPercent": 1 } } }"#.utf8)
        return CodexUsageFetchResult(response: try CodexUsageClient.decode(raw), raw: raw)
    }
}

private struct FixedAccountDateProvider: DateProvider {
    let now: Date
}

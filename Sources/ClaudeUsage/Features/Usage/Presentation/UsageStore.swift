import Combine
import Foundation
import UsageCore

@MainActor
final class UsageStore: ObservableObject {
    enum Status: Equatable {
        case loading
        case signedOut
        case ok
        case throttled(until: Date)
        case rateLimited(until: Date)
        case authExpired(String)
        case failed(String)
    }

    struct AuthFeedback: Equatable {
        enum Kind: Equatable {
            case info
            case failure
        }

        let kind: Kind
        let message: String

        var failure: String? { kind == .failure ? message : nil }
    }

    private static let minimumSpacing: TimeInterval = 15 * 60
    static let stalenessThreshold: TimeInterval = 60 * 60

    @Published private(set) var buckets: [UsageBucket] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var status: Status = .loading
    @Published private(set) var codexBuckets: [UsageBucket] = []
    @Published private(set) var codexLastUpdated: Date?
    @Published private(set) var codexStatus: Status = .loading
    @Published var pollInterval: TimeInterval {
        didSet { UserDefaults.standard.set(pollInterval, forKey: "pollInterval") }
    }
    @Published private(set) var claudeIsSignedIn: Bool = false
    @Published private(set) var codexIsSignedIn: Bool = false
    @Published private(set) var claudeEmail: String?
    @Published private(set) var codexEmail: String?
    @Published private(set) var isSigningInClaude: Bool = false
    @Published private(set) var isSigningInCodex: Bool = false
    @Published private(set) var isSigningOutClaude: Bool = false
    @Published private(set) var isSigningOutCodex: Bool = false
    @Published private(set) var claudeAuthFeedback: AuthFeedback?
    @Published private(set) var codexAuthFeedback: AuthFeedback?

    private let repository: UsageRepository?
    private let codexRepository: CodexUsageRepository?
    private let claudeAuth: any ProviderAuthenticating
    private let codexAuth: any ProviderAuthenticating
    private let clock: any DateProvider
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?

    var now: Date { clock.now }

    var isStale: Bool {
        guard let lastUpdated else { return true }
        return now.timeIntervalSince(lastUpdated) > Self.stalenessThreshold
    }

    init(
        repository: UsageRepository = UsageRepository(),
        codexRepository: CodexUsageRepository = CodexUsageRepository(),
        claudeAuth: any ProviderAuthenticating = ClaudeAuthentication(),
        codexAuth: any ProviderAuthenticating = CodexAuthentication(),
        clock: any DateProvider = SystemDateProvider()
    ) {
        self.repository = repository
        self.codexRepository = codexRepository
        self.claudeAuth = claudeAuth
        self.codexAuth = codexAuth
        self.clock = clock
        let stored = UserDefaults.standard.double(forKey: "pollInterval")
        pollInterval = stored > 0 ? stored : 30 * 60
    }

    init(
        fixture buckets: [UsageBucket],
        codexBuckets: [UsageBucket] = [],
        lastUpdated: Date,
        codexLastUpdated: Date? = nil,
        status: Status = .ok,
        codexStatus: Status = .ok,
        pollInterval: TimeInterval = 30 * 60,
        claudeAuth: any ProviderAuthenticating = FixedAuthentication(signedIn: true),
        codexAuth: any ProviderAuthenticating = FixedAuthentication(signedIn: true),
        clock: any DateProvider
    ) {
        repository = nil
        codexRepository = nil
        self.claudeAuth = claudeAuth
        self.codexAuth = codexAuth
        self.clock = clock
        self.pollInterval = pollInterval
        self.buckets = buckets
        self.lastUpdated = lastUpdated
        self.status = status
        self.codexBuckets = codexBuckets
        self.codexLastUpdated = codexLastUpdated ?? (codexBuckets.isEmpty ? nil : lastUpdated)
        self.codexStatus = codexStatus
    }

    func start() {
        guard timer == nil, repository != nil || codexRepository != nil else { return }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            await loadCachedSnapshots()
            await performRefresh(manual: false)
            refreshTask = nil
        }

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 10
    }

    func refreshIfStale() {
        let threshold = max(Self.minimumSpacing, pollInterval / 2)
        if claudeNeedsRefresh(threshold: threshold) || codexNeedsRefresh(threshold: threshold) {
            scheduleRefresh(manual: false)
        }
    }

    func refreshManually() {
        scheduleRefresh(manual: true)
    }

    func refreshAuthState() async {
        let claudeSignedIn = await claudeAuth.isSignedIn()
        let codexSignedIn = await codexAuth.isSignedIn()
        claudeEmail = await claudeAuth.accountLabel()
        codexEmail = await codexAuth.accountLabel()
        claudeIsSignedIn = claudeSignedIn
        codexIsSignedIn = codexSignedIn

        if !claudeSignedIn { clearClaude() }
        if !codexSignedIn { clearCodex() }
    }

    func signInClaude() {
        guard !isSigningInClaude else { return }
        isSigningInClaude = true
        claudeAuthFeedback = nil

        Task {
            defer { isSigningInClaude = false }
            do {
                try await claudeAuth.signIn()
                await repository?.allowImmediateRefresh()
                await refreshAuthState()
                Log.write("claude sign-in: succeeded")
                refreshManually()
            } catch {
                claudeAuthFeedback = Self.signInFeedback(for: error)
                Log.write("claude sign-in: failed \(error.localizedDescription)")
            }
        }
    }

    func signOutClaude() {
        guard !isSigningOutClaude else { return }
        isSigningOutClaude = true
        claudeAuthFeedback = nil

        Task {
            defer { isSigningOutClaude = false }
            do {
                try await claudeAuth.signOut()
                await repository?.clearCachedUsage()
                await refreshAuthState()
                claudeAuthFeedback = AuthFeedback(kind: .info, message: "Signed out.")
                Log.write("claude sign-out: succeeded")
            } catch {
                claudeAuthFeedback = Self.signOutFeedback(for: error)
                Log.write("claude sign-out: failed \(error.localizedDescription)")
            }
        }
    }

    func cancelClaudeSignIn() {
        guard isSigningInClaude else { return }
        Task { await claudeAuth.cancelSignIn() }
    }

    func signInCodex() {
        guard !isSigningInCodex else { return }
        isSigningInCodex = true
        codexAuthFeedback = nil

        Task {
            defer { isSigningInCodex = false }
            do {
                try await codexAuth.signIn()
                await codexRepository?.allowImmediateRefresh()
                await refreshAuthState()
                Log.write("codex sign-in: succeeded")
                refreshManually()
            } catch {
                codexAuthFeedback = Self.signInFeedback(for: error)
                Log.write("codex sign-in: failed \(error.localizedDescription)")
            }
        }
    }

    func signOutCodex() {
        guard !isSigningOutCodex else { return }
        isSigningOutCodex = true
        codexAuthFeedback = nil

        Task {
            defer { isSigningOutCodex = false }
            do {
                try await codexAuth.signOut()
                await codexRepository?.clearCachedUsage()
                await refreshAuthState()
                codexAuthFeedback = AuthFeedback(kind: .info, message: "Signed out.")
                Log.write("codex sign-out: succeeded")
            } catch {
                codexAuthFeedback = Self.signOutFeedback(for: error)
                Log.write("codex sign-out: failed \(error.localizedDescription)")
            }
        }
    }

    func cancelCodexSignIn() {
        guard isSigningInCodex else { return }
        Task { await codexAuth.cancelSignIn() }
    }

    private static func signInFeedback(for error: Error) -> AuthFeedback {
        if error is CancellationError { return AuthFeedback(kind: .info, message: "Sign-in cancelled.") }
        if case .cancelled? = error as? OAuthServerError {
            return AuthFeedback(kind: .info, message: "Sign-in cancelled.")
        }
        return AuthFeedback(kind: .failure, message: "Sign-in failed: \(error.localizedDescription)")
    }

    private static func signOutFeedback(for error: Error) -> AuthFeedback {
        AuthFeedback(kind: .failure, message: "Sign-out failed: \(error.localizedDescription)")
    }

    private func clearClaude() {
        buckets = []
        lastUpdated = nil
        claudeEmail = nil
        if status != .signedOut { status = .signedOut }
    }

    private func clearCodex() {
        codexBuckets = []
        codexLastUpdated = nil
        codexEmail = nil
        if codexStatus != .signedOut { codexStatus = .signedOut }
    }

    private func tick() {
        objectWillChange.send()

        if claudeNeedsRefresh(threshold: pollInterval) || codexNeedsRefresh(threshold: pollInterval) {
            scheduleRefresh(manual: false)
        }
    }

    private func scheduleRefresh(manual: Bool) {
        guard refreshTask == nil, repository != nil || codexRepository != nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await performRefresh(manual: manual)
            refreshTask = nil
        }
    }

    private func loadCachedSnapshots() async {
        await refreshAuthState()
        async let claudeSnapshot = repository?.loadCachedSnapshot()
        async let codexSnapshot = codexRepository?.loadCachedSnapshot()

        let (cachedClaude, cachedCodex) = await (claudeSnapshot, codexSnapshot)
        if claudeIsSignedIn, let cachedClaude { apply(cachedClaude) }
        if codexIsSignedIn, let cachedCodex { applyCodex(cachedCodex) }
    }

    func performRefresh(manual: Bool) async {
        enum ProviderResult: Sendable {
            case claude(UsageRefreshOutcome)
            case codex(UsageRefreshOutcome)
        }

        await refreshAuthState()

        let reason = manual ? "manual" : "scheduled"
        await withTaskGroup(of: ProviderResult.self) { group in
            if let repository, claudeIsSignedIn {
                Log.write("fetch: requesting (\(reason))")
                group.addTask { .claude(await repository.refresh()) }
            }
            if let codexRepository, codexIsSignedIn {
                Log.write("codex fetch: requesting (\(reason))")
                group.addTask { .codex(await codexRepository.refresh()) }
            }

            for await result in group {
                switch result {
                case .claude(let outcome):
                    applyClaude(outcome)
                case .codex(let outcome):
                    applyCodex(outcome)
                }
            }
        }
    }

    private func applyClaude(_ outcome: UsageRefreshOutcome) {
        switch outcome {
        case .updated(let snapshot):
            apply(snapshot)
            status = .ok
            Log.write(
                "fetch: 200, \(buckets.count) window(s)"
                    + buckets.map {
                        "\($0.title) \(Int($0.remaining.rounded()))% left"
                    }.joined(separator: ", ")
            )

        case .deferred(let until, let restriction):
            switch restriction {
            case .serverRateLimit:
                status = .rateLimited(until: until)
            case .authentication:
                if case .authExpired = status {
                } else {
                    status = .authExpired("Sign-in unavailable — retrying shortly.")
                }
            case .errorBackoff:
                if case .failed = status {
                } else {
                    status = .failed("Temporary error — waiting before retrying.")
                }
            case .minimumSpacing:
                status = .throttled(until: until)
            }
            Log.write("fetch: deferred until \(Self.clockText(until)) (\(restriction.rawValue))")

        case .authenticationFailed(let message):
            status = .authExpired(message)
            Log.write("fetch: authentication failed \(message)")

        case .failed(let message):
            status = .failed(message)
            Log.write("fetch: failed \(message)")
        }
    }

    private func applyCodex(_ outcome: UsageRefreshOutcome) {
        switch outcome {
        case .updated(let snapshot):
            applyCodex(snapshot)
            codexStatus = .ok
            Log.write(
                "codex fetch: success, \(codexBuckets.count) window(s)"
                    + codexBuckets.map {
                        "\($0.title) \(Int($0.remaining.rounded()))% left"
                    }.joined(separator: ", ")
            )

        case .deferred(let until, let restriction):
            switch restriction {
            case .serverRateLimit:
                codexStatus = .rateLimited(until: until)
            case .authentication:
                if case .authExpired = codexStatus {
                } else {
                    codexStatus = .authExpired("Codex sign-in unavailable — retrying later.")
                }
            case .errorBackoff:
                if case .failed = codexStatus {
                } else {
                    codexStatus = .failed("Codex temporarily unavailable — waiting before retrying.")
                }
            case .minimumSpacing:
                codexStatus = .throttled(until: until)
            }
            Log.write("codex fetch: deferred until \(Self.clockText(until)) (\(restriction.rawValue))")

        case .authenticationFailed(let message):
            codexStatus = .authExpired(message)
            Log.write("codex fetch: authentication failed \(message)")

        case .failed(let message):
            codexStatus = .failed(message)
            Log.write("codex fetch: failed \(message)")
        }
    }

    private func apply(_ snapshot: UsageSnapshot) {
        buckets = snapshot.buckets
        lastUpdated = snapshot.fetchedAt
    }

    private func applyCodex(_ snapshot: UsageSnapshot) {
        codexBuckets = snapshot.buckets
        codexLastUpdated = snapshot.fetchedAt
    }

    private func claudeNeedsRefresh(threshold: TimeInterval) -> Bool {
        claudeIsSignedIn && needsRefresh(lastUpdated: lastUpdated, threshold: threshold)
    }

    private func codexNeedsRefresh(threshold: TimeInterval) -> Bool {
        codexIsSignedIn && needsRefresh(lastUpdated: codexLastUpdated, threshold: threshold)
    }

    private func needsRefresh(lastUpdated: Date?, threshold: TimeInterval) -> Bool {
        guard let lastUpdated else { return true }
        return now.timeIntervalSince(lastUpdated) >= threshold
    }

    private static func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

extension UsageStore {
    var statusMessage: String? {
        statusMessage(for: status, lastUpdated: lastUpdated)
    }

    var codexStatusMessage: String? {
        statusMessage(for: codexStatus, lastUpdated: codexLastUpdated)
    }

    var codexIsStale: Bool {
        isStale(lastUpdated: codexLastUpdated)
    }

    var codexStatusIcon: String {
        statusIcon(for: codexStatus, isStale: codexIsStale)
    }

    var codexStatusIsWarning: Bool {
        statusIsWarning(for: codexStatus, isStale: codexIsStale)
    }

    private func statusMessage(for status: Status, lastUpdated: Date?) -> String? {
        switch status {
        case .loading:
            return lastUpdated == nil ? "Fetching…" : nil
        case .ok, .throttled, .signedOut:
            return nil
        case .rateLimited(let until):
            guard let minutes = minutesUntil(until) else { return "Retrying…" }
            return "Rate limited — retrying in \(minutes)m"
        case .authExpired(let message), .failed(let message):
            return message
        }
    }

    var statusIcon: String {
        statusIcon(for: status, isStale: isStale)
    }

    private func statusIcon(for status: Status, isStale: Bool) -> String {
        switch status {
        case .ok, .loading, .throttled: isStale ? "clock" : "checkmark.circle"
        case .signedOut: "person.crop.circle.badge.xmark"
        case .rateLimited: "hourglass"
        case .authExpired: "key"
        case .failed: "exclamationmark.triangle"
        }
    }

    var statusIsWarning: Bool {
        statusIsWarning(for: status, isStale: isStale)
    }

    private func statusIsWarning(for status: Status, isStale: Bool) -> Bool {
        switch status {
        case .signedOut: false
        case .ok, .loading, .throttled: isStale
        case .rateLimited, .authExpired, .failed: true
        }
    }

    private func minutesUntil(_ date: Date) -> Int? {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        return max(1, Int((seconds / 60).rounded(.up)))
    }

    private func isStale(lastUpdated: Date?) -> Bool {
        guard let lastUpdated else { return true }
        return now.timeIntervalSince(lastUpdated) > Self.stalenessThreshold
    }
}

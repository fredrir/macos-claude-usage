import Combine
import Foundation
import UsageCore

@MainActor
final class UsageStore: ObservableObject {
    enum Status: Equatable {
        case loading
        case ok
        case throttled(until: Date)
        case rateLimited(until: Date)
        case authExpired(String)
        case failed(String)
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

    private let repository: UsageRepository?
    private let codexRepository: CodexUsageRepository?
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
        clock: any DateProvider = SystemDateProvider()
    ) {
        self.repository = repository
        self.codexRepository = codexRepository
        self.clock = clock
        let stored = UserDefaults.standard.double(forKey: "pollInterval")
        pollInterval = stored > 0 ? stored : 30 * 60
    }

    /// Fixed contents and no networking or timers for deterministic UI rendering.
    init(
        fixture buckets: [UsageBucket],
        codexBuckets: [UsageBucket] = [],
        lastUpdated: Date,
        codexLastUpdated: Date? = nil,
        status: Status = .ok,
        codexStatus: Status = .ok,
        pollInterval: TimeInterval = 30 * 60,
        clock: any DateProvider
    ) {
        repository = nil
        codexRepository = nil
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

    /// Opening the dropdown may top up old data, but the repository remains the authority on
    /// persisted spacing and server penalties.
    func refreshIfStale() {
        let threshold = max(Self.minimumSpacing, pollInterval / 2)
        if needsRefresh(lastUpdated: lastUpdated, threshold: threshold)
            || needsRefresh(lastUpdated: codexLastUpdated, threshold: threshold)
        {
            scheduleRefresh(manual: false)
        }
    }

    func refreshManually() {
        scheduleRefresh(manual: true)
    }

    private func tick() {
        // Reset and retry countdowns are derived values, so notify even without new usage data.
        objectWillChange.send()

        if needsRefresh(lastUpdated: lastUpdated, threshold: pollInterval)
            || needsRefresh(lastUpdated: codexLastUpdated, threshold: pollInterval)
        {
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
        async let claudeSnapshot = repository?.loadCachedSnapshot()
        async let codexSnapshot = codexRepository?.loadCachedSnapshot()

        let (cachedClaude, cachedCodex) = await (claudeSnapshot, codexSnapshot)
        if let cachedClaude { apply(cachedClaude) }
        if let cachedCodex { applyCodex(cachedCodex) }
    }

    /// Both providers fetch concurrently and each result is applied as soon as it completes.
    private func performRefresh(manual: Bool) async {
        enum ProviderResult: Sendable {
            case claude(UsageRefreshOutcome)
            case codex(UsageRefreshOutcome)
        }

        let reason = manual ? "manual" : "scheduled"
        await withTaskGroup(of: ProviderResult.self) { group in
            if let repository {
                Log.write("fetch: requesting (\(reason))")
                group.addTask { .claude(await repository.refresh()) }
            }
            if let codexRepository {
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
                "fetch: 200, \(buckets.count) window(s) — "
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
            Log.write("fetch: authentication failed — \(message)")

        case .failed(let message):
            status = .failed(message)
            Log.write("fetch: failed — \(message)")
        }
    }

    private func applyCodex(_ outcome: UsageRefreshOutcome) {
        switch outcome {
        case .updated(let snapshot):
            applyCodex(snapshot)
            codexStatus = .ok
            Log.write(
                "codex fetch: success, \(codexBuckets.count) window(s) — "
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
            Log.write("codex fetch: authentication failed — \(message)")

        case .failed(let message):
            codexStatus = .failed(message)
            Log.write("codex fetch: failed — \(message)")
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
        case .ok, .throttled:
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

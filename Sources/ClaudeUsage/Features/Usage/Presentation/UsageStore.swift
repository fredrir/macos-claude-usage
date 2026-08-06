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
    @Published var pollInterval: TimeInterval {
        didSet { UserDefaults.standard.set(pollInterval, forKey: "pollInterval") }
    }

    private let repository: UsageRepository?
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
        clock: any DateProvider = SystemDateProvider()
    ) {
        self.repository = repository
        self.clock = clock
        let stored = UserDefaults.standard.double(forKey: "pollInterval")
        pollInterval = stored > 0 ? stored : 30 * 60
    }

    /// Fixed contents and no networking or timers for deterministic UI rendering.
    init(
        fixture buckets: [UsageBucket],
        lastUpdated: Date,
        status: Status = .ok,
        pollInterval: TimeInterval = 30 * 60,
        clock: any DateProvider
    ) {
        repository = nil
        self.clock = clock
        self.pollInterval = pollInterval
        self.buckets = buckets
        self.lastUpdated = lastUpdated
        self.status = status
    }

    func start() {
        guard timer == nil, let repository else { return }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            if let cached = await repository.loadCachedSnapshot() {
                apply(cached)
            }
            await performRefresh(using: repository, manual: false)
            refreshTask = nil
        }

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 10
    }

    /// Opening the popover may top up old data, but the repository remains the authority on
    /// persisted spacing and server penalties.
    func refreshIfStale() {
        let threshold = max(Self.minimumSpacing, pollInterval / 2)
        guard let lastUpdated else {
            scheduleRefresh(manual: false)
            return
        }
        if now.timeIntervalSince(lastUpdated) >= threshold {
            scheduleRefresh(manual: false)
        }
    }

    func refreshManually() {
        scheduleRefresh(manual: true)
    }

    private func tick() {
        // Reset and retry countdowns are derived values, so notify even without new usage data.
        objectWillChange.send()

        guard let lastUpdated else {
            scheduleRefresh(manual: false)
            return
        }
        if now.timeIntervalSince(lastUpdated) >= pollInterval {
            scheduleRefresh(manual: false)
        }
    }

    private func scheduleRefresh(manual: Bool) {
        guard refreshTask == nil, let repository else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await performRefresh(using: repository, manual: manual)
            refreshTask = nil
        }
    }

    private func performRefresh(using repository: UsageRepository, manual: Bool) async {
        status = .loading
        Log.write("fetch: requesting (\(manual ? "manual" : "scheduled"))")

        switch await repository.refresh() {
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
                status = .authExpired("Sign-in unavailable — retrying shortly.")
            case .errorBackoff:
                status = .failed("Temporary error — waiting before retrying.")
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

    private func apply(_ snapshot: UsageSnapshot) {
        buckets = snapshot.buckets
        lastUpdated = snapshot.fetchedAt
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
        switch status {
        case .loading:
            return lastUpdated == nil ? "Fetching…" : updatedText
        case .ok:
            return updatedText
        case .throttled(let until):
            guard let minutes = minutesUntil(until) else { return updatedText }
            let suffix = updatedText.map { "\($0) · " } ?? ""
            return "\(suffix)next check in \(minutes)m"
        case .rateLimited(let until):
            let suffix = updatedText.map { " · \($0)" } ?? ""
            guard let minutes = minutesUntil(until) else { return "Retrying…\(suffix)" }
            return "Rate limited — retrying in \(minutes)m\(suffix)"
        case .authExpired(let message), .failed(let message):
            return message
        }
    }

    var statusIcon: String {
        switch status {
        case .ok, .loading, .throttled: isStale ? "clock" : "checkmark.circle"
        case .rateLimited: "hourglass"
        case .authExpired: "key"
        case .failed: "exclamationmark.triangle"
        }
    }

    var statusIsWarning: Bool {
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

    private var updatedText: String? {
        guard let lastUpdated else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "Updated \(formatter.string(from: lastUpdated))"
    }
}

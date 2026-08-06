import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    enum Status: Equatable {
        case loading
        case ok
        /// Our own minimum spacing between calls — nothing is wrong.
        case throttled(until: Date)
        /// The server answered 429 and told us to wait.
        case rateLimited(until: Date)
        case authExpired(String)
        case failed(String)
    }

    /// The endpoint answered a 429 with `retry-after: 654`, and Claude Code itself caches a
    /// successful response for a full hour. Never ask more often than this.
    private static let minimumSpacing: TimeInterval = 600
    /// Anything older than this is shown dimmed.
    static let stalenessThreshold: TimeInterval = 3600

    @Published private(set) var buckets: [Bucket] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var status: Status = .loading
    @Published var pollInterval: TimeInterval {
        didSet { UserDefaults.standard.set(pollInterval, forKey: "pollInterval") }
    }

    private var isFetching = false
    private var nextAllowedFetch: Date?
    /// Set only by a server 429, so a penalty can be reported differently from routine spacing.
    private var rateLimitedUntil: Date?
    private var errorBackoff: TimeInterval = 60
    private var timer: Timer?

    var isStale: Bool {
        guard let lastUpdated else { return true }
        return Date().timeIntervalSince(lastUpdated) > Self.stalenessThreshold
    }

    init() {
        let stored = UserDefaults.standard.double(forKey: "pollInterval")
        pollInterval = stored > 0 ? stored : 900
    }

    func start() {
        loadCache()
        Task { await refresh() }

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 10
    }

    /// Called when the dropdown opens: top up only if the data has aged past half the poll
    /// interval, so repeatedly opening the menu cannot burn through the rate limit.
    func refreshIfStale() {
        let threshold = max(Self.minimumSpacing, pollInterval / 2)
        guard let lastUpdated else {
            Task { await refresh() }
            return
        }
        if Date().timeIntervalSince(lastUpdated) >= threshold {
            Task { await refresh() }
        }
    }

    func refreshManually() {
        Task { await refresh(manual: true) }
    }

    private func tick() {
        // Reset countdowns, the rate-limit countdown and the staleness dimming are all derived
        // from the current time, so republish on every tick even when no fetch is due.
        objectWillChange.send()

        guard let lastUpdated else {
            Task { await refresh() }
            return
        }
        if Date().timeIntervalSince(lastUpdated) >= pollInterval {
            Task { await refresh() }
        }
    }

    private func refresh(manual: Bool = false) async {
        guard !isFetching else { return }

        let now = Date()
        if let nextAllowedFetch, now < nextAllowedFetch {
            if let rateLimitedUntil, now < rateLimitedUntil {
                // A server penalty is worth showing unprompted — otherwise a launch into a
                // rate-limited window would sit on "Fetching…" indefinitely.
                status = .rateLimited(until: rateLimitedUntil)
            } else if manual {
                status = .throttled(until: nextAllowedFetch)
            }
            return
        }

        isFetching = true
        defer { isFetching = false }

        do {
            let (response, raw) = try await UsageAPI.fetch()
            apply(response: response, fetchedAt: Date())
            saveCache(raw: raw, fetchedAt: Date())
            status = .ok
            errorBackoff = 60
            rateLimitedUntil = nil
            nextAllowedFetch = Date().addingTimeInterval(Self.minimumSpacing)
        } catch let error as UsageAPIError {
            switch error {
            case .rateLimited(let retryAfter):
                let until = Date().addingTimeInterval(retryAfter)
                nextAllowedFetch = until
                rateLimitedUntil = until
                status = .rateLimited(until: until)
            case .unauthorized:
                status = .authExpired("Sign-in expired — run `claude` once to refresh.")
                nextAllowedFetch = Date().addingTimeInterval(120)
            case .http:
                failed(error.localizedDescription)
            }
        } catch let error as AuthError {
            status = .authExpired(error.localizedDescription)
            nextAllowedFetch = Date().addingTimeInterval(120)
        } catch let error as KeychainError {
            status = .authExpired(error.localizedDescription)
            nextAllowedFetch = Date().addingTimeInterval(120)
        } catch {
            failed(error.localizedDescription)
        }
    }

    private func failed(_ message: String) {
        status = .failed(message)
        nextAllowedFetch = Date().addingTimeInterval(errorBackoff)
        errorBackoff = min(errorBackoff * 2, 3600)
    }

    private func apply(response: UsageResponse, fetchedAt: Date) {
        buckets = UsageModel.buckets(from: response)
        lastUpdated = fetchedAt
    }

    // MARK: - Disk cache

    private struct CachedPayload: Codable {
        let fetchedAt: Date
        let raw: Data
    }

    private func saveCache(raw: Data, fetchedAt: Date) {
        let payload = CachedPayload(fetchedAt: fetchedAt, raw: raw)
        guard let encoded = try? JSONEncoder().encode(payload) else { return }
        try? encoded.write(to: AppPaths.cachedPayload, options: .atomic)
    }

    /// Paints the last known numbers immediately at launch so the menu bar is never blank.
    private func loadCache() {
        guard
            let data = try? Data(contentsOf: AppPaths.cachedPayload),
            let payload = try? JSONDecoder().decode(CachedPayload.self, from: data),
            let response = try? JSONDecoder().decode(UsageResponse.self, from: payload.raw)
        else { return }

        apply(response: response, fetchedAt: payload.fetchedAt)
    }
}

import Foundation
import UsageCore

enum UsageRefreshOutcome: Sendable {
    case updated(UsageSnapshot)
    case deferred(until: Date, restriction: PollingRestriction)
    case authenticationFailed(String)
    case failed(String)
}

/// Owns request scheduling, disk persistence, and DTO-to-domain mapping.
///
/// The actor is intentionally independent of SwiftUI. Recording and saving an attempt before
/// awaiting the network is the key invariant: quitting and reopening the app cannot bypass the
/// endpoint's minimum spacing or a persisted server penalty.
actor UsageRepository {
    private struct CachedPayload: Codable, Sendable {
        let fetchedAt: Date
        let raw: Data
    }

    private let client: any UsageFetching
    private let cacheURL: URL
    private let pollingStateURL: URL
    private let policy: PollingPolicy
    private let clock: any DateProvider
    private let mapper: UsageResponseMapper

    private var pollingState = PollingState()
    private var hasLoadedPollingState = false

    init(
        client: any UsageFetching = AnthropicUsageClient(),
        cacheURL: URL = AppPaths.cachedPayload,
        pollingStateURL: URL = AppPaths.pollingState,
        policy: PollingPolicy = PollingPolicy(),
        clock: any DateProvider = SystemDateProvider(),
        mapper: UsageResponseMapper = UsageResponseMapper()
    ) {
        self.client = client
        self.cacheURL = cacheURL
        self.pollingStateURL = pollingStateURL
        self.policy = policy
        self.clock = clock
        self.mapper = mapper
    }

    /// Returns the last good response without making a request. An old cache is also used to
    /// seed polling state when upgrading from versions that did not persist scheduling data.
    func loadCachedSnapshot() -> UsageSnapshot? {
        loadPollingStateIfNeeded()

        guard
            let data = try? Data(contentsOf: cacheURL),
            let payload = try? JSONDecoder().decode(CachedPayload.self, from: data),
            let response = try? JSONDecoder().decode(UsageResponseDTO.self, from: payload.raw)
        else {
            return nil
        }

        if pollingState.lastAttemptAt == nil, pollingState.nextAllowedAttemptAt == nil {
            pollingState.lastSuccessAt = payload.fetchedAt
            pollingState.nextAllowedAttemptAt = payload.fetchedAt.addingTimeInterval(
                policy.minimumSpacing
            )
            pollingState.restriction = .minimumSpacing
            persistPollingStateBestEffort(context: "cache migration")
        }

        return mapper.map(response, fetchedAt: payload.fetchedAt)
    }

    func refresh() async -> UsageRefreshOutcome {
        loadPollingStateIfNeeded()

        let startedAt = clock.now
        switch policy.decision(for: pollingState, at: startedAt) {
        case .allowed:
            break
        case .deferred(let until, let restriction):
            return .deferred(until: until, restriction: restriction)
        }

        pollingState = policy.recordingAttempt(in: pollingState, at: startedAt)
        do {
            try persistPollingState()
        } catch {
            let message = "Could not save request scheduling state: \(error.localizedDescription)"
            Log.write("fetch: refused before request — \(message)")
            return .failed(message)
        }

        do {
            let result = try await client.fetch()
            let finishedAt = clock.now
            let snapshot = mapper.map(result.response, fetchedAt: finishedAt)

            pollingState = policy.recordingSuccess(in: pollingState, at: finishedAt)
            persistPollingStateBestEffort(context: "successful response")
            persistCacheBestEffort(raw: result.raw, fetchedAt: finishedAt)

            return .updated(snapshot)
        } catch let error as UsageAPIError {
            switch error {
            case .rateLimited(let retryAfter):
                let now = clock.now
                pollingState = policy.recordingRateLimit(
                    in: pollingState,
                    retryAfter: retryAfter,
                    at: now
                )
                persistPollingStateBestEffort(context: "rate limit")
                let until =
                    pollingState.nextAllowedAttemptAt
                    ?? now.addingTimeInterval(retryAfter + policy.retryAfterMargin)
                return .deferred(until: until, restriction: .serverRateLimit)

            case .unauthorized:
                return recordAuthenticationFailure(
                    "Sign-in expired — run `claude` once to refresh."
                )

            case .http, .undecodable:
                return recordFailure(error.localizedDescription)
            }
        } catch let error as AuthError {
            return recordAuthenticationFailure(error.localizedDescription)
        } catch let error as KeychainError {
            return recordAuthenticationFailure(error.localizedDescription)
        } catch is CancellationError {
            return .failed("Refresh cancelled.")
        } catch {
            return recordFailure(error.localizedDescription)
        }
    }

    private func recordAuthenticationFailure(_ message: String) -> UsageRefreshOutcome {
        pollingState = policy.recordingAuthenticationFailure(in: pollingState, at: clock.now)
        persistPollingStateBestEffort(context: "authentication failure")
        return .authenticationFailed(message)
    }

    private func recordFailure(_ message: String) -> UsageRefreshOutcome {
        pollingState = policy.recordingFailure(in: pollingState, at: clock.now)
        persistPollingStateBestEffort(context: "failed response")
        return .failed(message)
    }

    private func loadPollingStateIfNeeded() {
        guard !hasLoadedPollingState else { return }
        defer { hasLoadedPollingState = true }

        guard let data = try? Data(contentsOf: pollingStateURL) else { return }
        do {
            pollingState = try JSONDecoder().decode(PollingState.self, from: data)
        } catch {
            Log.write("polling state: ignored unreadable file — \(error.localizedDescription)")
        }
    }

    private func persistPollingState() throws {
        let encoded = try JSONEncoder().encode(pollingState)
        try encoded.write(to: pollingStateURL, options: .atomic)
    }

    private func persistPollingStateBestEffort(context: String) {
        do {
            try persistPollingState()
        } catch {
            Log.write("polling state: save failed after \(context) — \(error.localizedDescription)")
        }
    }

    private func persistCacheBestEffort(raw: Data, fetchedAt: Date) {
        do {
            let payload = CachedPayload(fetchedAt: fetchedAt, raw: raw)
            let encoded = try JSONEncoder().encode(payload)
            try encoded.write(to: cacheURL, options: .atomic)
        } catch {
            Log.write("cache: save failed — \(error.localizedDescription)")
        }
    }
}

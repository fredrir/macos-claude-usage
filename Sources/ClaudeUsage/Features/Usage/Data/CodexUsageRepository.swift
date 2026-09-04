import Foundation
import UsageCore

/// Owns Codex request scheduling and a provider-specific last-good cache.
actor CodexUsageRepository {
    private struct CachedPayload: Codable, Sendable {
        let fetchedAt: Date
        let raw: Data
    }

    private let client: any CodexUsageFetching
    private let cacheURL: URL
    private let pollingStateURL: URL
    private let policy: PollingPolicy
    private let clock: any DateProvider
    private let mapper: CodexRateLimitsMapper

    private var pollingState = PollingState()
    private var hasLoadedPollingState = false

    init(
        client: any CodexUsageFetching = CodexAppServerClient(),
        cacheURL: URL = AppPaths.codexCachedPayload,
        pollingStateURL: URL = AppPaths.codexPollingState,
        policy: PollingPolicy = PollingPolicy(authenticationDelay: 15 * 60),
        clock: any DateProvider = SystemDateProvider(),
        mapper: CodexRateLimitsMapper = CodexRateLimitsMapper()
    ) {
        self.client = client
        self.cacheURL = cacheURL
        self.pollingStateURL = pollingStateURL
        self.policy = policy
        self.clock = clock
        self.mapper = mapper
    }

    func loadCachedSnapshot() -> UsageSnapshot? {
        loadPollingStateIfNeeded()

        guard
            let data = try? Data(contentsOf: cacheURL),
            let payload = try? JSONDecoder().decode(CachedPayload.self, from: data),
            let response = try? CodexAppServerClient.decode(payload.raw)
        else {
            return nil
        }

        if pollingState.lastAttemptAt == nil, pollingState.nextAllowedAttemptAt == nil {
            pollingState.lastSuccessAt = payload.fetchedAt
            pollingState.nextAllowedAttemptAt = payload.fetchedAt.addingTimeInterval(
                policy.minimumSpacing
            )
            pollingState.restriction = .minimumSpacing
            persistPollingStateBestEffort(context: "Codex cache migration")
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
            let message = "Could not save Codex request scheduling state: \(error.localizedDescription)"
            Log.write("codex fetch: refused before request — \(message)")
            return .failed(message)
        }

        do {
            let result = try await client.fetch()
            let finishedAt = clock.now
            let snapshot = mapper.map(result.response, fetchedAt: finishedAt)

            pollingState = policy.recordingSuccess(in: pollingState, at: finishedAt)
            persistPollingStateBestEffort(context: "successful Codex response")
            persistCacheBestEffort(raw: result.raw, fetchedAt: finishedAt)
            return .updated(snapshot)
        } catch let error as CodexUsageError {
            switch error {
            case .authenticationRequired:
                return recordAuthenticationFailure(error.localizedDescription)
            case .executableNotFound, .timedOut, .processFailed, .protocolFailure, .undecodable:
                return recordFailure(error.localizedDescription)
            }
        } catch is CancellationError {
            return .failed("Codex refresh cancelled.")
        } catch {
            return recordFailure(error.localizedDescription)
        }
    }

    private func recordAuthenticationFailure(_ message: String) -> UsageRefreshOutcome {
        pollingState = policy.recordingAuthenticationFailure(in: pollingState, at: clock.now)
        persistPollingStateBestEffort(context: "Codex authentication failure")
        return .authenticationFailed(message)
    }

    private func recordFailure(_ message: String) -> UsageRefreshOutcome {
        pollingState = policy.recordingFailure(in: pollingState, at: clock.now)
        persistPollingStateBestEffort(context: "failed Codex response")
        return .failed(message)
    }

    private func loadPollingStateIfNeeded() {
        guard !hasLoadedPollingState else { return }
        defer { hasLoadedPollingState = true }

        guard let data = try? Data(contentsOf: pollingStateURL) else { return }
        do {
            pollingState = try JSONDecoder().decode(PollingState.self, from: data)
        } catch {
            Log.write("Codex polling state: ignored unreadable file — \(error.localizedDescription)")
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
            Log.write("Codex polling state: save failed after \(context) — \(error.localizedDescription)")
        }
    }

    private func persistCacheBestEffort(raw: Data, fetchedAt: Date) {
        do {
            let payload = CachedPayload(fetchedAt: fetchedAt, raw: raw)
            let encoded = try JSONEncoder().encode(payload)
            try encoded.write(to: cacheURL, options: .atomic)
        } catch {
            Log.write("Codex cache: save failed — \(error.localizedDescription)")
        }
    }
}

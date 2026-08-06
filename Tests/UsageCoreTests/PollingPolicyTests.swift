import Foundation
import Testing

@testable import UsageCore

@Suite("Polling policy")
struct PollingPolicyTests {
    private let policy = PollingPolicy()
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)

    @Test("An attempt immediately establishes the fifteen-minute floor")
    func attemptEstablishesMinimumSpacing() {
        let state = policy.recordingAttempt(in: PollingState(), at: now)

        #expect(state.lastAttemptAt == now)
        #expect(state.nextAllowedAttemptAt == now.addingTimeInterval(15 * 60))
        #expect(
            policy.decision(for: state, at: now.addingTimeInterval(899))
                == .deferred(
                    until: now.addingTimeInterval(900),
                    restriction: .minimumSpacing
                )
        )
        #expect(policy.decision(for: state, at: now.addingTimeInterval(900)) == .allowed)
    }

    @Test("A persisted next-allowed date survives an encode/decode restart")
    func persistsDeferralAcrossRestart() throws {
        let penalty = now.addingTimeInterval(2_000)
        let original = PollingState(
            lastAttemptAt: now,
            lastSuccessAt: now.addingTimeInterval(-300),
            nextAllowedAttemptAt: penalty,
            restriction: .serverRateLimit,
            errorBackoff: 240
        )
        let persisted = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(PollingState.self, from: persisted)

        #expect(restored == original)
        #expect(
            policy.decision(for: restored, at: now.addingTimeInterval(1_000))
                == .deferred(until: penalty, restriction: .serverRateLimit)
        )
    }

    @Test("Derives the minimum spacing from a persisted last attempt")
    func derivesSpacingWhenExplicitDeadlineIsMissing() {
        let state = PollingState(lastAttemptAt: now)

        #expect(
            policy.decision(for: state, at: now.addingTimeInterval(100))
                == .deferred(
                    until: now.addingTimeInterval(900),
                    restriction: .minimumSpacing
                )
        )
    }

    @Test("Adds a safety margin to Retry-After")
    func addsRetryAfterMargin() {
        let state = policy.recordingRateLimit(
            in: PollingState(),
            retryAfter: 600,
            at: now
        )

        #expect(state.nextAllowedAttemptAt == now.addingTimeInterval(660))
        #expect(state.restriction == .serverRateLimit)
    }

    @Test("A rate limit never shortens an existing minimum-spacing deadline")
    func rateLimitPreservesLaterDeadline() {
        let attempted = policy.recordingAttempt(in: PollingState(), at: now)
        let rateLimited = policy.recordingRateLimit(
            in: attempted,
            retryAfter: 100,
            at: now
        )

        #expect(rateLimited.nextAllowedAttemptAt == now.addingTimeInterval(900))
        #expect(rateLimited.restriction == .serverRateLimit)
    }

    @Test("Authentication failures use the configured delay")
    func authenticationDelay() {
        let state = policy.recordingAuthenticationFailure(in: PollingState(), at: now)

        #expect(state.nextAllowedAttemptAt == now.addingTimeInterval(120))
        #expect(state.restriction == .authentication)
    }

    @Test("Ordinary failures double the next backoff and cap it at one hour")
    func exponentialBackoffCapsAtOneHour() throws {
        var state = PollingState()
        var attemptDate = now
        var appliedDelays: [TimeInterval] = []

        for _ in 0..<8 {
            state = policy.recordingFailure(in: state, at: attemptDate)
            let deadline = try #require(state.nextAllowedAttemptAt)
            appliedDelays.append(deadline.timeIntervalSince(attemptDate))
            attemptDate = deadline
        }

        #expect(appliedDelays == [60, 120, 240, 480, 960, 1_920, 3_600, 3_600])
        #expect(state.errorBackoff == 3_600)
        #expect(state.restriction == .errorBackoff)
    }

    @Test("Success resets error backoff and schedules from completion")
    func successResetsBackoff() {
        let failing = PollingState(errorBackoff: 960)
        let state = policy.recordingSuccess(in: failing, at: now)

        #expect(state.lastSuccessAt == now)
        #expect(state.nextAllowedAttemptAt == now.addingTimeInterval(900))
        #expect(state.errorBackoff == 60)
        #expect(state.restriction == .minimumSpacing)
    }
}

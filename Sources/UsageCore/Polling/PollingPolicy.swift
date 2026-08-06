import Foundation

/// Why a fetch is currently deferred.
public enum PollingRestriction: String, Codable, Equatable, Sendable {
    case minimumSpacing
    case serverRateLimit
    case authentication
    case errorBackoff
}

/// Persisted scheduling state. Save the value returned by `recordingAttempt` before starting
/// network work so a restart cannot bypass the minimum request spacing.
public struct PollingState: Codable, Equatable, Sendable {
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var nextAllowedAttemptAt: Date?
    public var restriction: PollingRestriction?
    /// Delay to use for the next ordinary failure.
    public var errorBackoff: TimeInterval

    public init(
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        nextAllowedAttemptAt: Date? = nil,
        restriction: PollingRestriction? = nil,
        errorBackoff: TimeInterval = 60
    ) {
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.nextAllowedAttemptAt = nextAllowedAttemptAt
        self.restriction = restriction
        self.errorBackoff = errorBackoff
    }
}

public enum PollingDecision: Equatable, Sendable {
    case allowed
    case deferred(until: Date, restriction: PollingRestriction)
}

/// Pure scheduling policy for usage requests.
public struct PollingPolicy: Equatable, Sendable {
    public let minimumSpacing: TimeInterval
    public let retryAfterMargin: TimeInterval
    public let authenticationDelay: TimeInterval
    public let initialErrorBackoff: TimeInterval
    public let maximumErrorBackoff: TimeInterval

    public init(
        minimumSpacing: TimeInterval = 15 * 60,
        retryAfterMargin: TimeInterval = 60,
        authenticationDelay: TimeInterval = 2 * 60,
        initialErrorBackoff: TimeInterval = 60,
        maximumErrorBackoff: TimeInterval = 60 * 60
    ) {
        precondition(minimumSpacing >= 0, "Minimum spacing cannot be negative")
        precondition(retryAfterMargin >= 0, "Retry-After margin cannot be negative")
        precondition(authenticationDelay >= 0, "Authentication delay cannot be negative")
        precondition(initialErrorBackoff >= 0, "Initial error backoff cannot be negative")
        precondition(
            maximumErrorBackoff >= initialErrorBackoff,
            "Maximum error backoff cannot be less than its initial value"
        )

        self.minimumSpacing = minimumSpacing
        self.retryAfterMargin = retryAfterMargin
        self.authenticationDelay = authenticationDelay
        self.initialErrorBackoff = initialErrorBackoff
        self.maximumErrorBackoff = maximumErrorBackoff
    }

    /// Decides whether a request may begin. A future persisted `nextAllowedAttemptAt` is always
    /// honored, including after process restart.
    public func decision(for state: PollingState, at now: Date) -> PollingDecision {
        guard let until = effectiveNextAllowedAttempt(for: state), now < until else {
            return .allowed
        }

        return .deferred(
            until: until,
            restriction: state.restriction ?? .minimumSpacing
        )
    }

    /// Records an attempt and establishes the minimum spacing immediately. Persist this state
    /// before awaiting the request.
    public func recordingAttempt(in state: PollingState, at now: Date) -> PollingState {
        var updated = state
        updated.lastAttemptAt = now
        return scheduling(
            updated,
            noEarlierThan: now.addingTimeInterval(minimumSpacing),
            restriction: .minimumSpacing
        )
    }

    public func recordingSuccess(in state: PollingState, at now: Date) -> PollingState {
        var updated = state
        updated.lastAttemptAt = updated.lastAttemptAt ?? now
        updated.lastSuccessAt = now
        updated.nextAllowedAttemptAt = now.addingTimeInterval(minimumSpacing)
        updated.restriction = .minimumSpacing
        updated.errorBackoff = initialErrorBackoff
        return updated
    }

    public func recordingRateLimit(
        in state: PollingState,
        retryAfter: TimeInterval,
        at now: Date
    ) -> PollingState {
        let delay = max(0, retryAfter) + retryAfterMargin
        return scheduling(
            state,
            noEarlierThan: now.addingTimeInterval(delay),
            restriction: .serverRateLimit
        )
    }

    public func recordingAuthenticationFailure(
        in state: PollingState,
        at now: Date
    ) -> PollingState {
        scheduling(
            state,
            noEarlierThan: now.addingTimeInterval(authenticationDelay),
            restriction: .authentication
        )
    }

    public func recordingFailure(in state: PollingState, at now: Date) -> PollingState {
        var updated = state
        let delay = min(max(0, updated.errorBackoff), maximumErrorBackoff)
        updated = scheduling(
            updated,
            noEarlierThan: now.addingTimeInterval(delay),
            restriction: .errorBackoff
        )
        updated.errorBackoff = min(
            max(delay * 2, initialErrorBackoff),
            maximumErrorBackoff
        )
        return updated
    }

    private func effectiveNextAllowedAttempt(for state: PollingState) -> Date? {
        let spacingUntil = state.lastAttemptAt?.addingTimeInterval(minimumSpacing)

        switch (state.nextAllowedAttemptAt, spacingUntil) {
        case (.some(let persisted), .some(let spacing)):
            return max(persisted, spacing)
        case (.some(let persisted), nil):
            return persisted
        case (nil, .some(let spacing)):
            return spacing
        case (nil, nil):
            return nil
        }
    }

    private func scheduling(
        _ state: PollingState,
        noEarlierThan proposedDate: Date,
        restriction: PollingRestriction
    ) -> PollingState {
        var updated = state
        let existingDate = effectiveNextAllowedAttempt(for: state)

        if let existingDate, existingDate > proposedDate {
            updated.nextAllowedAttemptAt = existingDate
        } else {
            updated.nextAllowedAttemptAt = proposedDate
        }
        updated.restriction = restriction
        return updated
    }
}

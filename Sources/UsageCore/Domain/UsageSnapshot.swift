import Foundation

/// A coherent set of usage windows returned by one successful fetch.
public struct UsageSnapshot: Equatable, Sendable {
    public let buckets: [UsageBucket]
    public let fetchedAt: Date

    public init(buckets: [UsageBucket], fetchedAt: Date) {
        self.buckets = buckets
        self.fetchedAt = fetchedAt
    }

    public var session: UsageBucket? {
        buckets.first { $0.role == .session }
    }

    public var fable: UsageBucket? {
        buckets.first { $0.role == .fable }
    }
}

extension Collection where Element == UsageBucket {
    public var session: UsageBucket? {
        first { $0.role == .session }
    }

    public var fable: UsageBucket? {
        first { $0.role == .fable }
    }
}

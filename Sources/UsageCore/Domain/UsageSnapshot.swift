import Foundation

public struct UsageSnapshot: Equatable, Sendable {
    public let buckets: [UsageBucket]
    public let fetchedAt: Date
    public let credits: CreditBalance?

    public init(buckets: [UsageBucket], fetchedAt: Date, credits: CreditBalance? = nil) {
        self.buckets = buckets
        self.fetchedAt = fetchedAt
        self.credits = credits
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

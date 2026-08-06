import Foundation

/// Provides the current time without global mutable test state.
public protocol DateProvider: Sendable {
    var now: Date { get }
}

public struct SystemDateProvider: DateProvider {
    public init() {}

    public var now: Date {
        .now
    }
}

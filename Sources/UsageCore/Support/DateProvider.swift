import Foundation

public protocol DateProvider: Sendable {
    var now: Date { get }
}

public struct SystemDateProvider: DateProvider {
    public init() {}

    public var now: Date {
        .now
    }
}

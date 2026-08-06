import Foundation

/// The purpose a usage window serves in the UI.
public enum UsageRole: String, Codable, Equatable, Sendable {
    case session
    case weeklyAll
    case fable
    case other
}

/// A normalized traffic-light state for a usage window.
public enum UsageLevel: String, Codable, Equatable, Sendable {
    case normal
    case warning
    case critical
}

/// The usage service's assessment of a limit window.
///
/// Unknown values are preserved so adding a new server-side severity does not make an
/// otherwise valid response undecodable.
public enum UsageSeverity: Codable, Equatable, Sendable {
    case normal
    case warning
    case critical
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        self =
            switch value {
            case "normal": .normal
            case "warning": .warning
            case "critical": .critical
            default: .unknown(value)
            }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        case .unknown(let value): value
        }
    }
}

/// A single usage limit window normalized for presentation.
public struct UsageBucket: Identifiable, Equatable, Sendable {
    public typealias Role = UsageRole
    public typealias Level = UsageLevel

    public let id: String
    public let title: String
    /// Percentage of the window consumed, clamped to `0 ... 100`.
    public let utilization: Double
    public let resetsAt: Date?
    public let severity: UsageSeverity?
    public let role: UsageRole

    public init(
        id: String,
        title: String,
        utilization: Double,
        resetsAt: Date?,
        severity: UsageSeverity?,
        role: UsageRole
    ) {
        self.id = id
        self.title = title
        self.utilization = min(100, max(0, utilization))
        self.resetsAt = resetsAt
        self.severity = severity
        self.role = role
    }

    /// Percentage of the window still available, in `0 ... 100`.
    public var remaining: Double {
        100 - utilization
    }

    /// Fraction of the window consumed, in `0 ... 1`.
    public var usedFraction: Double {
        utilization / 100
    }

    /// Prefers the server-provided severity and falls back to remaining-capacity thresholds.
    public var level: UsageLevel {
        switch severity {
        case .critical: .critical
        case .warning: .warning
        case .normal: .normal
        case .unknown, nil:
            if remaining < 10 {
                .critical
            } else if remaining < 25 {
                .warning
            } else {
                .normal
            }
        }
    }
}

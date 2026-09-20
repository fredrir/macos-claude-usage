import Foundation

public enum UsageRole: String, Codable, Equatable, Sendable {
    case session
    case weeklyAll
    case fable
    case other
}

public enum UsageLevel: String, Codable, Equatable, Sendable {
    case normal
    case warning
    case critical
}

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

public struct UsageBucket: Identifiable, Equatable, Sendable {
    public typealias Role = UsageRole
    public typealias Level = UsageLevel

    public let id: String
    public let title: String
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

    public var remaining: Double {
        100 - utilization
    }

    public var usedFraction: Double {
        utilization / 100
    }

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

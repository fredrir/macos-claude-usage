import Foundation

public struct UsageWindowDTO: Decodable, Equatable, Sendable {
    public let utilization: Double?
    public let resetsAt: String?

    public init(utilization: Double? = nil, resetsAt: String? = nil) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

public struct LimitEntryDTO: Decodable, Equatable, Sendable {
    public struct ScopeDTO: Decodable, Equatable, Sendable {
        public struct ModelDTO: Decodable, Equatable, Sendable {
            public let id: String?
            public let displayName: String?

            public init(id: String? = nil, displayName: String? = nil) {
                self.id = id
                self.displayName = displayName
            }

            private enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
            }
        }

        public let model: ModelDTO?

        public init(model: ModelDTO? = nil) {
            self.model = model
        }
    }

    public let kind: String?
    public let group: String?
    public let percent: Double?
    public let severity: UsageSeverity?
    public let resetsAt: String?
    public let scope: ScopeDTO?
    public let isActive: Bool?

    public init(
        kind: String? = nil,
        group: String? = nil,
        percent: Double? = nil,
        severity: UsageSeverity? = nil,
        resetsAt: String? = nil,
        scope: ScopeDTO? = nil,
        isActive: Bool? = nil
    ) {
        self.kind = kind
        self.group = group
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.scope = scope
        self.isActive = isActive
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case group
        case percent
        case severity
        case resetsAt = "resets_at"
        case scope
        case isActive = "is_active"
    }
}

/// Wire representation of the usage response.
///
/// At least one known root key must be present. A present key whose value is `null` is a
/// recognized response, while `{}` and unknown-only objects are rejected. This prevents a
/// silent schema change from replacing a valid cached snapshot with an empty one.
public struct UsageResponseDTO: Decodable, Equatable, Sendable {
    public let fiveHour: UsageWindowDTO?
    public let sevenDay: UsageWindowDTO?
    public let sevenDayOpus: UsageWindowDTO?
    public let sevenDaySonnet: UsageWindowDTO?
    public let limits: [LimitEntryDTO]?

    public init(
        fiveHour: UsageWindowDTO? = nil,
        sevenDay: UsageWindowDTO? = nil,
        sevenDayOpus: UsageWindowDTO? = nil,
        sevenDaySonnet: UsageWindowDTO? = nil,
        limits: [LimitEntryDTO]? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.limits = limits
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasRecognizedKey = CodingKeys.allCases.contains { container.contains($0) }

        guard hasRecognizedKey else {
            throw DecodingError.dataCorruptedError(
                forKey: .limits,
                in: container,
                debugDescription: "The usage response has no recognized root fields."
            )
        }

        fiveHour = try container.decodeIfPresent(UsageWindowDTO.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(UsageWindowDTO.self, forKey: .sevenDay)
        sevenDayOpus = try container.decodeIfPresent(UsageWindowDTO.self, forKey: .sevenDayOpus)
        sevenDaySonnet = try container.decodeIfPresent(UsageWindowDTO.self, forKey: .sevenDaySonnet)
        limits = try container.decodeIfPresent([LimitEntryDTO].self, forKey: .limits)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case limits
    }
}

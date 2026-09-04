import Foundation

/// One quota window returned by Codex's app-server account API.
public struct CodexRateLimitWindowDTO: Codable, Equatable, Sendable {
    public let usedPercent: Double?
    public let windowDurationMins: Int?
    public let resetsAt: Double?

    public init(
        usedPercent: Double? = nil,
        windowDurationMins: Int? = nil,
        resetsAt: Double? = nil
    ) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }
}

/// A main or model-specific pair of Codex quota windows.
public struct CodexRateLimitDTO: Codable, Equatable, Sendable {
    public let limitId: String
    public let limitName: String?
    public let primary: CodexRateLimitWindowDTO?
    public let secondary: CodexRateLimitWindowDTO?
    public let planType: String?
    public let rateLimitReachedType: String?

    public init(
        limitId: String,
        limitName: String? = nil,
        primary: CodexRateLimitWindowDTO? = nil,
        secondary: CodexRateLimitWindowDTO? = nil,
        planType: String? = nil,
        rateLimitReachedType: String? = nil
    ) {
        self.limitId = limitId
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.rateLimitReachedType = rateLimitReachedType
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limitId = try container.decodeIfPresent(String.self, forKey: .limitId) ?? ""
        limitName = try container.decodeIfPresent(String.self, forKey: .limitName)
        primary = try container.decodeIfPresent(CodexRateLimitWindowDTO.self, forKey: .primary)
        secondary = try container.decodeIfPresent(CodexRateLimitWindowDTO.self, forKey: .secondary)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        rateLimitReachedType = try container.decodeIfPresent(String.self, forKey: .rateLimitReachedType)
    }

    private enum CodingKeys: String, CodingKey {
        case limitId
        case limitName
        case primary
        case secondary
        case planType
        case rateLimitReachedType
    }
}

/// Result payload from the stable `account/rateLimits/read` app-server method.
///
/// The keyed collection is authoritative when present. `rateLimits` is retained as the
/// backward-compatible fallback for older Codex releases.
public struct CodexRateLimitsResponseDTO: Codable, Equatable, Sendable {
    public let rateLimits: CodexRateLimitDTO?
    public let rateLimitsByLimitId: [String: CodexRateLimitDTO]?

    public init(
        rateLimits: CodexRateLimitDTO? = nil,
        rateLimitsByLimitId: [String: CodexRateLimitDTO]? = nil
    ) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitId = rateLimitsByLimitId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard CodingKeys.allCases.contains(where: { container.contains($0) }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .rateLimits,
                in: container,
                debugDescription: "The Codex rate-limit response has no recognized root fields."
            )
        }

        rateLimits = try container.decodeIfPresent(CodexRateLimitDTO.self, forKey: .rateLimits)
        rateLimitsByLimitId = try container.decodeIfPresent(
            [String: CodexRateLimitDTO].self,
            forKey: .rateLimitsByLimitId
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case rateLimits
        case rateLimitsByLimitId
    }
}

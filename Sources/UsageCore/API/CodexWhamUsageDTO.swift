import Foundation

public struct CodexWhamUsageDTO: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public let usedPercent: Double?
        public let limitWindowSeconds: Int?
        public let resetAfterSeconds: Int?
        public let resetAt: Double?

        public init(
            usedPercent: Double? = nil,
            limitWindowSeconds: Int? = nil,
            resetAfterSeconds: Int? = nil,
            resetAt: Double? = nil
        ) {
            self.usedPercent = usedPercent
            self.limitWindowSeconds = limitWindowSeconds
            self.resetAfterSeconds = resetAfterSeconds
            self.resetAt = resetAt
        }

        private enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }
    }

    public struct RateLimit: Codable, Equatable, Sendable {
        public let allowed: Bool?
        public let limitReached: Bool?
        public let primaryWindow: Window?
        public let secondaryWindow: Window?

        public init(
            allowed: Bool? = nil,
            limitReached: Bool? = nil,
            primaryWindow: Window? = nil,
            secondaryWindow: Window? = nil
        ) {
            self.allowed = allowed
            self.limitReached = limitReached
            self.primaryWindow = primaryWindow
            self.secondaryWindow = secondaryWindow
        }

        private enum CodingKeys: String, CodingKey {
            case allowed
            case limitReached = "limit_reached"
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    public struct AdditionalRateLimit: Codable, Equatable, Sendable {
        public let limitName: String?
        public let meteredFeature: String?
        public let primaryWindow: Window?
        public let secondaryWindow: Window?

        public init(
            limitName: String? = nil,
            meteredFeature: String? = nil,
            primaryWindow: Window? = nil,
            secondaryWindow: Window? = nil
        ) {
            self.limitName = limitName
            self.meteredFeature = meteredFeature
            self.primaryWindow = primaryWindow
            self.secondaryWindow = secondaryWindow
        }

        private enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    public struct RateLimitReachedType: Codable, Equatable, Sendable {
        public let type: String?
        public let details: String?

        public init(type: String? = nil, details: String? = nil) {
            self.type = type
            self.details = details
        }
    }

    public let userId: String?
    public let accountId: String?
    public let email: String?
    public let planType: String?
    public let rateLimit: RateLimit?
    public let additionalRateLimits: [String: AdditionalRateLimit]?
    public let rateLimitReachedType: RateLimitReachedType?

    public init(
        userId: String? = nil,
        accountId: String? = nil,
        email: String? = nil,
        planType: String? = nil,
        rateLimit: RateLimit? = nil,
        additionalRateLimits: [String: AdditionalRateLimit]? = nil,
        rateLimitReachedType: RateLimitReachedType? = nil
    ) {
        self.userId = userId
        self.accountId = accountId
        self.email = email
        self.planType = planType
        self.rateLimit = rateLimit
        self.additionalRateLimits = additionalRateLimits
        self.rateLimitReachedType = rateLimitReachedType
    }

    private enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case accountId = "account_id"
        case email
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case rateLimitReachedType = "rate_limit_reached_type"
    }

    public func toRateLimitsResponse() -> CodexRateLimitsResponseDTO {
        let primaryWin = rateLimit?.primaryWindow.map {
            CodexRateLimitWindowDTO(
                usedPercent: $0.usedPercent,
                windowDurationMins: $0.limitWindowSeconds.map { $0 / 60 },
                resetsAt: $0.resetAt
            )
        }
        let secondaryWin = rateLimit?.secondaryWindow.map {
            CodexRateLimitWindowDTO(
                usedPercent: $0.usedPercent,
                windowDurationMins: $0.limitWindowSeconds.map { $0 / 60 },
                resetsAt: $0.resetAt
            )
        }

        let mainLimit = CodexRateLimitDTO(
            limitId: "codex",
            limitName: "Codex",
            primary: primaryWin,
            secondary: secondaryWin,
            planType: planType,
            rateLimitReachedType: rateLimitReachedType?.type
        )

        var byId: [String: CodexRateLimitDTO] = ["codex": mainLimit]

        if let additional = additionalRateLimits {
            for (key, limit) in additional {
                let p = limit.primaryWindow.map {
                    CodexRateLimitWindowDTO(
                        usedPercent: $0.usedPercent,
                        windowDurationMins: $0.limitWindowSeconds.map { $0 / 60 },
                        resetsAt: $0.resetAt
                    )
                }
                let s = limit.secondaryWindow.map {
                    CodexRateLimitWindowDTO(
                        usedPercent: $0.usedPercent,
                        windowDurationMins: $0.limitWindowSeconds.map { $0 / 60 },
                        resetsAt: $0.resetAt
                    )
                }
                let dto = CodexRateLimitDTO(
                    limitId: key,
                    limitName: limit.limitName ?? limit.meteredFeature ?? key,
                    primary: p,
                    secondary: s,
                    planType: planType,
                    rateLimitReachedType: nil
                )
                byId[key] = dto
            }
        }

        return CodexRateLimitsResponseDTO(
            rateLimits: mainLimit,
            rateLimitsByLimitId: byId
        )
    }
}

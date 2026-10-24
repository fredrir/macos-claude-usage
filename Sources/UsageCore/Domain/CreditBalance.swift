import Foundation

public struct CreditBalance: Codable, Equatable, Sendable {
    public let amount: Double?
    public let currency: String?
    public let isUnlimited: Bool

    public init(amount: Double?, currency: String? = nil, isUnlimited: Bool = false) {
        self.amount = amount.flatMap { $0.isFinite ? max(0, $0) : nil }
        self.currency = currency
        self.isUnlimited = isUnlimited
    }

    /// Without a declared full amount the current balance is the full amount, so the gauge starts full
    /// instead of empty.
    public func remainingFraction(fullAmount: Double?) -> Double? {
        if isUnlimited { return 1 }
        guard let amount else { return nil }
        guard let fullAmount, fullAmount.isFinite, fullAmount > 0 else { return amount > 0 ? 1 : 0 }
        return min(1, max(0, amount / fullAmount))
    }
}

public struct CreditDisplayPreference: Codable, Equatable, Sendable {
    private var storedFullGaugeAmount: Double?

    public var placements: Set<GaugePlacement> = []

    /// The positive amount the menu bar gauge fills against. Zero, negative and missing amounts are
    /// rejected: an unset amount means the current credit balance is used instead.
    public var fullGaugeAmount: Double? {
        get { storedFullGaugeAmount }
        set { storedFullGaugeAmount = Self.sanitized(newValue) }
    }

    public init(placements: Set<GaugePlacement> = [], fullGaugeAmount: Double? = nil) {
        self.placements = placements
        storedFullGaugeAmount = Self.sanitized(fullGaugeAmount)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            placements: try container.decodeIfPresent(Set<GaugePlacement>.self, forKey: .placements) ?? [],
            fullGaugeAmount: try container.decodeIfPresent(Double.self, forKey: .fullGaugeAmount)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(placements, forKey: .placements)
        try container.encodeIfPresent(storedFullGaugeAmount, forKey: .fullGaugeAmount)
    }

    /// Zero, negative and non-finite amounts are not valid full gauge amounts.
    public static func sanitized(_ amount: Double?) -> Double? {
        guard let amount, amount.isFinite, amount > 0 else { return nil }
        return amount
    }

    /// The amount the gauge fills against: the custom amount, or the current balance when unset.
    public func resolvedFullGaugeAmount(for credits: CreditBalance?) -> Double? {
        storedFullGaugeAmount ?? credits?.amount
    }

    private enum CodingKeys: String, CodingKey {
        case placements
        case fullGaugeAmount
    }
}

public struct CreditDisplaySettings: Codable, Equatable, Sendable {
    public var claude = CreditDisplayPreference()
    public var codex = CreditDisplayPreference()

    public init() {}

    public subscript(provider: UsageProvider) -> CreditDisplayPreference {
        get {
            switch provider {
            case .claude: claude
            case .codex: codex
            }
        }
        set {
            switch provider {
            case .claude: claude = newValue
            case .codex: codex = newValue
            }
        }
    }
}

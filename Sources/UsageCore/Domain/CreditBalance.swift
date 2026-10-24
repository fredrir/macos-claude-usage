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

    public func remainingFraction(fullAmount: Double?) -> Double? {
        if isUnlimited { return 1 }
        guard let amount, let fullAmount, fullAmount.isFinite, fullAmount > 0 else { return nil }
        return min(1, max(0, amount / fullAmount))
    }
}

public struct CreditDisplayPreference: Codable, Equatable, Sendable {
    public var placements: Set<GaugePlacement> = []
    public var fullGaugeAmount: Double?

    public init() {}
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

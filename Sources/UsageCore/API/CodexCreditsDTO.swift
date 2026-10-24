import Foundation

public struct CodexCreditsDTO: Codable, Equatable, Sendable {
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public let balance: String?

    public init(hasCredits: Bool? = nil, unlimited: Bool? = nil, balance: String? = nil) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits =
            try container.decodeIfPresent(Bool.self, forKey: .hasCredits)
            ?? container.decodeIfPresent(Bool.self, forKey: .hasCreditsSnakeCase)
        unlimited = try container.decodeIfPresent(Bool.self, forKey: .unlimited)
        if let number = try? container.decode(Double.self, forKey: .balance) {
            balance = String(number)
        } else {
            balance = try container.decodeIfPresent(String.self, forKey: .balance)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(hasCredits, forKey: .hasCredits)
        try container.encodeIfPresent(unlimited, forKey: .unlimited)
        try container.encodeIfPresent(balance, forKey: .balance)
    }

    public var creditBalance: CreditBalance {
        let amount = balance.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return CreditBalance(amount: amount ?? (hasCredits == false ? 0 : nil), isUnlimited: unlimited == true)
    }

    private enum CodingKeys: String, CodingKey {
        case hasCredits
        case hasCreditsSnakeCase = "has_credits"
        case unlimited
        case balance
    }
}

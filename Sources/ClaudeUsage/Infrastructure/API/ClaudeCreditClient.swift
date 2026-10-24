import Foundation
import UsageCore

struct ClaudeCreditClient: Sendable {
    let usageEndpoint: URL
    let session: URLSession

    func fetch(accessToken: String) async throws -> CreditBalance? {
        let base = usageEndpoint.deletingLastPathComponent()
        let profileData = try await get(base.appendingPathComponent("profile"), accessToken: accessToken)
        let profile = try JSONDecoder().decode(Profile.self, from: profileData)
        guard let organizationID = profile.organization?.uuid, UUID(uuidString: organizationID) != nil else {
            return nil
        }

        let endpoint = base.appendingPathComponent("organizations")
            .appendingPathComponent(organizationID)
            .appendingPathComponent("prepaid/credits")
        let data = try await get(endpoint, accessToken: accessToken)
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> CreditBalance? {
        let response = try JSONDecoder().decode(PrepaidCredits.self, from: data)
        guard let amount = response.amount, amount.isFinite,
            let currency = response.currency?.uppercased(), Locale.commonISOCurrencyCodes.contains(currency)
        else { return nil }

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        let decimals = response.decimalPlaces ?? formatter.maximumFractionDigits
        guard (0...6).contains(decimals) else { return nil }
        return CreditBalance(amount: amount / pow(10, Double(decimals)), currency: currency)
    }

    private func get(_ url: URL, accessToken: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else { throw UsageAPIError.http(status: response.statusCode) }
        return data
    }

    private struct Profile: Decodable {
        struct Organization: Decodable { let uuid: String? }
        let organization: Organization?
    }

    private struct PrepaidCredits: Decodable {
        let amount: Double?
        let currency: String?
        let decimalPlaces: Int?

        enum CodingKeys: String, CodingKey {
            case amount
            case currency
            case decimalPlaces = "decimal_places"
        }
    }
}

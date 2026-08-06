import Foundation

enum UsageAPIError: LocalizedError {
    case rateLimited(retryAfter: TimeInterval)
    case unauthorized
    case http(status: Int)

    var errorDescription: String? {
        switch self {
        case .rateLimited(let retryAfter):
            return "Rate limited by the usage endpoint (retry in \(Int(retryAfter / 60))m)."
        case .unauthorized:
            return "Not authorised — the access token was rejected."
        case .http(let status):
            return "Usage endpoint returned HTTP \(status)."
        }
    }
}

/// One limit window as the API reports it. `utilization` is a **percentage 0–100**, and
/// `resets_at` is **unix seconds** — both verified against how Claude Code renders them
/// (`Math.floor(u)% used`, bar fraction `u / 100`, `new Date(resets_at * 1000)`).
struct UsageWindow: Codable {
    let utilization: Double?
    let resets_at: Double?
}

/// An entry of the `limits[]` array: a weekly window scoped to a single model.
struct ScopedWindow: Codable {
    struct Scope: Codable {
        struct Model: Codable { let display_name: String? }
        let model: Model?
    }

    let kind: String?
    let percent: Double?
    let resets_at: Double?
    let scope: Scope?
}

struct UsageResponse: Codable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let seven_day_opus: UsageWindow?
    let seven_day_sonnet: UsageWindow?
    let seven_day_oauth_apps: UsageWindow?
    let seven_day_overage_included: UsageWindow?
    let cinder_cove: UsageWindow?
    let limits: [ScopedWindow]?
}

enum UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Fetches usage, transparently retrying once after a forced token refresh if the token
    /// turned out to be dead earlier than its recorded expiry.
    static func fetch() async throws -> (response: UsageResponse, raw: Data) {
        // Development escape hatch: the live endpoint is rate limited hard enough that
        // iterating on the UI against it is impractical.
        if let fixture = ProcessInfo.processInfo.environment["CLAUDE_USAGE_FIXTURE"] {
            let raw = try Data(contentsOf: URL(fileURLWithPath: fixture))
            return (try JSONDecoder().decode(UsageResponse.self, from: raw), raw)
        }

        let token = try await AuthManager.shared.accessToken()
        do {
            return try await request(token: token)
        } catch UsageAPIError.unauthorized {
            let refreshed = try await AuthManager.shared.forceRefresh()
            return try await request(token: refreshed)
        }
    }

    private static func request(token: String) async throws -> (response: UsageResponse, raw: Data) {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        guard let http = urlResponse as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        switch http.statusCode {
        case 200..<300:
            return (try JSONDecoder().decode(UsageResponse.self, from: data), data)
        case 401, 403:
            throw UsageAPIError.unauthorized
        case 429:
            let header = http.value(forHTTPHeaderField: "retry-after")
            let retryAfter = header.flatMap(TimeInterval.init) ?? 600
            throw UsageAPIError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageAPIError.http(status: http.statusCode)
        }
    }
}

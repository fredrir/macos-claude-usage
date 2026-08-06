import Foundation

enum UsageAPIError: LocalizedError {
    case rateLimited(retryAfter: TimeInterval)
    case unauthorized
    case http(status: Int)
    case undecodable(String)

    var errorDescription: String? {
        switch self {
        case .rateLimited(let retryAfter):
            return "Rate limited by the usage endpoint (retry in \(Int(retryAfter / 60))m)."
        case .unauthorized:
            return "Not authorised — the access token was rejected."
        case .http(let status):
            return "Usage endpoint returned HTTP \(status)."
        case .undecodable(let detail):
            return "Could not read the usage response: \(detail)"
        }
    }
}

/// One of the top-level limit windows. `utilization` is a percentage 0–100 and `resets_at` is
/// an ISO 8601 timestamp string — *not* unix seconds, despite the rate-limit response headers
/// using epoch seconds for the same concept.
struct UsageWindow: Codable {
    let utilization: Double?
    let resets_at: String?
}

/// An entry of `limits[]` — the structured view of every window, and the only place per-model
/// weekly windows (Fable) appear.
struct LimitEntry: Codable {
    struct Scope: Codable {
        struct Model: Codable {
            let id: String?
            let display_name: String?
        }
        let model: Model?
    }

    /// `session`, `weekly_all` or `weekly_scoped`.
    let kind: String?
    let group: String?
    let percent: Double?
    /// `normal`, `warning` or `critical` — the server's own read on how close the window is.
    let severity: String?
    let resets_at: String?
    let scope: Scope?
    let is_active: Bool?
}

struct UsageResponse: Codable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let seven_day_opus: UsageWindow?
    let seven_day_sonnet: UsageWindow?
    let limits: [LimitEntry]?
}

/// The endpoint emits microsecond precision (`2026-08-06T21:00:00.290962+00:00`), which
/// `ISO8601DateFormatter` will not parse with its fractional-seconds option. Sub-second
/// precision is meaningless for a reset time, so it is dropped before parsing.
enum ISODate {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }

        let withoutFraction = string.replacingOccurrences(
            of: #"\.\d+"#,
            with: "",
            options: .regularExpression
        )
        return formatter.date(from: withoutFraction)
            ?? withFractionalSeconds.date(from: string)
            ?? formatter.date(from: string)
    }
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
            return (try decode(raw), raw)
        }

        let token = try await AuthManager.shared.accessToken()
        do {
            return try await request(token: token)
        } catch UsageAPIError.unauthorized {
            let refreshed = try await AuthManager.shared.forceRefresh()
            return try await request(token: refreshed)
        }
    }

    /// Reports *which* field failed rather than Foundation's opaque "isn't in the correct
    /// format", so a future change to the response shape is diagnosable from the log alone.
    static func decode(_ data: Data) throws -> UsageResponse {
        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch let error as DecodingError {
            let detail: String
            switch error {
            case .typeMismatch(let type, let context):
                detail = "\(path(context)) is not \(type) — \(context.debugDescription)"
            case .valueNotFound(let type, let context):
                detail = "\(path(context)) missing \(type)"
            case .keyNotFound(let key, let context):
                detail = "\(path(context)) has no key '\(key.stringValue)'"
            case .dataCorrupted(let context):
                detail = "\(path(context)) corrupted — \(context.debugDescription)"
            @unknown default:
                detail = error.localizedDescription
            }
            throw UsageAPIError.undecodable(detail)
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let joined = context.codingPath.map(\.stringValue).joined(separator: ".")
        return joined.isEmpty ? "<root>" : joined
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
            return (try decode(data), data)
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

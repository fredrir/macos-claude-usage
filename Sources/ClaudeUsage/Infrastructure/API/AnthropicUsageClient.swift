import Foundation
import UsageCore

enum UsageAPIError: LocalizedError, Sendable {
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

struct UsageFetchResult: Sendable {
    let response: UsageResponseDTO
    let raw: Data
}

protocol UsageFetching: Sendable {
    func fetch() async throws -> UsageFetchResult
}

/// Network adapter for Anthropic's OAuth usage endpoint.
///
/// Token providers are injected so request behavior can be tested without touching the user's
/// Keychain. The production defaults delegate to the serialized `AuthManager` actor.
struct AnthropicUsageClient: UsageFetching {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let endpoint: URL
    private let session: URLSession
    private let accessToken: @Sendable () async throws -> String
    private let refreshToken: @Sendable (String) async throws -> String

    init(
        endpoint: URL = Self.endpoint,
        session: URLSession = .shared,
        accessToken: @escaping @Sendable () async throws -> String = {
            try await AuthManager.shared.accessToken()
        },
        refreshToken: @escaping @Sendable (String) async throws -> String = { rejectedToken in
            try await AuthManager.shared.forceRefresh(rejectedAccessToken: rejectedToken)
        }
    ) {
        self.endpoint = endpoint
        self.session = session
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    /// Fetches usage, retrying once after a refresh only when the exact rejected token is still
    /// current. This avoids rotating an already-replaced refresh token after a cross-process race.
    func fetch() async throws -> UsageFetchResult {
        // Development escape hatch: render and inspect against a fixture without consuming the
        // endpoint's intentionally conservative request allowance.
        if let fixture = ProcessInfo.processInfo.environment["CLAUDE_USAGE_FIXTURE"] {
            let raw = try Data(contentsOf: URL(fileURLWithPath: fixture))
            return UsageFetchResult(response: try Self.decode(raw), raw: raw)
        }

        let token = try await accessToken()
        do {
            return try await request(token: token)
        } catch UsageAPIError.unauthorized {
            let refreshed = try await refreshToken(token)
            return try await request(token: refreshed)
        }
    }

    /// Reports the failing field rather than Foundation's generic decoding message.
    static func decode(_ data: Data) throws -> UsageResponseDTO {
        do {
            return try JSONDecoder().decode(UsageResponseDTO.self, from: data)
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

    private func request(token: String) async throws -> UsageFetchResult {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        switch http.statusCode {
        case 200..<300:
            return UsageFetchResult(response: try Self.decode(data), raw: data)
        case 401, 403:
            throw UsageAPIError.unauthorized
        case 429:
            let retryAfter =
                RetryAfterParser.delay(
                    from: http.value(forHTTPHeaderField: "Retry-After"),
                    relativeTo: .now
                ) ?? 600
            throw UsageAPIError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageAPIError.http(status: http.statusCode)
        }
    }
}

/// Supports both forms permitted by HTTP: delay-seconds and an absolute HTTP-date.
enum RetryAfterParser {
    static func delay(from value: String?, relativeTo now: Date) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value) {
            return max(0, seconds)
        }

        let formats = [
            "EEE',' dd MMM yyyy HH':'mm':'ss zzz",
            "EEEE',' dd-MMM-yy HH':'mm':'ss zzz",
            "EEE MMM d HH':'mm':'ss yyyy",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        return nil
    }
}

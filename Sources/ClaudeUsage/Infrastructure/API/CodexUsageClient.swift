import Foundation
import UsageCore

/// Network adapter for ChatGPT/Codex's backend usage endpoint (`/backend-api/wham/usage`).
struct CodexUsageClient: CodexUsageFetching {
    static var endpoint: URL {
        AppEnvironment.shared.openAIEndpoint
    }

    private let endpoint: URL
    private let session: URLSession
    private let accessToken: @Sendable () async throws -> String
    private let refreshToken: @Sendable (String) async throws -> String

    init(
        endpoint: URL = Self.endpoint,
        session: URLSession = .shared,
        accessToken: @escaping @Sendable () async throws -> String = {
            try await CodexAuthManager.shared.accessToken()
        },
        refreshToken: @escaping @Sendable (String) async throws -> String = { rejectedToken in
            try await CodexAuthManager.shared.forceRefresh(rejectedAccessToken: rejectedToken)
        }
    ) {
        self.endpoint = endpoint
        self.session = session
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    func fetch() async throws -> CodexUsageFetchResult {
        // Development escape hatch: test against a fixture
        if let fixture = ProcessInfo.processInfo.environment["CODEX_USAGE_FIXTURE"] {
            let raw = try Data(contentsOf: URL(fileURLWithPath: fixture))
            return CodexUsageFetchResult(response: try Self.decode(raw), raw: raw)
        }

        let token: String
        do {
            token = try await accessToken()
        } catch {
            throw CodexUsageError.authenticationRequired
        }

        do {
            return try await request(token: token)
        } catch CodexUsageError.authenticationRequired {
            let refreshed = try await refreshToken(token)
            return try await request(token: refreshed)
        }
    }

    static func decode(_ data: Data) throws -> CodexRateLimitsResponseDTO {
        if let direct = try? JSONDecoder().decode(CodexRateLimitsResponseDTO.self, from: data),
           direct.rateLimits != nil {
            return direct
        }

        if let wham = try? JSONDecoder().decode(CodexWhamUsageDTO.self, from: data),
           wham.rateLimit != nil || wham.additionalRateLimits != nil {
            return wham.toRateLimitsResponse()
        }

        if let direct = try? JSONDecoder().decode(CodexRateLimitsResponseDTO.self, from: data) {
            return direct
        }

        do {
            let wham = try JSONDecoder().decode(CodexWhamUsageDTO.self, from: data)
            return wham.toRateLimitsResponse()
        } catch {
            throw CodexUsageError.undecodable(error.localizedDescription)
        }
    }

    private func request(token: String) async throws -> CodexUsageFetchResult {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = 20
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("claude-usage-macos", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw CodexUsageError.protocolFailure(error.localizedDescription)
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        switch status {
        case 200..<300:
            let decoded = try Self.decode(data)
            return CodexUsageFetchResult(response: decoded, raw: data)
        case 401:
            throw CodexUsageError.authenticationRequired
        case 429:
            throw CodexUsageError.protocolFailure("Rate limited (HTTP 429)")
        default:
            throw CodexUsageError.protocolFailure("HTTP \(status)")
        }
    }
}

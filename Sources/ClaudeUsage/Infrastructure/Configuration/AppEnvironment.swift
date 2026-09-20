import Foundation

public struct AppEnvironment: Sendable {
    public static let shared = AppEnvironment()

    private let values: [String: String]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        envFileContent: String? = nil
    ) {
        var merged: [String: String] = [:]

        if let content = envFileContent ?? Self.loadEnvFileContent() {
            let parsed = Self.parseDotEnv(content)
            merged.merge(parsed) { _, new in new }
        }

        merged.merge(environment) { _, envValue in envValue }

        self.values = merged
    }

    public func value(for key: String) -> String? {
        values[key]
    }

    public func string(for key: String, default defaultValue: String = "") -> String {
        values[key] ?? defaultValue
    }

    public func url(for key: String, default defaultValue: URL) -> URL {
        guard let string = values[key], let url = URL(string: string) else {
            return defaultValue
        }
        return url
    }

    public var openAIClientID: String {
        string(for: "OPENAI_CLIENT_ID")
    }

    public var openAIEndpoint: URL {
        url(for: "OPENAI_ENDPOINT", default: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
    }

    public var openAITokenURL: URL {
        url(for: "OPENAI_TOKEN_URL", default: URL(string: "https://auth.openai.com/oauth/token")!)
    }

    public var openAIAuthorizeURL: URL {
        url(for: "OPENAI_AUTHORIZE_URL", default: URL(string: "https://auth.openai.com/oauth/authorize")!)
    }

    public var openAIRedirectURI: String {
        string(for: "OPENAI_REDIRECT_URI", default: "http://localhost:1455/auth/callback")
    }

    public var claudeClientID: String {
        string(for: "CLAUDE_CLIENT_ID")
    }

    public var claudeTokenURL: URL {
        url(for: "CLAUDE_TOKEN_URL", default: URL(string: "https://platform.claude.com/v1/oauth/token")!)
    }

    public var claudeAuthorizeURL: URL {
        url(for: "CLAUDE_AUTHORIZE_URL", default: URL(string: "https://claude.com/cai/oauth/authorize")!)
    }

    public var claudeUsageEndpoint: URL {
        url(for: "CLAUDE_USAGE_ENDPOINT", default: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    }

    public var appleTeamID: String? {
        value(for: "APPLE_TEAM_ID")
    }

    public var appleNotaryProfile: String? {
        value(for: "APPLE_NOTARY_PROFILE") ?? value(for: "NOTARYTOOL_PROFILE")
    }

    public var appleID: String? {
        value(for: "APPLE_ID")
    }

    public static func parseDotEnv(_ content: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            var lineToParse = trimmed
            if lineToParse.hasPrefix("export ") {
                lineToParse = String(lineToParse.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            guard let equalIndex = lineToParse.firstIndex(of: "=") else {
                continue
            }
            let key = String(lineToParse[..<equalIndex]).trimmingCharacters(in: .whitespaces)
            var val = String(lineToParse[lineToParse.index(after: equalIndex)...]).trimmingCharacters(in: .whitespaces)
            if (val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2) ||
               (val.hasPrefix("'") && val.hasSuffix("'") && val.count >= 2) {
                val = String(val.dropFirst().dropLast())
            }
            if !key.isEmpty {
                result[key] = val
            }
        }
        return result
    }

    private static func loadEnvFileContent() -> String? {
        if let customPath = ProcessInfo.processInfo.environment["CLAUDE_USAGE_ENV_FILE"],
           let content = try? String(contentsOfFile: customPath, encoding: .utf8) {
            return content
        }

        if let bundleURL = Bundle.main.url(forResource: ".env", withExtension: nil),
           let content = try? String(contentsOf: bundleURL, encoding: .utf8) {
            return content
        }

        let cwdPath = FileManager.default.currentDirectoryPath + "/.env"
        if let content = try? String(contentsOfFile: cwdPath, encoding: .utf8) {
            return content
        }

        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent(".env")
            if let content = try? String(contentsOf: candidate, encoding: .utf8) {
                return content
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }

        let userConfig = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("claude-usage")
            .appendingPathComponent(".env")
        if let content = try? String(contentsOf: userConfig, encoding: .utf8) {
            return content
        }

        return nil
    }
}

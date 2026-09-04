import Foundation
import UsageCore

enum CodexUsageError: LocalizedError, Sendable {
    case executableNotFound
    case authenticationRequired
    case timedOut
    case processFailed
    case protocolFailure(String)
    case undecodable(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Codex not found — install the ChatGPT app or Codex CLI."
        case .authenticationRequired:
            return "Codex sign-in required — run `codex login` once."
        case .timedOut:
            return "Codex did not return usage in time."
        case .processFailed:
            return "Codex closed before returning usage."
        case .protocolFailure(let message):
            return "Codex could not return usage: \(message)"
        case .undecodable(let detail):
            return "Could not read Codex usage: \(detail)"
        }
    }
}

struct CodexUsageFetchResult: Sendable {
    let response: CodexRateLimitsResponseDTO
    let raw: Data
}

protocol CodexUsageFetching: Sendable {
    func fetch() async throws -> CodexUsageFetchResult
}

/// Reads account limits through Codex's stable app-server protocol.
///
/// Codex remains the sole owner of its cached credentials and automatic token refresh. This app
/// never reads, copies, logs, or independently rotates the user's OpenAI tokens.
struct CodexAppServerClient: CodexUsageFetching {
    private static let responseID = 1
    private static let maximumResponseBytes = 1_048_576

    private let locateExecutable: @Sendable () -> URL?
    private let timeout: Duration

    init(
        locateExecutable: @escaping @Sendable () -> URL? = { CodexExecutableLocator.locate() },
        timeout: Duration = .seconds(20)
    ) {
        self.locateExecutable = locateExecutable
        self.timeout = timeout
    }

    func fetch() async throws -> CodexUsageFetchResult {
        if let fixture = ProcessInfo.processInfo.environment["CODEX_USAGE_FIXTURE"] {
            let raw = try Data(contentsOf: URL(fileURLWithPath: fixture))
            return CodexUsageFetchResult(response: try Self.decode(raw), raw: raw)
        }

        guard let executable = locateExecutable() else {
            throw CodexUsageError.executableNotFound
        }
        return try await Self.request(executable: executable, timeout: timeout)
    }

    static func decode(_ data: Data) throws -> CodexRateLimitsResponseDTO {
        do {
            return try JSONDecoder().decode(CodexRateLimitsResponseDTO.self, from: data)
        } catch let error as DecodingError {
            throw CodexUsageError.undecodable(decodingDetail(error))
        } catch {
            throw CodexUsageError.undecodable(error.localizedDescription)
        }
    }

    /// Decodes only the matching JSON-RPC response; initialization replies and notifications are
    /// deliberately ignored.
    static func decodeResponseLine(_ data: Data) throws -> CodexUsageFetchResult? {
        let identifier: RPCIdentifier
        do {
            identifier = try JSONDecoder().decode(RPCIdentifier.self, from: data)
        } catch {
            throw CodexUsageError.undecodable("app-server emitted invalid JSON")
        }
        guard identifier.id == responseID else { return nil }

        let envelope: RateLimitsEnvelope
        do {
            envelope = try JSONDecoder().decode(RateLimitsEnvelope.self, from: data)
        } catch let error as DecodingError {
            throw CodexUsageError.undecodable(decodingDetail(error))
        }

        if let error = envelope.error {
            let message = error.message.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = message.lowercased()
            if ["auth", "credential", "login", "log in", "sign in", "chatgpt"]
                .contains(where: normalized.contains)
            {
                throw CodexUsageError.authenticationRequired
            }
            throw CodexUsageError.protocolFailure(message.isEmpty ? "unknown app-server error" : message)
        }
        guard let result = envelope.result else {
            throw CodexUsageError.protocolFailure("empty app-server response")
        }

        let raw = try JSONEncoder().encode(result)
        return CodexUsageFetchResult(response: result, raw: raw)
    }

    private static func request(executable: URL, timeout: Duration) async throws -> CodexUsageFetchResult {
        let process = Process()
        let input = Pipe()
        let output = Pipe()

        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        // App-server diagnostics can be verbose and must never become user-visible or fill a pipe.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: initializationPayload)
        } catch {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            throw CodexUsageError.processFailed
        }

        return try await withThrowingTaskGroup(of: CodexUsageFetchResult.self) { group in
            group.addTask {
                try await readResponse(
                    from: output.fileHandleForReading,
                    input: input.fileHandleForWriting
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CodexUsageError.timedOut
            }

            do {
                guard let result = try await group.next() else {
                    throw CodexUsageError.processFailed
                }
                group.cancelAll()
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                try? output.fileHandleForReading.close()
                return result
            } catch {
                group.cancelAll()
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                try? output.fileHandleForReading.close()
                throw error
            }
        }
    }

    private static func readResponse(
        from handle: FileHandle,
        input: FileHandle
    ) async throws -> CodexUsageFetchResult {
        var line = Data()
        line.reserveCapacity(4_096)
        var hasInitialized = false

        for try await byte in handle.bytes {
            try Task.checkCancellation()
            if byte == 0x0A {
                if !line.isEmpty {
                    let identifier = try JSONDecoder().decode(RPCIdentifier.self, from: line)
                    if identifier.id == 0, !hasInitialized {
                        try input.write(contentsOf: rateLimitsPayload)
                        hasInitialized = true
                    } else if let result = try decodeResponseLine(line) {
                        return result
                    }
                }
                line.removeAll(keepingCapacity: true)
                continue
            }

            line.append(byte)
            guard line.count <= maximumResponseBytes else {
                throw CodexUsageError.protocolFailure("app-server response was unexpectedly large")
            }
        }

        if !line.isEmpty, let result = try decodeResponseLine(line) {
            return result
        }
        throw CodexUsageError.processFailed
    }

    private static var initializationPayload: Data {
        Data(
            """
            {"method":"initialize","id":0,"params":{"clientInfo":{"name":"claude_usage","title":"Claude Usage","version":"1"}}}

            """.utf8
        )
    }

    private static var rateLimitsPayload: Data {
        Data(
            """
            {"method":"initialized","params":{}}
            {"method":"account/rateLimits/read","id":1}

            """.utf8
        )
    }

    private static func decodingDetail(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(let type, let context):
            return "\(path(context)) is not \(type) — \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "\(path(context)) missing \(type)"
        case .keyNotFound(let key, let context):
            return "\(path(context)) has no key '\(key.stringValue)'"
        case .dataCorrupted(let context):
            return "\(path(context)) corrupted — \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let joined = context.codingPath.map(\.stringValue).joined(separator: ".")
        return joined.isEmpty ? "<root>" : joined
    }
}

enum CodexExecutableLocator {
    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        var candidates: [URL] = []

        if let override = environment["CODEX_USAGE_CODEX_PATH"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }

        candidates += [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            homeDirectory.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            homeDirectory.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex"),
            homeDirectory.appendingPathComponent(".local/bin/codex"),
            homeDirectory.appendingPathComponent(".codex/packages/standalone/current/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]

        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("codex")
            }
        }

        var seen = Set<String>()
        return candidates.first { candidate in
            seen.insert(candidate.path).inserted && isExecutable(candidate.path)
        }
    }
}

private struct RPCIdentifier: Decodable {
    let id: Int?
}

private struct RateLimitsEnvelope: Decodable {
    struct RPCError: Decodable {
        let message: String
    }

    let result: CodexRateLimitsResponseDTO?
    let error: RPCError?
}

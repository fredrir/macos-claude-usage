import Foundation
import Testing
import UsageCore

@testable import ClaudeUsage

@Suite("Codex infrastructure")
struct CodexInfrastructureTests {
    private let now = Date(timeIntervalSinceReferenceDate: 30_000)

    @Test("Runs the app-server protocol without reading credentials")
    func appServerProtocol() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex-fixture")
        let script = #"""
            #!/bin/sh
            while IFS= read -r line; do
              case "$line" in
                *'"method":"initialize"'*)
                  printf '%s\n' '{"id":0,"result":{"userAgent":"fixture"}}'
                  ;;
                *account/rateLimits/read*)
                  printf '%s\n' '{"id":1,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":17,"windowDurationMins":300,"resetsAt":1788573723}}}}'
                  exit 0
                  ;;
              esac
            done
            """#
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let client = CodexAppServerClient(locateExecutable: { executable }, timeout: .seconds(2))
        let result = try await client.fetch()

        #expect(result.response.rateLimits?.primary?.usedPercent == 17)
    }

    @Test("Terminates an app-server that does not return usage")
    func appServerTimeout() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex-timeout-fixture")
        let script = #"""
            #!/bin/sh
            while IFS= read -r line; do
              case "$line" in
                *'"method":"initialize"'*)
                  printf '%s\n' '{"id":0,"result":{"userAgent":"fixture"}}'
                  ;;
              esac
            done
            """#
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let client = CodexAppServerClient(locateExecutable: { executable }, timeout: .milliseconds(50))
        do {
            _ = try await client.fetch()
            Issue.record("Expected the app-server request to time out")
        } catch CodexUsageError.timedOut {
            // Expected. Cleanup closes the pipe and terminates the process.
        }
    }

    @Test("Maps an app-server login error to one actionable authentication state")
    func authenticationError() throws {
        let line = Data(
            #"{ "id": 1, "error": { "code": -32000, "message": "ChatGPT login required" } }"#.utf8
        )

        do {
            _ = try CodexAppServerClient.decodeResponseLine(line)
            Issue.record("Expected an authentication error")
        } catch CodexUsageError.authenticationRequired {
            // Expected. The presentation layer tells the user to run `codex login` once.
        }
    }

    @Test("Ignores unrelated app-server messages")
    func ignoresNotifications() throws {
        let initialization = Data(#"{ "id": 0, "result": { "userAgent": "fixture" } }"#.utf8)
        let notification = Data(#"{ "method": "account/rateLimits/updated", "params": {} }"#.utf8)

        #expect(try CodexAppServerClient.decodeResponseLine(initialization) == nil)
        #expect(try CodexAppServerClient.decodeResponseLine(notification) == nil)
    }

    @Test("Finds an explicitly configured Codex executable first")
    func executableOverride() {
        let expected = "/custom/codex"
        let located = CodexExecutableLocator.locate(
            environment: ["CODEX_USAGE_CODEX_PATH": expected],
            homeDirectory: URL(fileURLWithPath: "/Users/fixture"),
            isExecutable: { $0 == expected }
        )

        #expect(located?.path == expected)
    }

    @Test("Caches Codex windows and persists request spacing")
    func repositoryCacheAndSpacing() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = SuccessfulCodexUsageClient()
        let repository = makeRepository(directory: directory, client: client, now: now)

        guard case .updated(let snapshot) = await repository.refresh() else {
            Issue.record("Expected the Codex request to update the snapshot")
            return
        }
        #expect(snapshot.buckets.map(\.title) == ["5-hour limit", "Weekly limit"])

        let restarted = makeRepository(
            directory: directory,
            client: client,
            now: now.addingTimeInterval(100)
        )
        #expect(await restarted.loadCachedSnapshot()?.buckets.map(\.utilization) == [18, 41])

        guard case .deferred(_, let restriction) = await restarted.refresh() else {
            Issue.record("Expected persisted Codex request spacing")
            return
        }
        #expect(restriction == .minimumSpacing)
        #expect(await client.requestCount == 1)
    }

    @Test("Authentication backoff avoids repeatedly invoking Codex")
    func authenticationBackoff() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = SignedOutCodexUsageClient()
        let repository = makeRepository(directory: directory, client: client, now: now)

        guard case .authenticationFailed = await repository.refresh() else {
            Issue.record("Expected the first request to report a missing sign-in")
            return
        }

        let restarted = makeRepository(
            directory: directory,
            client: client,
            now: now.addingTimeInterval(5 * 60)
        )
        guard case .deferred(let until, let restriction) = await restarted.refresh() else {
            Issue.record("Expected the persisted authentication backoff")
            return
        }
        #expect(until == now.addingTimeInterval(15 * 60))
        #expect(restriction == .authentication)
        #expect(await client.requestCount == 1)
    }

    private func makeRepository(
        directory: URL,
        client: some CodexUsageFetching,
        now: Date
    ) -> CodexUsageRepository {
        CodexUsageRepository(
            client: client,
            cacheURL: directory.appendingPathComponent("codex-usage.json"),
            pollingStateURL: directory.appendingPathComponent("codex-polling.json"),
            clock: CodexFixedDateProvider(now: now)
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexInfrastructureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }
}

private actor SuccessfulCodexUsageClient: CodexUsageFetching {
    private(set) var requestCount = 0

    func fetch() async throws -> CodexUsageFetchResult {
        requestCount += 1
        let response = CodexRateLimitsResponseDTO(
            rateLimits: CodexRateLimitDTO(
                limitId: "codex",
                primary: CodexRateLimitWindowDTO(usedPercent: 18, windowDurationMins: 300),
                secondary: CodexRateLimitWindowDTO(usedPercent: 41, windowDurationMins: 10_080)
            )
        )
        return CodexUsageFetchResult(response: response, raw: try JSONEncoder().encode(response))
    }
}

private actor SignedOutCodexUsageClient: CodexUsageFetching {
    private(set) var requestCount = 0

    func fetch() async throws -> CodexUsageFetchResult {
        requestCount += 1
        throw CodexUsageError.authenticationRequired
    }
}

private struct CodexFixedDateProvider: DateProvider {
    let now: Date
}

import Foundation
import Testing
import UsageCore

@testable import ClaudeUsage

@Suite("Usage repository")
struct UsageRepositoryTests {
    private let now = Date(timeIntervalSinceReferenceDate: 20_000)

    @Test("Persists a successful request's spacing across repository restarts")
    func persistsMinimumSpacing() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = SuccessfulUsageClient()
        let repository = makeRepository(directory: directory, client: client, now: now)

        guard case .updated(let snapshot) = await repository.refresh() else {
            Issue.record("Expected the first request to update the snapshot")
            return
        }
        #expect(snapshot.session?.utilization == 42)
        #expect(await client.requestCount == 1)

        let restarted = makeRepository(
            directory: directory,
            client: client,
            now: now.addingTimeInterval(100)
        )
        #expect(await restarted.loadCachedSnapshot()?.session?.utilization == 42)

        guard case .deferred(let until, let restriction) = await restarted.refresh() else {
            Issue.record("Expected the restarted repository to honor persisted spacing")
            return
        }
        #expect(until == now.addingTimeInterval(15 * 60))
        #expect(restriction == .minimumSpacing)
        #expect(await client.requestCount == 1)
    }

    @Test("Persists a server penalty and its safety floor across restarts")
    func persistsRateLimit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = RateLimitedUsageClient(retryAfter: 10 * 60)
        let repository = makeRepository(directory: directory, client: client, now: now)

        guard case .deferred(let until, let restriction) = await repository.refresh() else {
            Issue.record("Expected the first request to record the server penalty")
            return
        }
        // The 15-minute request floor is later than Retry-After plus its one-minute margin.
        #expect(until == now.addingTimeInterval(15 * 60))
        #expect(restriction == .serverRateLimit)

        let restarted = makeRepository(
            directory: directory,
            client: client,
            now: now.addingTimeInterval(12 * 60)
        )
        guard
            case .deferred(let restoredUntil, let restoredRestriction) =
                await restarted.refresh()
        else {
            Issue.record("Expected the restarted repository to honor the server penalty")
            return
        }
        #expect(restoredUntil == until)
        #expect(restoredRestriction == .serverRateLimit)
        #expect(await client.requestCount == 1)
    }

    private func makeRepository(
        directory: URL,
        client: some UsageFetching,
        now: Date
    ) -> UsageRepository {
        UsageRepository(
            client: client,
            cacheURL: directory.appendingPathComponent("usage.json"),
            pollingStateURL: directory.appendingPathComponent("polling.json"),
            clock: FixedDateProvider(now: now)
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }
}

private actor SuccessfulUsageClient: UsageFetching {
    private(set) var requestCount = 0

    func fetch() async throws -> UsageFetchResult {
        requestCount += 1
        let raw = Data(#"{ "five_hour": { "utilization": 42 } }"#.utf8)
        let response = try JSONDecoder().decode(UsageResponseDTO.self, from: raw)
        return UsageFetchResult(response: response, raw: raw)
    }
}

private actor RateLimitedUsageClient: UsageFetching {
    private(set) var requestCount = 0
    private let retryAfter: TimeInterval

    init(retryAfter: TimeInterval) {
        self.retryAfter = retryAfter
    }

    func fetch() async throws -> UsageFetchResult {
        requestCount += 1
        throw UsageAPIError.rateLimited(retryAfter: retryAfter)
    }
}

private struct FixedDateProvider: DateProvider {
    let now: Date
}

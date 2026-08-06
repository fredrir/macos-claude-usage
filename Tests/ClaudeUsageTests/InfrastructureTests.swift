import Foundation
import Testing

@testable import ClaudeUsage

@Suite("Infrastructure adapters")
struct InfrastructureTests {
    @Test("Retry-After accepts delay seconds")
    func retryAfterSeconds() {
        #expect(RetryAfterParser.delay(from: "120", relativeTo: .distantPast) == 120)
        #expect(RetryAfterParser.delay(from: "-5", relativeTo: .distantPast) == 0)
    }

    @Test("Retry-After accepts an HTTP date")
    func retryAfterHTTPDate() throws {
        let now = try #require(
            try? Date("2026-08-06T12:00:00Z", strategy: .iso8601)
        )

        let delay = try #require(
            RetryAfterParser.delay(
                from: "Thu, 06 Aug 2026 12:10:00 GMT",
                relativeTo: now
            )
        )
        #expect(abs(delay - 10 * 60) < 0.001)
    }

    @Test("API decoding describes structural schema changes")
    func apiRejectsUnknownRoot() {
        #expect(throws: UsageAPIError.self) {
            try AnthropicUsageClient.decode(Data(#"{ "replacement": true }"#.utf8))
        }
    }

    @Test("Reset copy uses an injected reference date")
    func resetFormatting() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        #expect(
            ResetFormatter.text(
                for: now.addingTimeInterval(2 * 3600 + 15 * 60),
                relativeTo: now
            ) == "Resets in 2h 15m"
        )
    }
}

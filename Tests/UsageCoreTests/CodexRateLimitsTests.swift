import Foundation
import Testing

@testable import UsageCore

@Suite("Codex rate limits")
struct CodexRateLimitsTests {
    private let mapper = CodexRateLimitsMapper()

    @Test("Decodes main and model-specific windows while excluding Spark")
    func decodesMultiBucketResponse() throws {
        let response = try JSONDecoder().decode(
            CodexRateLimitsResponseDTO.self,
            from: Data(
                #"""
                {
                  "rateLimits": null,
                  "rateLimitsByLimitId": {
                    "codex_spark": {
                      "limitId": "codex_spark",
                      "limitName": "Codex Spark",
                      "primary": {
                        "usedPercent": 21,
                        "windowDurationMins": 300,
                        "resetsAt": 1788573723
                      },
                      "secondary": {
                        "usedPercent": 46,
                        "windowDurationMins": 10080,
                        "resetsAt": 1789160523
                      }
                    },
                    "codex": {
                      "limitId": "codex",
                      "limitName": null,
                      "primary": {
                        "usedPercent": 12,
                        "windowDurationMins": 300,
                        "resetsAt": 1788570000
                      },
                      "secondary": {
                        "usedPercent": 34,
                        "windowDurationMins": 10080,
                        "resetsAt": 1789160000
                      }
                    },
                    "codex_mini": {
                      "limitId": "codex_mini",
                      "limitName": "Codex Mini",
                      "primary": {
                        "usedPercent": 18,
                        "windowDurationMins": 300,
                        "resetsAt": 1788571000
                      },
                      "secondary": {
                        "usedPercent": 38,
                        "windowDurationMins": 10080,
                        "resetsAt": 1789161000
                      }
                    }
                  }
                }
                """#.utf8
            )
        )

        let buckets = mapper.buckets(from: response)

        #expect(
            buckets.map(\.title) == [
                "5-hour limit",
                "Weekly limit",
                "5-hour limit (Codex Mini)",
                "Weekly limit (Codex Mini)",
            ]
        )
        #expect(buckets.map(\.utilization) == [12, 34, 18, 38])
        #expect(buckets.allSatisfy { $0.role == .other })
        #expect(buckets[0].resetsAt == Date(timeIntervalSince1970: 1_788_570_000))
    }

    @Test("Uses the backward-compatible single-bucket response")
    func fallsBackToSingleBucket() {
        let response = CodexRateLimitsResponseDTO(
            rateLimits: CodexRateLimitDTO(
                limitId: "codex",
                primary: CodexRateLimitWindowDTO(
                    usedPercent: 27,
                    windowDurationMins: 90
                ),
                secondary: CodexRateLimitWindowDTO(
                    usedPercent: 39,
                    windowDurationMins: 7 * 24 * 60
                )
            )
        )

        let buckets = mapper.buckets(from: response)

        #expect(buckets.map(\.title) == ["90-minute limit", "Weekly limit"])
        #expect(buckets.map(\.utilization) == [27, 39])
    }

    @Test("Derives labels from arbitrary server durations")
    func durationLabels() {
        #expect(CodexRateLimitsMapper.title(forDurationMinutes: 60) == "1-hour limit")
        #expect(CodexRateLimitsMapper.title(forDurationMinutes: 300) == "5-hour limit")
        #expect(CodexRateLimitsMapper.title(forDurationMinutes: 2_880) == "2-day limit")
        #expect(CodexRateLimitsMapper.title(forDurationMinutes: 10_080) == "Weekly limit")
    }

    @Test("Skips incomplete windows without discarding valid siblings")
    func skipsIncompleteWindows() {
        let response = CodexRateLimitsResponseDTO(
            rateLimits: CodexRateLimitDTO(
                limitId: "codex",
                primary: CodexRateLimitWindowDTO(usedPercent: 12, windowDurationMins: 0),
                secondary: CodexRateLimitWindowDTO(usedPercent: 44, windowDurationMins: 10_080)
            )
        )

        #expect(mapper.buckets(from: response).map(\.title) == ["Weekly limit"])
    }

    @Test("Rejects an unknown response shape")
    func rejectsUnknownRoot() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                CodexRateLimitsResponseDTO.self,
                from: Data(#"{ "replacement": true }"#.utf8)
            )
        }
    }
}

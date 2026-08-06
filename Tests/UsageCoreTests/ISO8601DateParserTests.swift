import Foundation
import Testing

@testable import UsageCore

@Suite("ISO-8601 parsing")
struct ISO8601DateParserTests {
    @Test("Accepts whole-second, millisecond, and microsecond timestamps")
    func acceptsEndpointPrecision() throws {
        let whole = try #require(ISO8601DateParser.parse("2026-08-06T21:00:00+00:00"))
        let milliseconds = try #require(ISO8601DateParser.parse("2026-08-06T21:00:00.290+00:00"))
        let microseconds = try #require(ISO8601DateParser.parse("2026-08-06T21:00:00.290962+00:00"))

        #expect(abs(milliseconds.timeIntervalSince(whole) - 0.290) < 0.000_001)
        #expect(abs(microseconds.timeIntervalSince(whole) - 0.290_962) < 0.000_001)
    }

    @Test("Returns nil for absent and malformed timestamps")
    func rejectsInvalidInput() {
        #expect(ISO8601DateParser.parse(nil) == nil)
        #expect(ISO8601DateParser.parse("not-a-date") == nil)
    }
}

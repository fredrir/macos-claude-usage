import Foundation
import Testing

@testable import UsageCore

@Suite("Usage response mapping")
struct UsageResponseMapperTests {
    private let mapper = UsageResponseMapper()

    @Test("Preserves the established bucket order")
    func preservesOrdering() {
        let response = UsageResponseDTO(
            limits: [
                entry(kind: "weekly_scoped", percent: 51, modelID: "other-id", name: "Other"),
                entry(kind: "weekly_all", percent: 22),
                entry(kind: "weekly_scoped", percent: 33, modelID: "fable-id", name: "Fable 3"),
                entry(kind: "session", percent: 11),
            ]
        )

        let buckets = mapper.buckets(from: response)

        #expect(
            buckets.map(\.id) == [
                "session",
                "weekly_all",
                "scoped:fable-id",
                "scoped:other-id",
            ])
        #expect(buckets.map(\.role) == [.session, .weeklyAll, .fable, .other])
    }

    @Test("Structured limits take precedence over top-level duplicates")
    func limitsTakePrecedence() {
        let response = UsageResponseDTO(
            fiveHour: UsageWindowDTO(utilization: 91),
            sevenDay: UsageWindowDTO(utilization: 92),
            limits: [
                entry(kind: "session", percent: 12, severity: .normal),
                entry(kind: "weekly_all", percent: 34, severity: .warning),
            ]
        )

        let buckets = mapper.buckets(from: response)

        #expect(buckets.count == 2)
        #expect(buckets[0].utilization == 12)
        #expect(buckets[0].severity == .normal)
        #expect(buckets[1].utilization == 34)
        #expect(buckets[1].severity == .warning)
    }

    @Test("Falls back to top-level windows when structured equivalents are absent")
    func fallsBackToTopLevelWindows() {
        let response = UsageResponseDTO(
            fiveHour: UsageWindowDTO(utilization: 41),
            sevenDay: UsageWindowDTO(utilization: 62),
            sevenDayOpus: UsageWindowDTO(utilization: 73),
            sevenDaySonnet: UsageWindowDTO(utilization: 84),
            limits: []
        )

        let buckets = mapper.buckets(from: response)

        #expect(
            buckets.map(\.id) == [
                "session",
                "weekly_all",
                "seven_day_opus",
                "seven_day_sonnet",
            ])
        #expect(buckets.map(\.utilization) == [41, 62, 73, 84])
    }

    @Test("A structured entry without a percentage permits its fallback")
    func nilStructuredPercentageUsesFallback() {
        let response = UsageResponseDTO(
            fiveHour: UsageWindowDTO(utilization: 45),
            limits: [entry(kind: "session", percent: nil)]
        )

        #expect(mapper.buckets(from: response).session?.utilization == 45)
    }

    @Test("Clamps out-of-range percentages")
    func clampsPercentages() {
        let response = UsageResponseDTO(
            fiveHour: UsageWindowDTO(utilization: -20),
            sevenDay: UsageWindowDTO(utilization: 140)
        )

        let buckets = mapper.buckets(from: response)

        #expect(buckets.map(\.utilization) == [0, 100])
        #expect(buckets.map(\.remaining) == [100, 0])
        #expect(buckets.map(\.usedFraction) == [0, 1])
    }

    @Test("Uses model IDs so equal display names do not collide")
    func usesStableModelIDs() {
        let response = UsageResponseDTO(limits: [
            entry(kind: "weekly_scoped", percent: 10, modelID: "model-a", name: "Shared Name"),
            entry(kind: "weekly_scoped", percent: 20, modelID: "model-b", name: "Shared Name"),
        ])

        let buckets = mapper.buckets(from: response)

        #expect(buckets.map(\.id) == ["scoped:model-a", "scoped:model-b"])
        #expect(buckets.map(\.utilization) == [10, 20])
    }

    @Test("Maps reset timestamps and fetched time into a snapshot")
    func createsSnapshot() throws {
        let fetchedAt = Date(timeIntervalSinceReferenceDate: 100)
        let response = UsageResponseDTO(
            fiveHour: UsageWindowDTO(
                utilization: 30,
                resetsAt: "2026-08-06T21:00:00.290962+00:00"
            )
        )

        let snapshot = mapper.map(response, fetchedAt: fetchedAt)

        #expect(snapshot.fetchedAt == fetchedAt)
        #expect(try #require(snapshot.session?.resetsAt) == ISO8601DateParser.parse("2026-08-06T21:00:00.290962+00:00"))
    }

    @Test("Uses server severity before threshold fallback")
    func severityPrecedence() {
        let normalAtHighUsage = UsageBucket(
            id: "normal",
            title: "Normal",
            utilization: 99,
            resetsAt: nil,
            severity: .normal,
            role: .other
        )
        let unknownAtHighUsage = UsageBucket(
            id: "unknown",
            title: "Unknown",
            utilization: 99,
            resetsAt: nil,
            severity: .unknown("future"),
            role: .other
        )

        #expect(normalAtHighUsage.level == .normal)
        #expect(unknownAtHighUsage.level == .critical)
    }

    private func entry(
        kind: String,
        percent: Double?,
        severity: UsageSeverity? = nil,
        modelID: String? = nil,
        name: String? = nil
    ) -> LimitEntryDTO {
        LimitEntryDTO(
            kind: kind,
            percent: percent,
            severity: severity,
            scope: modelID == nil && name == nil
                ? nil
                : .init(model: .init(id: modelID, displayName: name))
        )
    }
}

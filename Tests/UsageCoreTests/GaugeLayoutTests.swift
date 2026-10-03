import Foundation
import Testing

@testable import UsageCore

@Suite("Gauge layout")
struct GaugeLayoutTests {
    @Test("First discovery keeps the classic bar gauges and lists every limit in the menu")
    func firstDiscoveryKeepsTheClassicGauges() {
        var layout = GaugeLayout()
        layout.discover(claudeBuckets, from: .claude)
        layout.discover(codexBuckets, from: .codex)

        #expect(
            layout.entries(in: .menuBar).map(\.id) == ["claude/session", "claude/scoped:fable", "codex/codex-5h"]
        )
        #expect(layout.entries(in: .menu) == layout.entries)
        #expect(layout.entries.count == 6)
    }

    @Test("Claude gauges stay ahead of Codex even when Codex answers first")
    func providersAreGroupedInTheirUsualOrder() {
        var layout = GaugeLayout()
        layout.discover(codexBuckets, from: .codex)
        layout.discover(claudeBuckets, from: .claude)

        #expect(layout.entries.map(\.provider) == [.claude, .claude, .claude, .claude, .codex, .codex])
    }

    @Test("Windows that show up later join their provider, hidden")
    func laterWindowsStartHidden() {
        var layout = GaugeLayout()
        layout.discover(claudeBuckets, from: .claude)
        layout.discover(codexBuckets, from: .codex)

        layout.discover(claudeBuckets + [bucket("scoped:haiku", role: .other)], from: .claude)

        let added = layout.entries[4]
        #expect(added.id == "claude/scoped:haiku")
        #expect(added.placements.isEmpty)
    }

    @Test("Rediscovery keeps the user's choices and refreshes titles")
    func rediscoveryKeepsChoices() {
        var layout = GaugeLayout()
        layout.discover(claudeBuckets, from: .claude)
        layout.setShown(false, in: .menuBar, for: "claude/session")
        layout.setShown(true, in: .menuBar, for: "claude/weekly_all")

        layout.discover([bucket("session", role: .session, title: "Five-hour session")], from: .claude)

        #expect(layout.entries.first?.title == "Five-hour session")
        #expect(layout.entries(in: .menuBar).map(\.id) == ["claude/weekly_all", "claude/scoped:fable"])
    }

    @Test("The last menu bar gauge cannot be hidden, but the menu may be emptied")
    func lastMenuBarGaugeStays() throws {
        var layout = GaugeLayout()
        layout.discover([bucket("session", role: .session)], from: .claude)
        let only = try #require(layout.entries.first)

        #expect(layout.isLocked(only, in: .menuBar))
        #expect(!layout.isLocked(only, in: .menu))

        layout.setShown(false, in: .menuBar, for: only.id)
        layout.setShown(false, in: .menu, for: only.id)

        #expect(layout.entries(in: .menuBar).count == 1)
        #expect(layout.entries(in: .menu).isEmpty)
    }

    @Test("Bar and menu are chosen independently, e.g. weekly limits in the bar and more in the menu")
    func placementsAreIndependent() {
        var layout = GaugeLayout()
        layout.discover(claudeBuckets, from: .claude)
        layout.discover(codexBuckets, from: .codex)

        layout.setShown(true, in: .menuBar, for: "claude/weekly_all")
        layout.setShown(true, in: .menuBar, for: "codex/codex-weekly")
        for id in ["claude/session", "claude/scoped:fable", "codex/codex-5h"] {
            layout.setShown(false, in: .menuBar, for: id)
        }
        for id in ["claude/scoped:fable", "claude/scoped:opus", "codex/codex-5h"] {
            layout.setShown(false, in: .menu, for: id)
        }

        #expect(layout.entries(in: .menuBar).map(\.id) == ["claude/weekly_all", "codex/codex-weekly"])
        #expect(
            layout.entries(in: .menu).map(\.id) == ["claude/session", "claude/weekly_all", "codex/codex-weekly"]
        )
    }

    @Test("Moving matches SwiftUI's onMove offsets")
    func moveFollowsListSemantics() {
        var layout = GaugeLayout()
        layout.discover(claudeBuckets, from: .claude)
        layout.discover(codexBuckets, from: .codex)

        layout.move(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        #expect(layout.entries.map(\.bucketID).prefix(2) == ["codex-5h", "session"])

        layout.move(fromOffsets: IndexSet(integer: 0), toOffset: 6)
        #expect(layout.entries.last?.bucketID == "codex-5h")

        layout.move(fromOffsets: IndexSet([0, 1]), toOffset: 3)
        #expect(layout.entries.map(\.bucketID).prefix(3) == ["scoped:fable", "session", "weekly_all"])
    }

    @Test("Menu sections follow the first menu limit of each provider")
    func providerOrderFollowsMenuLimits() {
        var layout = GaugeLayout()
        layout.discover(claudeBuckets, from: .claude)
        layout.discover(codexBuckets, from: .codex)
        #expect(layout.menuProviderOrder == [.claude, .codex])

        layout.move(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        #expect(layout.menuProviderOrder == [.codex, .claude])

        layout.setShown(false, in: .menu, for: "codex/codex-5h")
        layout.setShown(false, in: .menu, for: "codex/codex-weekly")
        #expect(layout.menuProviderOrder == [.claude, .codex])
    }

    @Test("A layout survives an encode/decode restart")
    func persistsAcrossRestart() throws {
        var layout = GaugeLayout()
        layout.discover(claudeBuckets, from: .claude)
        layout.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        let restored = try JSONDecoder().decode(GaugeLayout.self, from: JSONEncoder().encode(layout))

        #expect(restored == layout)
    }

    private var claudeBuckets: [UsageBucket] {
        [
            bucket("session", role: .session),
            bucket("weekly_all", role: .weeklyAll),
            bucket("scoped:fable", role: .fable),
            bucket("scoped:opus", role: .other),
        ]
    }

    private var codexBuckets: [UsageBucket] {
        [bucket("codex-5h", role: .other), bucket("codex-weekly", role: .other)]
    }

    private func bucket(_ id: String, role: UsageRole, title: String? = nil) -> UsageBucket {
        UsageBucket(id: id, title: title ?? id, utilization: 10, resetsAt: nil, severity: nil, role: role)
    }
}

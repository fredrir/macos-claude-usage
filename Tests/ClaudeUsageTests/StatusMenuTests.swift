import AppKit
import SwiftUI
import Testing
import UsageCore

@testable import ClaudeUsage

@Suite("Status menu")
@MainActor
struct StatusMenuTests {
    @Test("Passive refresh status has no menu copy")
    func passiveRefreshStatusIsHidden() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let store = UsageStore(
            fixture: [],
            lastUpdated: now,
            status: .throttled(until: now.addingTimeInterval(300)),
            clock: FixedTestDateProvider(now: now)
        )

        #expect(store.statusMessage == nil)
    }

    @Test("Rate-limit copy omits last-updated text")
    func rateLimitStatusHasOnlyActionableCopy() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let store = UsageStore(
            fixture: [],
            lastUpdated: now,
            status: .rateLimited(until: now.addingTimeInterval(300)),
            clock: FixedTestDateProvider(now: now)
        )

        #expect(store.statusMessage == "Rate limited — retrying in 5m")
    }

    @Test("Settings and Quit stay AppKit-drawn items so the menu highlights them itself")
    func commandsAreNotViewBacked() {
        let menu = populatedMenu()

        let settings = try? #require(menu.items.first { $0.title == "Settings…" })
        let quit = try? #require(menu.items.first { $0.title == "Quit" })

        #expect(settings?.view == nil)
        #expect(settings?.isEnabled == true)
        #expect(settings?.keyEquivalent == ",")
        #expect(settings?.keyEquivalentModifierMask == .command)

        #expect(quit?.view == nil)
        #expect(quit?.isEnabled == true)
        #expect(quit?.keyEquivalent == "q")
        #expect(quit?.keyEquivalentModifierMask == .command)
    }

    @Test("Usage rows are disabled so arrow keys step past them to the commands")
    func usageRowsAreNotFocusable() {
        let menu = populatedMenu()
        let rows = menu.items.filter { $0.view != nil }

        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.isEnabled == false })
    }

    /// AppKit refuses to resize an item view once the menu is tracking, so anything that reaches its
    /// size lazily shows up as a clipped row in the open menu.
    @Test("Every row is sized before the menu opens")
    func rowsAreSizedUpFront() {
        let menu = populatedMenu()
        let rows = menu.items.compactMap(\.view)

        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.frame.height > 0 })
        #expect(rows.allSatisfy { $0.frame.width == MenuMetrics.contentWidth })
    }

    @Test("Both providers are listed, separated from each other and from the commands")
    func menuIsSectioned() {
        let menu = populatedMenu()
        let separators = menu.items.filter(\.isSeparatorItem)

        #expect(separators.count == 2)
        #expect(menu.items.last?.title == "Quit")
    }

    private func populatedMenu() -> NSMenu {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let buckets = [
            UsageBucket(
                id: "claude-session",
                title: "Current session",
                utilization: 20,
                resetsAt: now.addingTimeInterval(3_600),
                severity: nil,
                role: .session
            )
        ]
        let codexBuckets = [
            UsageBucket(
                id: "codex-weekly",
                title: "Weekly limit",
                utilization: 30,
                resetsAt: now.addingTimeInterval(86_400),
                severity: nil,
                role: .other
            )
        ]
        let store = UsageStore(
            fixture: buckets,
            codexBuckets: codexBuckets,
            lastUpdated: now,
            clock: FixedTestDateProvider(now: now)
        )

        let responder = TestResponder()
        let menu = NSMenu()
        UsageMenuBuilder.populate(
            menu,
            from: store,
            actions: UsageMenuBuilder.Actions(
                refreshClaude: {},
                refreshCodex: {},
                signInClaude: nil,
                signInCodex: nil,
                settings: (target: responder, action: #selector(TestResponder.noop)),
                quit: (target: responder, action: #selector(TestResponder.noop))
            )
        )
        return menu
    }
}

private final class TestResponder: NSObject {
    @objc func noop() {}
}

private struct FixedTestDateProvider: DateProvider {
    let now: Date
}

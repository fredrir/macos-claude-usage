import AppKit
import SwiftUI
import Testing
import UsageCore

@testable import ClaudeUsage

@Suite("Dropdown layout")
@MainActor
struct DropdownLayoutTests {
    @Test("Passive refresh status has no dropdown copy")
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

    @Test("A short dropdown stays visible without a fixed blank viewport")
    func shortDropdownUsesContentHeight() {
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
        let hosting = NSHostingView(rootView: DropdownView(store: store))

        hosting.frame = NSRect(x: 0, y: 0, width: 292, height: 700)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let size = hosting.fittingSize
        window.orderOut(nil)

        #expect(size.height >= 250)
        #expect(size.height < 400)
    }
}

private struct FixedTestDateProvider: DateProvider {
    let now: Date
}

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

    @Test("With nothing signed in the gauge keeps its shape, greyed out")
    func emptyGaugeIsGreyedOut() throws {
        let bitmap = try rasterize(GaugeRenderer.image(for: [.empty, .empty, .empty]), scale: 2)
        let slotWidth = bitmap.pixelsWide / 3

        for slot in 0..<3 {
            let left = slot * slotWidth
            let rows = paintedRows(in: bitmap, columns: left..<(left + slotWidth))
            #expect(rows.count == 7, "slot \(slot) drew \(rows.count) rows")
        }

        let live = try rasterize(
            GaugeRenderer.image(for: [.usage(fullBucket)]),
            scale: 2
        )
        #expect(strongestAlpha(in: bitmap) < strongestAlpha(in: live))
    }

    @Test("A gauge with usage left paints only the rows it still has")
    func partlyUsedGaugeHidesSpentRows() throws {
        let halfUsed = UsageBucket(
            id: "claude-session",
            title: "Current session",
            utilization: 50,
            resetsAt: nil,
            severity: nil,
            role: .session
        )

        let bitmap = try rasterize(
            GaugeRenderer.image(for: [.usage(halfUsed)]),
            scale: 2
        )

        #expect(paintedRows(in: bitmap, columns: 0..<bitmap.pixelsWide).count == 4)
    }

    @Test("A gauge the account has used up disappears, unlike one with no account")
    func exhaustedGaugeDisappears() throws {
        let exhausted = UsageBucket(
            id: "claude-session",
            title: "Current session",
            utilization: 100,
            resetsAt: nil,
            severity: nil,
            role: .session
        )

        let present = try rasterize(GaugeRenderer.image(for: [.usage(exhausted)]), scale: 2)
        let missing = try rasterize(GaugeRenderer.image(for: [.empty]), scale: 2)

        #expect(paintedRows(in: present, columns: 0..<present.pixelsWide).isEmpty)
        #expect(paintedRows(in: missing, columns: 0..<missing.pixelsWide).count == 7)
    }

    private var fullBucket: UsageBucket {
        UsageBucket(
            id: "claude-session",
            title: "Current session",
            utilization: 0,
            resetsAt: nil,
            severity: nil,
            role: .session
        )
    }

    private func strongestAlpha(in bitmap: NSBitmapImageRep) -> CGFloat {
        (0..<bitmap.pixelsWide).reduce(0) { widest, x in
            max(widest, (0..<bitmap.pixelsHigh).reduce(0) { max($0, alpha(bitmap, x: x, y: $1)) })
        }
    }

    private func rasterize(_ image: NSImage, scale: Int) throws -> NSBitmapImageRep {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(image.size.width) * scale,
                pixelsHigh: Int(image.size.height) * scale,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        bitmap.size = image.size

        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        return bitmap
    }

    private func alpha(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
        bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    private func paintedRows(
        in bitmap: NSBitmapImageRep,
        columns: Range<Int>
    ) -> [ClosedRange<Int>] {
        var rows: [ClosedRange<Int>] = []
        var start: Int?

        for y in 0..<bitmap.pixelsHigh {
            let painted = columns.contains { alpha(bitmap, x: $0, y: y) > 0.05 }
            switch (painted, start) {
            case (true, nil): start = y
            case (false, .some(let first)):
                rows.append(first...(y - 1))
                start = nil
            default: break
            }
        }
        if let start { rows.append(start...(bitmap.pixelsHigh - 1)) }

        return rows
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

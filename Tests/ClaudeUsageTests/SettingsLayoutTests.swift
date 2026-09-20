import AppKit
import SwiftUI
import Testing
import UsageCore

@testable import ClaudeUsage

@Suite("Settings layout")
@MainActor
struct SettingsLayoutTests {
    @Test("Settings content has a useful intrinsic window size")
    func contentSize() {
        let store = UsageStore(
            fixture: [],
            lastUpdated: .now,
            pollInterval: 30 * 60,
            clock: SettingsTestDateProvider(now: .now)
        )
        let launchAtLogin = LaunchAtLoginModel(
            service: FixedLaunchAtLoginService(isEnabled: false)
        )
        let hosting = NSHostingView(
            rootView: SettingsView(store: store, launchAtLogin: launchAtLogin)
        )

        hosting.layoutSubtreeIfNeeded()

        #expect(hosting.fittingSize.width >= 400)
        #expect(hosting.fittingSize.height >= 120)
    }

    /// The app draws no menu bar, so this item exists purely to give ⌘W somewhere to land.
    @Test("Command-W is routed to the focused window, as on every other Mac app")
    func closeCommandIsWiredToTheKeyWindow() throws {
        let fileMenu = try #require(AppMainMenu.make().items.first?.submenu)
        let close = try #require(fileMenu.items.first { $0.keyEquivalent == "w" })

        #expect(close.keyEquivalentModifierMask == .command)
        #expect(close.action == #selector(NSWindow.performClose(_:)))
        #expect(close.target == nil, "a nil target is what sends this down the responder chain")
    }
}

private struct SettingsTestDateProvider: DateProvider {
    let now: Date
}

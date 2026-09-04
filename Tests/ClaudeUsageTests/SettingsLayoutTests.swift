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
}

private struct SettingsTestDateProvider: DateProvider {
    let now: Date
}

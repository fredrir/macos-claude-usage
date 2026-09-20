import AppKit
import Combine
import SwiftUI
import UsageCore

@MainActor
final class StatusMenuController: NSObject {
    private let store: UsageStore
    private let openSettings: () -> Void
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?

    init(store: UsageStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.setAccessibilityLabel("Claude Usage")

        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateStatusItem() }
        }

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let items = [store.buckets.session, store.buckets.fable]
            .compactMap { $0 }
            .map { GaugeRenderer.Item(bucket: $0) }

        var rendered: NSImage?
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            rendered = GaugeRenderer.image(for: items, dimmed: store.isStale)
        }
        button.image = rendered
        button.toolTip = tooltip
        button.setAccessibilityValue(tooltip)
    }

    private var tooltip: String {
        var lines = store.buckets.map { "\($0.title): \(Int($0.remaining.rounded()))% left" }
        if let message = store.statusMessage { lines.append(message) }
        return lines.isEmpty ? "Claude Usage" : lines.joined(separator: "\n")
    }

    @objc private func showSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openSettings()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

extension StatusMenuController: @MainActor NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        store.refreshIfStale()

        UsageMenuBuilder.populate(
            menu,
            from: store,
            actions: UsageMenuBuilder.Actions(
                refreshClaude: { [store] in store.refreshManually() },
                refreshCodex: { [store] in store.refreshManually() },
                signInClaude: store.claudeIsSignedIn ? nil : { [store] in store.signInClaude() },
                signInCodex: store.codexIsSignedIn ? nil : { [store] in store.signInCodex() },
                settings: (target: self, action: #selector(showSettings)),
                quit: (target: self, action: #selector(quit))
            )
        )
    }
}

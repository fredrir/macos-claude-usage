import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI
import UsageCore

@MainActor
final class StatusMenuController: NSObject {
    private let store: UsageStore
    private let openSettings: () -> Void
    private let statusItem: NSStatusItem
    let menu = NSMenu()
    private var isMenuOpen = false
    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?
    private var shortcutTask: Task<Void, Never>?

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

        // Dispatch rather than RunLoop.main so updates still land while the menu is tracking.
        store.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.storeDidChange() }
            .store(in: &cancellables)

        shortcutTask = Task { [weak self] in
            for await _ in KeyboardShortcuts.events(.keyDown, for: .toggleMenu) {
                self?.toggleMenu()
            }
        }

        updateStatusItem()
    }

    private func toggleMenu() {
        if isMenuOpen {
            menu.cancelTracking()
        } else {
            // performClick blocks until the menu closes; inside a main queue block that stalls the main actor too.
            RunLoop.main.perform { [weak self] in
                MainActor.assumeIsolated { self?.statusItem.button?.performClick(nil) }
            }
        }
    }

    private func storeDidChange() {
        updateStatusItem()
        if isMenuOpen && !store.isRefreshing {
            rebuildMenu()
        }
    }

    private func rebuildMenu() {
        UsageMenuBuilder.populate(
            menu,
            from: store,
            actions: UsageMenuBuilder.Actions(
                refresh: { [store] in store.refreshManually() },
                signInClaude: store.claudeIsSignedIn ? nil : { [store] in store.signInClaude() },
                signInCodex: store.codexIsSignedIn ? nil : { [store] in store.signInCodex() },
                settings: (target: self, action: #selector(showSettings)),
                quit: (target: self, action: #selector(quit))
            )
        )
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let slots =
            store.gaugeLayout.entries(in: .menuBar).map { slot(for: store.bucket(for: $0)) }
            + store.creditProviders(in: .menuBar).map {
                GaugeRenderer.Slot.credit(fraction: store.creditFraction(for: $0))
            }

        var rendered: NSImage?
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            rendered = GaugeRenderer.image(for: slots)
        }
        button.image = rendered
        button.toolTip = tooltip
        button.setAccessibilityValue(tooltip)
    }

    private func slot(for bucket: UsageBucket?) -> GaugeRenderer.Slot {
        guard let bucket else { return .empty }
        return .usage(bucket)
    }

    private var tooltip: String {
        var lines = store.gaugeLayout.entries(in: .menuBar).compactMap { entry in
            store.bucket(for: entry).map {
                "\(entry.provider.displayName) \($0.title): \(Int($0.remaining.rounded()))% left"
            }
        }
        lines += store.creditProviders(in: .menuBar).map {
            "\($0.displayName) credits: \(CreditFormatter.text(for: store.credits(for: $0)))"
        }
        lines += [store.statusMessage, store.codexStatusMessage].compactMap(\.self)

        guard lines.isEmpty else { return lines.joined(separator: "\n") }
        return store.claudeIsSignedIn || store.codexIsSignedIn
            ? "Claude Usage"
            : "Claude Usage — not signed in"
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
        Task { await store.refreshAuthState() }
        store.refreshIfStale()
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }
}

extension KeyboardShortcuts.Name {
    static let toggleMenu = Self("toggleMenu")
}

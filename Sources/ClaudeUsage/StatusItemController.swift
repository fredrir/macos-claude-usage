import AppKit
import Combine
import SwiftUI

/// Owns the menu bar item and the popover.
///
/// AppKit rather than SwiftUI's `MenuBarExtra`: the collapsed label is a custom-drawn pair of
/// gauges, and `MenuBarExtra` only renders `Text`/`Image` reliably in its label position.
@MainActor
final class StatusItemController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store: UsageStore
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?

    init(store: UsageStore) {
        self.store = store

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: DropdownView(store: store))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly

            // A light/dark switch must repaint the bitmap, not just re-composite it.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.render() }
            }
        }

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)

        render()
    }

    private func render() {
        let items = [store.buckets.session, store.buckets.fable]
            .compactMap { $0 }
            .map { GaugeRenderer.Item(bucket: $0) }

        statusItem.button?.image = GaugeRenderer.image(for: items, dimmed: store.isStale)
        statusItem.button?.toolTip = tooltip
    }

    private var tooltip: String {
        var lines = store.buckets.map {
            "\($0.title): \(Int($0.remaining.rounded()))% left"
        }
        if let message = store.statusMessage { lines.append(message) }
        return lines.isEmpty ? "Claude Usage" : lines.joined(separator: "\n")
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        store.refreshIfStale()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

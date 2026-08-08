import AppKit
import SwiftUI
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    fileprivate let store = UsageStore()
    fileprivate let launchAtLogin = LaunchAtLoginModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--dump") {
            dumpBuckets()
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--screenshot") {
            let path = CommandLine.arguments.dropFirst(index + 1).first ?? "docs/screenshots"
            do {
                try Screenshots.write(into: URL(fileURLWithPath: path))
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }

        store.start()
    }

    /// Prints the resolved windows and exits — lets the data path be checked against
    /// `/usage` without reading pixels out of the menu bar.
    private func dumpBuckets() {
        Task {
            do {
                let result = try await AnthropicUsageClient().fetch()
                let buckets = UsageResponseMapper().buckets(from: result.response)
                if buckets.isEmpty {
                    print("No populated limit windows in the response.")
                }
                for bucket in buckets {
                    let title = bucket.title.padding(toLength: 30, withPad: " ", startingAt: 0)
                    let used = String(format: "%5.1f%% used", bucket.utilization)
                    let left = String(format: "%5.1f%% left", bucket.remaining)
                    let reset =
                        ResetFormatter.text(for: bucket.resetsAt, relativeTo: .now)
                        ?? "no reset time"
                    print("\(title)  \(used)  \(left)   \(reset)")
                }
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
            exit(0)
        }
    }
}

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarDropdownContent(
                store: delegate.store,
                launchAtLogin: delegate.launchAtLogin
            )
        } label: {
            MenuBarGaugeLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarGaugeLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @ObservedObject var store: UsageStore

    var body: some View {
        Image(nsImage: image)
            .renderingMode(.original)
            .help(tooltip)
            .accessibilityLabel("Claude Usage")
            .accessibilityValue(tooltip)
    }

    private var image: NSImage {
        let items = [store.buckets.session, store.buckets.fable]
            .compactMap { $0 }
            .map { GaugeRenderer.Item(bucket: $0) }

        let appearanceName: NSAppearance.Name = switch (colorScheme, colorSchemeContrast) {
        case (.dark, .increased): .accessibilityHighContrastDarkAqua
        case (.light, .increased): .accessibilityHighContrastAqua
        case (.dark, _): .darkAqua
        case (.light, _): .aqua
        @unknown default: .aqua
        }
        guard let appearance = NSAppearance(named: appearanceName) else {
            return GaugeRenderer.image(for: items, dimmed: store.isStale)
        }

        var renderedImage: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            renderedImage = GaugeRenderer.image(for: items, dimmed: store.isStale)
        }
        return renderedImage ?? GaugeRenderer.image(for: items, dimmed: store.isStale)
    }

    private var tooltip: String {
        var lines = store.buckets.map {
            "\($0.title): \(Int($0.remaining.rounded()))% left"
        }
        if let message = store.statusMessage { lines.append(message) }
        return lines.isEmpty ? "Claude Usage" : lines.joined(separator: "\n")
    }
}

private struct MenuBarDropdownContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginModel

    var body: some View {
        DropdownView(store: store, launchAtLogin: launchAtLogin)
            .onAppear { store.refreshIfStale() }
    }
}

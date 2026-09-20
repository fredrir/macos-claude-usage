import AppKit
import SwiftUI
import UsageCore

@main
enum ClaudeUsageApp {
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        application.delegate = delegate
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    private let launchAtLogin = LaunchAtLoginModel()
    private var statusMenu: StatusMenuController?
    private var openSettings: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        if !Self.isCommandLineInvocation && Self.hasRunningSibling {
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--dump") {
            dumpBuckets()
            return
        }

        if CommandLine.arguments.contains("--dump-codex") {
            dumpCodexBuckets()
            return
        }

        if CommandLine.arguments.contains("--verify-refresh") {
            exit(RefreshProbe.run() ? 0 : 1)
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

        let scenes = NSHostingSceneRepresentation {
            Settings {
                SettingsView(store: store, launchAtLogin: launchAtLogin)
            }
            .windowResizability(.contentSize)
        }
        NSApplication.shared.addSceneRepresentation(scenes)
        openSettings = { scenes.environment.openSettings() }

        statusMenu = StatusMenuController(store: store) { [weak self] in
            self?.openSettings?()
        }

        launchAtLogin.synchronizeRegistration()
        store.start()
    }

    private static var isCommandLineInvocation: Bool {
        CommandLine.arguments.contains("--dump") || CommandLine.arguments.contains("--dump-codex")
            || CommandLine.arguments.contains("--screenshot")
            || CommandLine.arguments.contains("--verify-refresh")
    }

    private static var hasRunningSibling: Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let current = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains { $0.processIdentifier != current }
    }

    private func dumpBuckets() {
        Task {
            do {
                let result = try await AnthropicUsageClient().fetch()
                let buckets = UsageResponseMapper().buckets(from: result.response)
                if buckets.isEmpty {
                    print("No populated limit windows in the response.")
                }
                printBuckets(buckets)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
            exit(0)
        }
    }

    private func dumpCodexBuckets() {
        Task {
            do {
                let result = try await CodexAppServerClient().fetch()
                let buckets = CodexRateLimitsMapper().buckets(from: result.response)
                if buckets.isEmpty {
                    print("No populated Codex limit windows in the response.")
                }
                printBuckets(buckets)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
            exit(0)
        }
    }

    private func printBuckets(_ buckets: [UsageBucket]) {
        for bucket in buckets {
            let title = bucket.title.padding(toLength: 40, withPad: " ", startingAt: 0)
            let used = String(format: "%5.1f%% used", bucket.utilization)
            let left = String(format: "%5.1f%% left", bucket.remaining)
            let reset =
                ResetFormatter.text(for: bucket.resetsAt, relativeTo: .now)
                ?? "no reset time"
            print("\(title)  \(used)  \(left)   \(reset)")
        }
    }
}

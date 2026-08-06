import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusItemController(store: store)
        store.start()
    }
}

@main
@MainActor
enum ClaudeUsageApp {
    /// `NSApplication.delegate` is unowned, so the delegate is held here for the process
    /// lifetime rather than as a local that the optimiser could release.
    private static let delegate = AppDelegate()

    static func main() {
        if CommandLine.arguments.contains("--dump") {
            dumpBuckets()
            return
        }

        let application = NSApplication.shared
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    /// Prints the resolved windows and exits — lets the data path be checked against
    /// `/usage` without reading pixels out of the menu bar.
    private static func dumpBuckets() {
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached {
            do {
                let (response, _) = try await UsageAPI.fetch()
                let buckets = UsageModel.buckets(from: response)
                if buckets.isEmpty {
                    print("No populated limit windows in the response.")
                }
                for bucket in buckets {
                    let title = bucket.title.padding(toLength: 30, withPad: " ", startingAt: 0)
                    let used = String(format: "%5.1f%% used", bucket.utilization)
                    let left = String(format: "%5.1f%% left", bucket.remaining)
                    let reset = ResetFormatter.text(for: bucket.resetsAt) ?? "no reset time"
                    print("\(title)  \(used)  \(left)   \(reset)")
                }
            } catch {
                print("error: \(error.localizedDescription)")
            }
            semaphore.signal()
        }

        semaphore.wait()
    }
}

import AppKit
import SwiftUI
import UsageCore

@MainActor
enum RefreshProbe {
    private final class Flag {
        var refreshed = false
    }

    static func run() -> Bool {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()

        for _ in 1...10 {
            if let fired = attempt(headerEnabled: false) {
                print("disabled row routes the click to its view: \(fired)")
                return fired
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        print("inconclusive: the click never landed on the control")
        return false
    }

    private static func attempt(headerEnabled: Bool) -> Bool? {
        let flag = Flag()
        let store = UsageStore(
            fixture: [
                UsageBucket(
                    id: "claude-session",
                    title: "Current session",
                    utilization: 20,
                    resetsAt: Date().addingTimeInterval(3_600),
                    severity: nil,
                    role: .session
                )
            ],
            lastUpdated: Date(),
            clock: SystemDateProvider()
        )

        let menu = NSMenu()
        UsageMenuBuilder.populate(
            menu,
            from: store,
            actions: UsageMenuBuilder.Actions(
                refresh: { flag.refreshed = true },
                signInClaude: nil,
                signInCodex: nil,
                settings: nil,
                quit: nil
            )
        )

        menu.items.first?.isEnabled = headerEnabled

        let driver = ClickDriver(menu: menu)
        let timer = Timer(
            timeInterval: 0.05,
            target: driver,
            selector: #selector(ClickDriver.fire),
            userInfo: nil,
            repeats: true
        )
        RunLoop.current.add(timer, forMode: .eventTracking)
        menu.popUp(positioning: nil, at: NSPoint(x: 200, y: 700), in: nil)
        timer.invalidate()

        guard driver.hitControl else { return nil }
        return flag.refreshed
    }

    @MainActor
    private final class ClickDriver: NSObject {
        let menu: NSMenu
        var hitControl = false
        private var ticks = 0
        private weak var located: NSWindow?

        init(menu: NSMenu) {
            self.menu = menu
        }

        private func locateTrackingWindow() -> NSWindow? {
            if let located { return located }
            located = NSApplication.shared.windows.first {
                $0.isVisible && String(describing: type(of: $0)).contains("MenuWindow")
            }
            return located
        }

        @objc func fire() {
            ticks += 1
            guard let window = locateTrackingWindow() else { return }

            switch ticks {
            case 6: click(in: window)
            case 12: menu.cancelTracking()
            default: break
            }
        }

        private func click(in window: NSWindow) {
            guard let header = menu.items.first?.view else { return }

            let local = NSPoint(
                x: header.bounds.maxX - MenuMetrics.trailingInset - 9,
                y: header.bounds.midY
            )
            let inWindow = header.convert(local, to: nil)
            hitControl = window.contentView?.hitTest(inWindow).map { $0.isDescendant(of: header) } ?? false

            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard
                    let event = NSEvent.mouseEvent(
                        with: type,
                        location: inWindow,
                        modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil,
                        eventNumber: 0,
                        clickCount: 1,
                        pressure: type == .leftMouseDown ? 1 : 0
                    )
                else { continue }
                NSApplication.shared.postEvent(event, atStart: false)
            }
        }
    }
}

import AppKit
import SwiftUI
import UsageCore

@MainActor
enum Screenshots {
    private static let now = Date(timeIntervalSince1970: 1_768_487_520)
    private static let scale: CGFloat = 2

    static func write(into directory: URL) throws {
        NSTimeZone.default = TimeZone(identifier: "UTC")!

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for appearance in Appearance.allCases {
            guard let dropdown = captureMenu(appearance) else {
                throw ScreenshotError.menuCaptureFailed(appearance.name)
            }
            try write(dropdown, to: directory, named: "dropdown-\(appearance.name)")
            try write(menuBar(appearance), to: directory, named: "menubar-\(appearance.name)")
        }
    }

    private static func write(_ rep: NSBitmapImageRep, to directory: URL, named name: String) throws {
        let url = directory.appendingPathComponent("\(name).png")
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ScreenshotError.encodingFailed(name)
        }
        try data.write(to: url, options: .atomic)
        print("wrote \(url.path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
    }

    private static func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private static func captureMenu(_ appearance: Appearance) -> NSBitmapImageRep? {
        for _ in 1...8 {
            if let rep = attemptMenuCapture(appearance), looksRendered(rep) { return rep }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return nil
    }

    private static func looksRendered(_ rep: NSBitmapImageRep) -> Bool {
        var darkest = CGFloat.greatestFiniteMagnitude
        var lightest: CGFloat = 0
        let columnStep = max(1, rep.pixelsWide / 40)
        let rowStep = max(1, rep.pixelsHigh / 80)
        let rowsEnd = Int(Double(rep.pixelsHigh) * 0.7)

        for y in stride(from: 0, to: rowsEnd, by: rowStep) {
            for x in stride(from: 0, to: rep.pixelsWide, by: columnStep) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let luma =
                    0.299 * color.redComponent + 0.587 * color.greenComponent
                    + 0.114 * color.blueComponent
                darkest = min(darkest, luma)
                lightest = max(lightest, luma)
            }
        }
        return lightest - darkest > 0.25
    }

    private static func attemptMenuCapture(_ appearance: Appearance) -> NSBitmapImageRep? {
        let store = UsageStore(
            fixture: Fixture.buckets,
            codexBuckets: Fixture.codexBuckets,
            lastUpdated: now.addingTimeInterval(-260),
            clock: FixedDateProvider(now: now)
        )

        NSApplication.shared.appearance = appearance.nsAppearance

        let responder = InertResponder()
        let menu = NSMenu()
        menu.appearance = appearance.nsAppearance
        UsageMenuBuilder.populate(
            menu,
            from: store,
            actions: UsageMenuBuilder.Actions(
                refreshClaude: {},
                refreshCodex: {},
                signInClaude: nil,
                signInCodex: nil,
                settings: (target: responder, action: #selector(InertResponder.noop)),
                quit: (target: responder, action: #selector(InertResponder.noop))
            )
        )

        let capture = MenuCapture(menu: menu)
        let timer = Timer(
            timeInterval: MenuCapture.tick,
            target: capture,
            selector: #selector(MenuCapture.fire),
            userInfo: nil,
            repeats: true
        )
        RunLoop.current.add(timer, forMode: .eventTracking)
        menu.popUp(positioning: nil, at: popUpOrigin(for: menu), in: nil)
        timer.invalidate()

        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        return capture.rep
    }

    private static func popUpOrigin(for menu: NSMenu) -> NSPoint {
        guard let frame = NSScreen.main?.visibleFrame else { return NSPoint(x: 100, y: 100) }
        let pointer = NSEvent.mouseLocation
        let x =
            pointer.x > frame.midX
            ? frame.minX + 40
            : frame.maxX - 40 - MenuMetrics.contentWidth
        let y = max(frame.minY + menu.size.height, min(frame.maxY - 40, frame.maxY))
        return NSPoint(x: x, y: y)
    }

    @MainActor
    private final class MenuCapture: NSObject {
        static let tick: TimeInterval = 0.05
        static let captureTick = 10

        let menu: NSMenu
        var rep: NSBitmapImageRep?
        private var ticks = 0

        init(menu: NSMenu) {
            self.menu = menu
        }

        private weak var located: NSWindow?

        private func locateTrackingWindow() -> NSWindow? {
            if let located { return located }
            located = NSApplication.shared.windows.first {
                $0.isVisible && String(describing: type(of: $0)).contains("MenuWindow")
            }
            return located
        }

        @objc func fire() {
            ticks += 1

            let window = locateTrackingWindow()
            window?.alphaValue = 0

            guard ticks >= Self.captureTick else { return }

            if let content = window?.contentView, content.bounds.height > 1,
                let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
            {
                content.cacheDisplay(in: content.bounds, to: rep)
                self.rep = rep
            }
            menu.cancelTracking()
        }
    }

    private static func menuBar(_ appearance: Appearance) -> NSBitmapImageRep {
        let items = [Fixture.buckets.session, Fixture.buckets.fable]
            .compactMap { $0 }
            .map { GaugeRenderer.Item(bucket: $0) }
        let gauge = GaugeRenderer.image(for: items)
        let padding = NSSize(width: 14, height: 7)
        let size = NSSize(
            width: (gauge.size.width + padding.width * 2).rounded(.up),
            height: gauge.size.height + padding.height * 2
        )

        return bitmap(size: size, appearance: appearance) {
            appearance.menuBarBackground.setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 6, yRadius: 6).fill()
            gauge.draw(
                at: NSPoint(x: padding.width, y: padding.height), from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    private static func bitmap(
        size: NSSize,
        appearance: Appearance,
        draw: () -> Void
    ) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.nsAppearance.performAsCurrentDrawingAppearance(draw)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private final class InertResponder: NSObject {
        @objc func noop() {}
    }

    private enum Appearance: CaseIterable {
        case light, dark

        var name: String { self == .light ? "light" : "dark" }

        var nsAppearance: NSAppearance {
            NSAppearance(named: self == .light ? .aqua : .darkAqua)!
        }

        var menuBarBackground: NSColor {
            self == .light
                ? NSColor(white: 0.925, alpha: 1)
                : NSColor(white: 0.13, alpha: 1)
        }
    }

    private enum ScreenshotError: LocalizedError {
        case encodingFailed(String)
        case menuCaptureFailed(String)

        var errorDescription: String? {
            switch self {
            case .encodingFailed(let name): return "Could not encode \(name).png"
            case .menuCaptureFailed(let name):
                return "Could not capture the \(name) menu no tracking menu window was found"
            }
        }
    }
}

private enum Fixture {
    static let buckets: [UsageBucket] = {
        do {
            let response = try JSONDecoder().decode(
                UsageResponseDTO.self,
                from: Data(json.utf8)
            )
            return UsageResponseMapper().buckets(from: response)
        } catch {
            assertionFailure("Invalid screenshot fixture: \(error)")
            return []
        }
    }()

    static let codexBuckets: [UsageBucket] = {
        do {
            let response = try JSONDecoder().decode(
                CodexRateLimitsResponseDTO.self,
                from: Data(codexJSON.utf8)
            )
            return CodexRateLimitsMapper().buckets(from: response)
        } catch {
            assertionFailure("Invalid Codex screenshot fixture: \(error)")
            return []
        }
    }()

    private static let json = """
        {
          "five_hour": { "utilization": 42, "resets_at": "2026-01-15T17:13:00+00:00" },
          "seven_day": { "utilization": 63, "resets_at": "2026-01-19T09:00:00+00:00" },
          "seven_day_opus": { "utilization": 88, "resets_at": "2026-01-19T09:00:00+00:00" },
          "limits": [
            {
              "kind": "weekly_scoped",
              "percent": 18,
              "resets_at": "2026-01-19T09:00:00+00:00",
              "scope": { "model": { "display_name": "Fable 5" } }
            }
          ]
        }
        """

    private static let codexJSON = """
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": {
                "usedPercent": 27,
                "windowDurationMins": 300,
                "resetsAt": 1768496700
              },
              "secondary": {
                "usedPercent": 54,
                "windowDurationMins": 10080,
                "resetsAt": 1768813200
              }
            },
            "codex_spark": {
              "limitId": "codex_spark",
              "limitName": "Codex Spark",
              "primary": {
                "usedPercent": 8,
                "windowDurationMins": 300,
                "resetsAt": 1768501800
              },
              "secondary": {
                "usedPercent": 31,
                "windowDurationMins": 10080,
                "resetsAt": 1768813200
              }
            }
          }
        }
        """
}

private struct FixedDateProvider: DateProvider {
    let now: Date
}

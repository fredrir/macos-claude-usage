import AppKit
import SwiftUI
import UsageCore

/// `--screenshot <dir>`: renders the README images from the real views, offscreen.
///
/// Nothing here mocks the UI — the dropdown is `DropdownView` in an `NSHostingView` and the bar
/// image is `GaugeRenderer`'s, both against a pinned fixture and a pinned clock, so re-running
/// this produces identical files rather than a diff full of shifted timestamps.
@MainActor
enum Screenshots {
    /// Thursday 15 Jan 2026, 14:32 UTC. Pinned so weekday and clock text never move.
    private static let now = Date(timeIntervalSince1970: 1_768_487_520)
    private static let scale: CGFloat = 2

    static func write(into directory: URL) throws {
        NSTimeZone.default = TimeZone(identifier: "UTC")!

        // No dock icon, no menu bar item — but AppKit still needs to be woken up before it will
        // lay out and draw a window.
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.finishLaunching()

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for appearance in Appearance.allCases {
            try write(dropdown(appearance), to: directory, named: "dropdown-\(appearance.name)")
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

    // MARK: - The two images

    /// The dropdown, captured from a real `NSHostingView` so controls match the running app.
    private static func dropdown(_ appearance: Appearance) -> NSBitmapImageRep {
        let store = UsageStore(
            fixture: Fixture.buckets,
            codexBuckets: Fixture.codexBuckets,
            lastUpdated: now.addingTimeInterval(-260),
            clock: FixedDateProvider(now: now)
        )
        let hosting = NSHostingView(
            rootView: DropdownView(store: store)
        )
        hosting.appearance = appearance.nsAppearance
        settleLayout(of: hosting, appearance: appearance)

        let backdrop = BackdropView(frame: hosting.frame)
        backdrop.appearance = appearance.nsAppearance
        backdrop.cornerRadius = 10
        backdrop.fill = appearance.popoverBackground
        backdrop.addSubview(hosting)

        return capture(backdrop, appearance: appearance)
    }

    /// Let state driven by layout preferences settle before freezing the host's capture frame.
    private static func settleLayout(of hosting: NSView, appearance: Appearance) {
        let initialSize = NSSize(width: 292, height: 700)
        hosting.frame = NSRect(origin: .zero, size: initialSize)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance.nsAppearance
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()

        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        let fittingSize = hosting.fittingSize

        window.orderOut(nil)
        window.contentView = nil
        hosting.frame = NSRect(origin: .zero, size: fittingSize)
    }

    /// The collapsed status item, on a chip standing in for the menu bar behind it.
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
            // `NSImage`'s drawing handler runs here, inside the appearance, so its dynamic colours
            // resolve for the appearance being rendered rather than the process default.
            gauge.draw(
                at: NSPoint(x: padding.width, y: padding.height), from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    // MARK: - Offscreen capture

    /// Hosts the view in an offscreen window — SwiftUI needs one to lay out and draw — then reads
    /// the pixels back at `scale`.
    private static func capture(_ view: NSView, appearance: Appearance) -> NSBitmapImageRep {
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance.nsAppearance
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = view
        // Parked far outside any display: it has to be ordered in to draw, but never appears.
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()

        // Let SwiftUI settle: layout, control instantiation and image decoding all land on the
        // next few runloop turns.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let rep = bitmap(size: view.bounds.size, appearance: appearance) {
            guard let context = NSGraphicsContext.current else { return }
            view.layer?.render(in: context.cgContext)
        }
        window.orderOut(nil)
        return rep
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

    // MARK: - Supporting types

    private enum Appearance: CaseIterable {
        case light, dark

        var name: String { self == .light ? "light" : "dark" }

        var nsAppearance: NSAppearance {
            NSAppearance(named: self == .light ? .aqua : .darkAqua)!
        }

        /// The menu-bar window's own material is a behind-window blur, which has nothing behind it
        /// offscreen; these are its opaque equivalents.
        var popoverBackground: NSColor {
            self == .light
                ? NSColor(white: 0.965, alpha: 1)
                : NSColor(white: 0.145, alpha: 1)
        }

        var menuBarBackground: NSColor {
            self == .light
                ? NSColor(white: 0.925, alpha: 1)
                : NSColor(white: 0.13, alpha: 1)
        }
    }

    private enum ScreenshotError: LocalizedError {
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .encodingFailed(let name): return "Could not encode \(name).png"
            }
        }
    }
}

/// An opaque, rounded backing for the captured view that approximates the menu-bar window.
private final class BackdropView: NSView {
    var fill: NSColor = .windowBackgroundColor
    var cornerRadius: CGFloat = 0

    override var wantsUpdateLayer: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.masksToBounds = true
        updateLayer()
    }

    override func updateLayer() {
        layer?.cornerRadius = cornerRadius
        layer?.backgroundColor = fill.cgColor
    }
}

/// The numbers the screenshots show: a plausible mid-week account with one window running low,
/// so the green/orange tinting is visible rather than described.
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

    /// Reset times are absolute, matching the pinned clock in `Screenshots`: the session lands
    /// 2h 41m out, the weekly windows on Monday 09:00. Timestamps are ISO 8601 strings because
    /// that is what the live endpoint emits.
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

    /// The fixture includes the main quota and a Spark quota. Spark is intentionally filtered
    /// from the dropdown; main-window labels still come from the server durations.
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

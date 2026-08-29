import AppKit
import UsageCore

/// Colours come from dynamic `NSColor`s so they resolve correctly against whichever appearance
/// AppKit has current when the image is drawn; the SwiftUI menu-bar label re-renders under the
/// matching appearance so a light/dark switch never leaves a stale bitmap behind.
enum GaugeRenderer {
    struct Item {
        /// Percentage of the window still available, 0–100.
        let remaining: Double
        let level: UsageLevel

        init(bucket: UsageBucket) {
            remaining = bucket.remaining
            level = bucket.level
        }
    }

    private static let segmentCount = 7
    private static let segmentWidth: CGFloat = 6
    private static let segmentHeight: CGFloat = 1.5
    private static let segmentGap: CGFloat = 1
    private static let segmentRadius: CGFloat = 0.75
    private static let groupGap: CGFloat = 0
    private static let imageHeight: CGFloat = 18

    private static var font: NSFont { .systemFont(ofSize: 11, weight: .medium) }

    private static var gaugeHeight: CGFloat {
        CGFloat(segmentCount) * segmentHeight + CGFloat(segmentCount - 1) * segmentGap
    }

    static func image(for items: [Item], dimmed: Bool = false) -> NSImage {
        guard !items.isEmpty else { return placeholder() }

        let totalWidth =
            CGFloat(items.count) * segmentWidth + groupGap * CGFloat(items.count - 1)

        let image = NSImage(size: NSSize(width: ceil(totalWidth), height: imageHeight), flipped: false) { _ in
            var cursor: CGFloat = 0
            for item in items {
                let color = tint(level: item.level, dimmed: dimmed)
                drawGauge(remaining: item.remaining, at: cursor, color: color, dimmed: dimmed)
                cursor += segmentWidth + groupGap
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawGauge(remaining: Double, at originX: CGFloat, color: NSColor, dimmed: Bool) {
        let filled =
            remaining <= 0
            ? 0
            : max(1, min(segmentCount, Int((remaining / 100 * Double(segmentCount)).rounded())))
        let empty = NSColor.tertiaryLabelColor.withAlphaComponent(dimmed ? 0.25 : 0.45)
        let originY = (imageHeight - gaugeHeight) / 2

        for index in 0..<segmentCount {
            let y = originY + CGFloat(index) * (segmentHeight + segmentGap)
            let rect = NSRect(x: originX, y: y, width: segmentWidth, height: segmentHeight)
            (index < filled ? color : empty).setFill()
            NSBezierPath(roundedRect: rect, xRadius: segmentRadius, yRadius: segmentRadius).fill()
        }
    }

    private static func tint(level: UsageLevel, dimmed: Bool) -> NSColor {
        let base: NSColor
        switch level {
        case .critical: base = .systemRed
        case .warning: base = .systemOrange
        case .normal: base = .labelColor
        }
        return dimmed ? base.withAlphaComponent(0.45) : base
    }

    private static func textSize(_ string: String) -> NSSize {
        (string as NSString).size(withAttributes: [.font: font])
    }

    /// Shown before the first successful fetch, or when every window came back null.
    private static func placeholder() -> NSImage {
        let label = "—"
        let size = textSize(label)
        let image = NSImage(
            size: NSSize(width: max(18, ceil(size.width) + 8), height: imageHeight),
            flipped: false
        ) { rect in
            (label as NSString).draw(
                at: NSPoint(x: (rect.width - size.width) / 2, y: (imageHeight - size.height) / 2),
                withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            )
            return true
        }
        image.isTemplate = false
        return image
    }
}

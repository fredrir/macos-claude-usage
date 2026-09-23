import AppKit
import UsageCore

enum GaugeRenderer {
    enum Slot: Sendable {
        case usage(UsageBucket)
        case empty
    }

    private static let segmentCount = 7
    private static let segmentWidth: CGFloat = 5
    private static let segmentHeight: CGFloat = 1.5
    private static let segmentGap: CGFloat = 1
    private static let segmentRadius: CGFloat = 0.75
    private static let groupGap: CGFloat = 0.2
    private static let imageHeight: CGFloat = 18
    private static let missingAlpha: CGFloat = 0.25

    private static var gaugeHeight: CGFloat {
        CGFloat(segmentCount) * segmentHeight + CGFloat(segmentCount - 1) * segmentGap
    }

    private static var originY: CGFloat {
        (imageHeight - gaugeHeight) / 2
    }

    static func image(for slots: [Slot]) -> NSImage {
        let drawn = slots.isEmpty ? [.empty] : slots
        let totalWidth = CGFloat(drawn.count) * segmentWidth + groupGap * CGFloat(drawn.count - 1)

        let image = NSImage(size: NSSize(width: ceil(totalWidth), height: imageHeight), flipped: false) { _ in
            var cursor: CGFloat = 0
            for slot in drawn {
                switch slot {
                case .usage(let bucket):
                    drawGauge(remaining: bucket.remaining, at: cursor, color: tint(level: bucket.level))
                case .empty:
                    drawMissingGauge(at: cursor)
                }
                cursor += segmentWidth + groupGap
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Rows the account no longer has are left unpainted, so a gauge that is used up disappears.
    /// Only a slot with no account behind it keeps the dimmed shape.
    private static func drawGauge(remaining: Double, at originX: CGFloat, color: NSColor) {
        let filled =
            remaining <= 0
            ? 0
            : max(1, min(segmentCount, Int((remaining / 100 * Double(segmentCount)).rounded())))

        drawSegments(filled, at: originX, color: color)
    }

    /// A slot with no account behind it is the same gauge, dimmed.
    private static func drawMissingGauge(at originX: CGFloat) {
        let missing = NSColor.tertiaryLabelColor.withAlphaComponent(missingAlpha)
        drawSegments(segmentCount, at: originX, color: missing)
    }

    private static func drawSegments(_ count: Int, at originX: CGFloat, color: NSColor) {
        for index in 0..<count {
            let y = originY + CGFloat(index) * (segmentHeight + segmentGap)
            let rect = NSRect(x: originX, y: y, width: segmentWidth, height: segmentHeight)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: segmentRadius, yRadius: segmentRadius).fill()
        }
    }

    private static func tint(level: UsageLevel) -> NSColor {
        switch level {
        case .critical: .systemRed
        case .warning: .systemOrange
        case .normal: .labelColor
        }
    }
}

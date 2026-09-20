import AppKit
import UsageCore

enum GaugeRenderer {
    enum Slot: Sendable {
        case usage(UsageBucket, dimmed: Bool)
        case empty
    }

    private static let segmentCount = 7
    private static let segmentWidth: CGFloat = 5
    private static let segmentHeight: CGFloat = 1.5
    private static let segmentGap: CGFloat = 1
    private static let segmentRadius: CGFloat = 0.75
    private static let groupGap: CGFloat = 0.2
    private static let imageHeight: CGFloat = 18

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
                case .usage(let bucket, let dimmed):
                    drawGauge(
                        remaining: bucket.remaining,
                        at: cursor,
                        color: tint(level: bucket.level, dimmed: dimmed),
                        dimmed: dimmed
                    )
                case .empty:
                    drawEmptyGauge(at: cursor)
                }
                cursor += segmentWidth + groupGap
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Rows the account no longer has are left unpainted; a gauge with nothing left greys out whole.
    private static func drawGauge(remaining: Double, at originX: CGFloat, color: NSColor, dimmed: Bool) {
        let filled =
            remaining <= 0
            ? 0
            : max(1, min(segmentCount, Int((remaining / 100 * Double(segmentCount)).rounded())))
        let greyed = NSColor.tertiaryLabelColor.withAlphaComponent(dimmed ? 0.25 : 0.45)

        for index in 0..<segmentCount {
            guard filled == 0 || index < filled else { continue }
            let y = originY + CGFloat(index) * (segmentHeight + segmentGap)
            let rect = NSRect(x: originX, y: y, width: segmentWidth, height: segmentHeight)
            (filled == 0 ? greyed : color).setFill()
            NSBezierPath(roundedRect: rect, xRadius: segmentRadius, yRadius: segmentRadius).fill()
        }
    }

    /// A slot with no account behind it is the same gauge with nothing filled.
    private static func drawEmptyGauge(at originX: CGFloat) {
        drawGauge(remaining: 0, at: originX, color: .tertiaryLabelColor, dimmed: false)
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
}

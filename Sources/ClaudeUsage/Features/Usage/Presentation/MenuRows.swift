import AppKit
import SwiftUI
import UsageCore

enum MenuMetrics {
    static let contentWidth: CGFloat = 292
    static let leadingInset: CGFloat = 16
    static let trailingInset: CGFloat = 14
    static let itemHeight: CGFloat = 24

    static var titleFont: Font { Font(NSFont.menuFont(ofSize: 0)) }
    static var sectionHeaderFont: Font {
        Font(NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold))
    }

    static var secondaryLabel: Color { Color(nsColor: .secondaryLabelColor) }

    static var rowInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: leadingInset, bottom: 0, trailing: trailingInset)
    }
}

struct ProviderHeaderRow: View {
    let title: String
    @ObservedObject var store: UsageStore
    var refresh: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(MenuMetrics.sectionHeaderFont)
                .foregroundStyle(MenuMetrics.secondaryLabel)

            Spacer(minLength: 8)

            if let refresh {
                MenuIconButton(
                    systemName: "arrow.clockwise",
                    help: "Refresh",
                    isSpinning: store.isRefreshing,
                    action: refresh
                )
                .accessibilityLabel("Refresh usage")
            }
        }
        .padding(MenuMetrics.rowInsets)
        .frame(width: MenuMetrics.contentWidth, height: MenuMetrics.itemHeight)
    }
}

struct BucketMenuRow: View {
    let bucket: UsageBucket
    let dimmed: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bucket.title)
                    .font(MenuMetrics.titleFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text("\(Int(bucket.remaining.rounded(.down)))% left")
                    .font(MenuMetrics.titleFont)
                    .foregroundStyle(MenuMetrics.secondaryLabel)
                    .monospacedDigit()
                    .fixedSize()
            }

            GaugeBar(fraction: bucket.usedFraction, tint: tint)

            if let reset = ResetFormatter.text(for: bucket.resetsAt, relativeTo: now) {
                Text(reset)
                    .font(.system(size: 11))
                    .foregroundStyle(MenuMetrics.secondaryLabel)
                    .lineLimit(1)
            }
        }
        .padding(MenuMetrics.rowInsets)
        .padding(.vertical, 4)
        .frame(width: MenuMetrics.contentWidth, alignment: .leading)
        .opacity(dimmed ? 0.55 : 1)
    }

    private var tint: Color {
        switch bucket.level {
        case .critical: return Color(nsColor: .systemRed)
        case .warning: return Color(nsColor: .systemOrange)
        case .normal: return Color(nsColor: .systemGreen)
        }
    }
}

struct StatusMenuRow: View {
    let message: String
    let systemImage: String

    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.system(size: 11))
            .foregroundStyle(Color(nsColor: .systemOrange))
            .lineLimit(2)
            .padding(MenuMetrics.rowInsets)
            .padding(.vertical, 2)
            .frame(width: MenuMetrics.contentWidth, alignment: .leading)
    }
}

struct PlaceholderMenuRow: View {
    let message: String

    var body: some View {
        Text(message)
            .font(MenuMetrics.titleFont)
            .foregroundStyle(MenuMetrics.secondaryLabel)
            .lineLimit(1)
            .padding(MenuMetrics.rowInsets)
            .frame(width: MenuMetrics.contentWidth, height: MenuMetrics.itemHeight, alignment: .leading)
    }
}

struct SignInMenuRow: View {
    let isSigningIn: Bool
    let signIn: () -> Void

    var body: some View {
        HStack {
            if isSigningIn {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Sign In…", action: signIn)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(MenuMetrics.rowInsets)
        .padding(.vertical, 4)
        .frame(width: MenuMetrics.contentWidth, alignment: .leading)
    }
}

private struct MenuIconButton: View {
    let systemName: String
    let help: String
    var isSpinning: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @State private var angle: Double = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MenuMetrics.secondaryLabel)
                .rotationEffect(.degrees(angle))
                .frame(width: 18, height: 18)
                .background {
                    Circle().fill(Color.primary.opacity(isHovered ? 0.12 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .onAppear { updateSpin() }
        .onChange(of: isSpinning) { _, _ in updateSpin() }
    }

    private func updateSpin() {
        if isSpinning {
            angle = 0
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                angle = 360
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                angle = 0
            }
        }
    }
}

private struct GaugeBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint)
                    .frame(width: max(fraction > 0 ? 3 : 0, geometry.size.width * fraction))
            }
        }
        .frame(height: 6)
    }
}

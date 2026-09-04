import SwiftUI
import UsageCore

struct DropdownView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var store: UsageStore
    @State private var usageContentHeight: CGFloat = 180

    private static let maximumUsageContentHeight: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                usageContent
            }
            // A non-zero initial height prevents MenuBarExtra from collapsing its ScrollView.
            // Once laid out, track the real content height and cap only genuine overflow.
            .frame(
                height: min(usageContentHeight, Self.maximumUsageContentHeight)
            )
            .onPreferenceChange(UsageContentHeightKey.self) { measuredHeight in
                guard measuredHeight > 0, abs(measuredHeight - usageContentHeight) > 0.5 else {
                    return
                }
                usageContentHeight = measuredHeight
            }

            Divider()
                .padding(.horizontal, 14)
            footer
        }
        .frame(width: 292)
    }

    private var usageContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProviderUsageSection(
                title: "Claude",
                buckets: store.buckets,
                isStale: store.isStale,
                statusMessage: store.statusMessage,
                statusIcon: store.statusIcon,
                statusIsWarning: store.statusIsWarning,
                now: store.now,
                refresh: store.refreshManually
            )

            Divider()

            ProviderUsageSection(
                title: "Codex",
                buckets: store.codexBuckets,
                isStale: store.codexIsStale,
                statusMessage: store.codexStatusMessage,
                statusIcon: store.codexStatusIcon,
                statusIsWarning: store.codexStatusIsWarning,
                now: store.now,
                refresh: nil
            )
        }
        .padding(16)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: UsageContentHeightKey.self,
                    value: geometry.size.height
                )
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Button {
                // Menu bar apps don't become active when their extra opens. Activate first so
                // the Settings scene appears above the app the user was previously working in.
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                MenuRowLabel(title: "Settings…", shortcut: "⌘,")
            }
            .buttonStyle(MenuRowButtonStyle())
            .keyboardShortcut(",", modifiers: .command)

            Divider()
                .padding(.horizontal, 14)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                MenuRowLabel(title: "Quit", shortcut: "⌘Q")
            }
            .buttonStyle(MenuRowButtonStyle())
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.vertical, 4)
    }
}

private struct MenuRowLabel: View {
    let title: String
    let shortcut: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Text(shortcut)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRowButtonStyleBody(configuration: configuration)
    }

    private struct MenuRowButtonStyleBody: View {
        let configuration: Configuration
        @State private var isHovered = false

        private var isHighlighted: Bool {
            isHovered || configuration.isPressed
        }

        private var highlightColor: Color {
            guard isHighlighted else { return .clear }
            return Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08)
        }

        var body: some View {
            configuration.label
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 24)
                .contentShape(Rectangle())
                .foregroundStyle(Color.primary)
                .background {
                    Capsule()
                        .fill(highlightColor)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                }
                .onHover { isHovered = $0 }
        }
    }
}

private struct UsageContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ProviderUsageSection: View {
    let title: String
    let buckets: [UsageBucket]
    let isStale: Bool
    let statusMessage: String?
    let statusIcon: String
    let statusIsWarning: Bool
    let now: Date
    let refresh: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))

                Spacer(minLength: 8)

                if let refresh {
                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Refresh")
                    .accessibilityLabel("Refresh usage")
                }
            }

            if buckets.isEmpty {
                if statusIsWarning, let statusMessage {
                    statusRow(statusMessage)
                } else {
                    Text("No usage limits returned")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(buckets) { bucket in
                        BucketRow(bucket: bucket, dimmed: isStale, now: now)
                    }
                }

                if statusIsWarning, let statusMessage {
                    statusRow(statusMessage)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) usage")
    }

    private func statusRow(_ message: String) -> some View {
        Label(message, systemImage: statusIcon)
            .font(.system(size: 10))
            .foregroundStyle(Color(nsColor: .systemOrange))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct BucketRow: View {
    let bucket: UsageBucket
    let dimmed: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(bucket.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text("\(Int(bucket.remaining.rounded(.down)))% left")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }

            GaugeBar(fraction: bucket.usedFraction, tint: tint)

            if let reset = ResetFormatter.text(for: bucket.resetsAt, relativeTo: now) {
                Text(reset)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
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

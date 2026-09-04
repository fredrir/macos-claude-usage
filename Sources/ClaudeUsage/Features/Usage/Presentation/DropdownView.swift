import SwiftUI
import UsageCore

struct DropdownView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginModel
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
            footer
        }
        .frame(width: 292)
        .onAppear { launchAtLogin.refresh() }
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
                now: store.now
            )

            Divider()

            ProviderUsageSection(
                title: "Codex",
                buckets: store.codexBuckets,
                isStale: store.codexIsStale,
                statusMessage: store.codexStatusMessage,
                statusIcon: store.codexStatusIcon,
                statusIsWarning: store.codexStatusIsWarning,
                now: store.now
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Check every")
                Spacer(minLength: 12)
                Picker("", selection: $store.pollInterval) {
                    Text("15 min").tag(TimeInterval(900))
                    Text("30 min").tag(TimeInterval(1800))
                    Text("60 min").tag(TimeInterval(3600))
                }
                .labelsHidden()
                .frame(width: 92)
            }
            .frame(maxWidth: .infinity)
            .font(.system(size: 11))

            Toggle(
                "Launch at login",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
            )
            .font(.system(size: 11))
            .toggleStyle(.checkbox)

            if let errorMessage = launchAtLogin.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button("Refresh") { store.refreshManually() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.system(size: 11))
            .buttonStyle(.link)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

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

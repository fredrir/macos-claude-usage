import SwiftUI
import UsageCore

struct DropdownView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.buckets.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(store.buckets) { bucket in
                        BucketRow(bucket: bucket, dimmed: store.isStale, now: store.now)
                    }
                }
                .padding(16)
            }

            Divider()
            footer
        }
        .frame(width: 292)
        .onAppear { launchAtLogin.refresh() }
    }

    /// The reason there is nothing to show lives in the footer's status line, so this stays a
    /// bare heading rather than repeating it.
    private var emptyState: some View {
        Text("No usage data yet")
            .font(.system(size: 13, weight: .semibold))
            .padding(16)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = store.statusMessage {
                Label(message, systemImage: store.statusIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(store.statusIsWarning ? Color(nsColor: .systemOrange) : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Text("Check every")
                Picker("", selection: $store.pollInterval) {
                    Text("15 min").tag(TimeInterval(900))
                    Text("30 min").tag(TimeInterval(1800))
                    Text("60 min").tag(TimeInterval(3600))
                }
                .labelsHidden()
                .frame(width: 92)
            }
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

private struct BucketRow: View {
    let bucket: UsageBucket
    let dimmed: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(bucket.title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Text("\(Int(bucket.utilization.rounded(.down)))% used")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
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

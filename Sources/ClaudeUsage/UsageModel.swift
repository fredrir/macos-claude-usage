import Foundation

/// A single limit window, normalised so the status item and the dropdown share one shape and
/// buckets the API adds later render without code changes.
struct Bucket: Identifiable, Equatable {
    enum Role { case session, weeklyAll, fable, other }

    let id: String
    let title: String
    /// Percentage of the window consumed, 0–100.
    let utilization: Double
    let resetsAt: Date?
    /// The server's own read — `normal`, `warning` or `critical`. Absent on fallback windows.
    let severity: String?
    let role: Role

    /// Percentage of the window still available, 0–100.
    var remaining: Double { max(0, min(100, 100 - utilization)) }
    var usedFraction: Double { max(0, min(1, utilization / 100)) }

    /// Prefers the server's severity, falling back to thresholds on what is left.
    var level: Level {
        switch severity {
        case "critical": return .critical
        case "warning": return .warning
        case "normal": return .normal
        default:
            if remaining < 10 { return .critical }
            if remaining < 25 { return .warning }
            return .normal
        }
    }

    enum Level { case normal, warning, critical }
}

enum UsageModel {
    /// Flattens the response into an ordered bucket list: session, weekly (all models), weekly
    /// Fable, then everything else the account happens to have.
    ///
    /// `limits[]` is the authoritative source — it carries every window, including the
    /// per-model weekly ones, with severity attached. The top-level `five_hour` / `seven_day`
    /// keys duplicate the first two and are used only if `limits[]` is missing.
    static func buckets(from response: UsageResponse) -> [Bucket] {
        var result: [Bucket] = []
        var seen = Set<String>()

        func add(
            id: String,
            title: String,
            percent: Double?,
            resetsAt: String?,
            severity: String?,
            role: Bucket.Role
        ) {
            guard let percent, seen.insert(id).inserted else { return }
            result.append(
                Bucket(
                    id: id,
                    title: title,
                    utilization: percent,
                    resetsAt: ISODate.parse(resetsAt),
                    severity: severity,
                    role: role
                )
            )
        }

        let entries = response.limits ?? []
        let scoped = entries.filter { $0.kind == "weekly_scoped" && $0.scope?.model?.display_name != nil }

        if let session = entries.first(where: { $0.kind == "session" }) {
            add(
                id: "session",
                title: "Current session",
                percent: session.percent,
                resetsAt: session.resets_at,
                severity: session.severity,
                role: .session
            )
        }
        add(
            id: "session",
            title: "Current session",
            percent: response.five_hour?.utilization,
            resetsAt: response.five_hour?.resets_at,
            severity: nil,
            role: .session
        )

        if let weekly = entries.first(where: { $0.kind == "weekly_all" }) {
            add(
                id: "weekly_all",
                title: "Current week (all models)",
                percent: weekly.percent,
                resetsAt: weekly.resets_at,
                severity: weekly.severity,
                role: .weeklyAll
            )
        }
        add(
            id: "weekly_all",
            title: "Current week (all models)",
            percent: response.seven_day?.utilization,
            resetsAt: response.seven_day?.resets_at,
            severity: nil,
            role: .weeklyAll
        )

        // Fable first, then any other per-model weekly window the plan happens to expose.
        // Partitioned rather than sorted: `isFable` is not a strict weak ordering.
        for entry in scoped.filter(isFable) + scoped.filter({ !isFable($0) }) {
            guard let name = entry.scope?.model?.display_name else { continue }
            add(
                id: "scoped:\(name)",
                title: "Current week (\(name))",
                percent: entry.percent,
                resetsAt: entry.resets_at,
                severity: entry.severity,
                role: isFable(entry) ? .fable : .other
            )
        }

        add(
            id: "seven_day_opus",
            title: "Current week (Opus)",
            percent: response.seven_day_opus?.utilization,
            resetsAt: response.seven_day_opus?.resets_at,
            severity: nil,
            role: .other
        )
        add(
            id: "seven_day_sonnet",
            title: "Current week (Sonnet)",
            percent: response.seven_day_sonnet?.utilization,
            resetsAt: response.seven_day_sonnet?.resets_at,
            severity: nil,
            role: .other
        )

        return result
    }

    private static func isFable(_ entry: LimitEntry) -> Bool {
        entry.scope?.model?.display_name?.lowercased().contains("fable") ?? false
    }
}

extension Array where Element == Bucket {
    var session: Bucket? { first { $0.role == .session } }
    var fable: Bucket? { first { $0.role == .fable } }
}

enum ResetFormatter {
    private static let weekdayTime: DateFormatter = {
        let formatter = DateFormatter()
        // The rest of the UI is English-only; a localised weekday would be the odd one out.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()

    static func text(for date: Date?) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince(AppClock.now)
        guard interval > 0 else { return "Resets now" }

        if interval < 24 * 3600 {
            let hours = Int(interval) / 3600
            let minutes = (Int(interval) % 3600) / 60
            return hours > 0 ? "Resets in \(hours)h \(minutes)m" : "Resets in \(minutes)m"
        }
        return "Resets \(weekdayTime.string(from: date))"
    }
}

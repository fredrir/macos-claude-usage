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
    let role: Role

    /// Percentage of the window still available, 0–100.
    var remaining: Double { max(0, min(100, 100 - utilization)) }
    var usedFraction: Double { max(0, min(1, utilization / 100)) }
}

enum UsageModel {
    /// Flattens the response into an ordered bucket list: session, weekly (all models),
    /// weekly Fable, then everything else the account happens to have.
    static func buckets(from response: UsageResponse) -> [Bucket] {
        var result: [Bucket] = []
        var seenTitles = Set<String>()

        func append(
            _ window: UsageWindow?,
            id: String,
            title: String,
            role: Bucket.Role
        ) {
            guard let window, let utilization = window.utilization else { return }
            guard seenTitles.insert(title).inserted else { return }
            result.append(
                Bucket(
                    id: id,
                    title: title,
                    utilization: utilization,
                    resetsAt: window.resets_at.map { Date(timeIntervalSince1970: $0) },
                    role: role
                )
            )
        }

        append(response.five_hour, id: "five_hour", title: "Current session", role: .session)
        append(response.seven_day, id: "seven_day", title: "Current week (all models)", role: .weeklyAll)

        // Per-model weekly windows. This is where the Fable bucket lives.
        let scoped = (response.limits ?? []).filter { $0.kind == "weekly_scoped" }
        let fableScoped = scoped.filter { isFable($0.scope?.model?.display_name) }
        let otherScoped = scoped.filter { !isFable($0.scope?.model?.display_name) }

        for entry in fableScoped + otherScoped {
            guard
                let name = entry.scope?.model?.display_name,
                let percent = entry.percent
            else { continue }
            append(
                UsageWindow(utilization: percent, resets_at: entry.resets_at),
                id: "scoped:\(name)",
                title: "Current week (\(name))",
                role: isFable(name) ? .fable : .other
            )
        }

        // Only used when the account reports Fable through the overage key instead of limits[].
        append(
            response.seven_day_overage_included,
            id: "seven_day_overage_included",
            title: "Current week (Fable 5)",
            role: result.contains { $0.role == .fable } ? .other : .fable
        )

        append(response.seven_day_opus, id: "seven_day_opus", title: "Current week (Opus)", role: .other)
        append(response.seven_day_sonnet, id: "seven_day_sonnet", title: "Current week (Sonnet)", role: .other)
        append(
            response.seven_day_oauth_apps,
            id: "seven_day_oauth_apps",
            title: "Current week (OAuth apps)",
            role: .other
        )
        append(response.cinder_cove, id: "cinder_cove", title: "Additional window", role: .other)

        return result
    }

    private static func isFable(_ displayName: String?) -> Bool {
        displayName?.lowercased().contains("fable") ?? false
    }
}

extension Array where Element == Bucket {
    var session: Bucket? { first { $0.role == .session } }
    var fable: Bucket? { first { $0.role == .fable } }
}

enum ResetFormatter {
    private static let weekdayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()

    static func text(for date: Date?) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return "Resets now" }

        if interval < 24 * 3600 {
            let hours = Int(interval) / 3600
            let minutes = (Int(interval) % 3600) / 60
            return hours > 0 ? "Resets in \(hours)h \(minutes)m" : "Resets in \(minutes)m"
        }
        return "Resets \(weekdayTime.string(from: date))"
    }
}

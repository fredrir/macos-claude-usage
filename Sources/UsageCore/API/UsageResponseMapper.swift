import Foundation

/// Converts wire DTOs into stable, ordered domain values.
public struct UsageResponseMapper: Sendable {
    public init() {}

    public func map(_ response: UsageResponseDTO, fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(buckets: buckets(from: response), fetchedAt: fetchedAt)
    }

    /// Orders windows as session, all-model weekly, Fable, other scoped models, then legacy
    /// top-level model windows. A matching `limits` entry takes precedence over its top-level
    /// fallback.
    public func buckets(from response: UsageResponseDTO) -> [UsageBucket] {
        var result: [UsageBucket] = []
        var seen = Set<String>()

        func add(
            id: String,
            title: String,
            percent: Double?,
            resetsAt: String?,
            severity: UsageSeverity?,
            role: UsageRole
        ) {
            guard let percent, seen.insert(id).inserted else { return }
            result.append(
                UsageBucket(
                    id: id,
                    title: title,
                    utilization: percent,
                    resetsAt: ISO8601DateParser.parse(resetsAt),
                    severity: severity,
                    role: role
                )
            )
        }

        let entries = response.limits ?? []
        let scoped = entries.filter {
            $0.kind == "weekly_scoped" && $0.scope?.model?.displayName != nil
        }

        if let session = entries.first(where: { $0.kind == "session" }) {
            add(
                id: "session",
                title: "Current session",
                percent: session.percent,
                resetsAt: session.resetsAt,
                severity: session.severity,
                role: .session
            )
        }
        add(
            id: "session",
            title: "Current session",
            percent: response.fiveHour?.utilization,
            resetsAt: response.fiveHour?.resetsAt,
            severity: nil,
            role: .session
        )

        if let weekly = entries.first(where: { $0.kind == "weekly_all" }) {
            add(
                id: "weekly_all",
                title: "Current week",
                percent: weekly.percent,
                resetsAt: weekly.resetsAt,
                severity: weekly.severity,
                role: .weeklyAll
            )
        }
        add(
            id: "weekly_all",
            title: "Current week",
            percent: response.sevenDay?.utilization,
            resetsAt: response.sevenDay?.resetsAt,
            severity: nil,
            role: .weeklyAll
        )

        for entry in scoped.filter(isFable) + scoped.filter({ !isFable($0) }) {
            guard let model = entry.scope?.model, let name = model.displayName else { continue }
            add(
                id: scopedID(for: model),
                title: "Current week (\(name))",
                percent: entry.percent,
                resetsAt: entry.resetsAt,
                severity: entry.severity,
                role: isFable(entry) ? .fable : .other
            )
        }

        add(
            id: "seven_day_opus",
            title: "Current week (Opus)",
            percent: response.sevenDayOpus?.utilization,
            resetsAt: response.sevenDayOpus?.resetsAt,
            severity: nil,
            role: .other
        )
        add(
            id: "seven_day_sonnet",
            title: "Current week (Sonnet)",
            percent: response.sevenDaySonnet?.utilization,
            resetsAt: response.sevenDaySonnet?.resetsAt,
            severity: nil,
            role: .other
        )

        return result
    }

    private func isFable(_ entry: LimitEntryDTO) -> Bool {
        entry.scope?.model?.displayName?.localizedStandardContains("fable") ?? false
    }

    private func scopedID(for model: LimitEntryDTO.ScopeDTO.ModelDTO) -> String {
        let stableComponent = model.id.flatMap(nonempty) ?? model.displayName.flatMap(nonempty) ?? "unknown"
        return "scoped:\(stableComponent)"
    }

    private func nonempty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}

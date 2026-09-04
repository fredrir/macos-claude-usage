import Foundation

/// Converts Codex's dynamic quota windows into stable, ordered presentation values.
public struct CodexRateLimitsMapper: Sendable {
    public init() {}

    public func map(_ response: CodexRateLimitsResponseDTO, fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(buckets: buckets(from: response), fetchedAt: fetchedAt)
    }

    /// Orders the main Codex quota first, then model-specific quotas by display name. Within
    /// each quota, the shorter window precedes the longer one.
    public func buckets(from response: CodexRateLimitsResponseDTO) -> [UsageBucket] {
        limits(from: response).flatMap { limit in
            windows(from: limit).compactMap { slot, window in
                bucket(for: window, slot: slot, limit: limit)
            }
        }
    }

    private func limits(from response: CodexRateLimitsResponseDTO) -> [CodexRateLimitDTO] {
        let limits: [CodexRateLimitDTO]
        if let keyed = response.rateLimitsByLimitId, !keyed.isEmpty {
            limits = keyed.map { key, value in
                guard value.limitId.isEmpty else { return value }
                return CodexRateLimitDTO(
                    limitId: key,
                    limitName: value.limitName,
                    primary: value.primary,
                    secondary: value.secondary,
                    planType: value.planType,
                    rateLimitReachedType: value.rateLimitReachedType
                )
            }
        } else if let fallback = response.rateLimits {
            limits = [fallback]
        } else {
            limits = []
        }

        return
            limits
            .filter { !isSparkLimit($0) }
            .sorted { left, right in
                let leftIsMain = isMain(left)
                let rightIsMain = isMain(right)
                if leftIsMain != rightIsMain { return leftIsMain }
                return displayName(for: left).localizedStandardCompare(displayName(for: right))
                    == .orderedAscending
            }
    }

    private func windows(
        from limit: CodexRateLimitDTO
    ) -> [(slot: String, window: CodexRateLimitWindowDTO)] {
        [("primary", limit.primary), ("secondary", limit.secondary)]
            .compactMap { slot, window in window.map { (slot, $0) } }
            .sorted { left, right in
                let leftDuration = left.window.windowDurationMins ?? .max
                let rightDuration = right.window.windowDurationMins ?? .max
                if leftDuration != rightDuration { return leftDuration < rightDuration }
                return left.slot < right.slot
            }
    }

    private func bucket(
        for window: CodexRateLimitWindowDTO,
        slot: String,
        limit: CodexRateLimitDTO
    ) -> UsageBucket? {
        guard let percent = window.usedPercent, let duration = window.windowDurationMins, duration > 0 else {
            return nil
        }

        let modelSuffix = isMain(limit) ? nil : displayName(for: limit)
        let windowTitle = Self.title(forDurationMinutes: duration)
        let title = modelSuffix.map { "\(windowTitle) (\($0))" } ?? windowTitle
        let reset = window.resetsAt.map(Date.init(timeIntervalSince1970:))

        return UsageBucket(
            id: "codex:\(limit.limitId):\(slot):\(duration)",
            title: title,
            utilization: percent,
            resetsAt: reset,
            severity: nil,
            // Codex values must never become candidates for the Claude-only menu-bar gauges.
            role: .other
        )
    }

    private func isMain(_ limit: CodexRateLimitDTO) -> Bool {
        limit.limitId == "codex"
    }

    private func isSparkLimit(_ limit: CodexRateLimitDTO) -> Bool {
        limit.limitId.localizedCaseInsensitiveContains("spark")
            || limit.limitName?.localizedCaseInsensitiveContains("spark") == true
    }

    private func displayName(for limit: CodexRateLimitDTO) -> String {
        if let name = limit.limitName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }

        let withoutPrefix =
            limit.limitId.hasPrefix("codex_")
            ? String(limit.limitId.dropFirst("codex_".count))
            : limit.limitId
        return withoutPrefix.replacingOccurrences(of: "_", with: " ").capitalized
    }

    public static func title(forDurationMinutes minutes: Int) -> String {
        switch minutes {
        case 7 * 24 * 60:
            return "Weekly limit"
        case let value where value > 0 && value.isMultiple(of: 24 * 60):
            return "\(value / (24 * 60))-day limit"
        case let value where value > 0 && value.isMultiple(of: 60):
            return "\(value / 60)-hour limit"
        default:
            return "\(minutes)-minute limit"
        }
    }
}

import Foundation

public enum UsageProvider: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

public enum GaugePlacement: String, Codable, CaseIterable, Sendable {
    case menuBar
    case menu

    /// The menu bar always keeps a gauge so the status item has something to click.
    var requiresOne: Bool { self == .menuBar }
}

public struct GaugeEntry: Codable, Equatable, Identifiable, Sendable {
    public let provider: UsageProvider
    public let bucketID: String
    public var title: String
    public var placements: Set<GaugePlacement>

    public init(provider: UsageProvider, bucketID: String, title: String, placements: Set<GaugePlacement>) {
        self.provider = provider
        self.bucketID = bucketID
        self.title = title
        self.placements = placements
    }

    public var id: String { "\(provider.rawValue)/\(bucketID)" }

    public func isShown(in placement: GaugePlacement) -> Bool {
        placements.contains(placement)
    }
}

public struct GaugeLayout: Codable, Equatable, Sendable {
    public private(set) var entries: [GaugeEntry]

    public init(entries: [GaugeEntry] = []) {
        self.entries = entries
    }

    public func entries(in placement: GaugePlacement) -> [GaugeEntry] {
        entries.filter { $0.isShown(in: placement) }
    }

    /// Menu sections follow the first shown limit of each provider; providers with none trail in their usual order.
    public var menuProviderOrder: [UsageProvider] {
        var order: [UsageProvider] = []
        for provider in entries(in: .menu).map(\.provider) + UsageProvider.allCases where !order.contains(provider) {
            order.append(provider)
        }
        return order
    }

    public func bucketIDs(from provider: UsageProvider, in placement: GaugePlacement) -> [String] {
        entries(in: placement).filter { $0.provider == provider }.map(\.bucketID)
    }

    public func isLocked(_ entry: GaugeEntry, in placement: GaugePlacement) -> Bool {
        placement.requiresOne && entry.isShown(in: placement) && entries(in: placement).count == 1
    }

    /// The first buckets seen from a provider pick the defaults; anything appearing later starts hidden.
    public mutating func discover(_ buckets: [UsageBucket], from provider: UsageProvider) {
        let isFirstDiscovery = !entries.contains { $0.provider == provider }

        for (index, bucket) in buckets.enumerated() {
            if let existing = entries.firstIndex(where: { $0.provider == provider && $0.bucketID == bucket.id }) {
                entries[existing].title = bucket.title
                continue
            }

            let entry = GaugeEntry(
                provider: provider,
                bucketID: bucket.id,
                title: bucket.title,
                placements: isFirstDiscovery ? Self.defaultPlacements(for: bucket, at: index, from: provider) : []
            )
            entries.insert(entry, at: insertionIndex(for: provider))
        }
    }

    public mutating func setShown(_ isShown: Bool, in placement: GaugePlacement, for id: GaugeEntry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }

        if isShown {
            entries[index].placements.insert(placement)
        } else if !isLocked(entries[index], in: placement) {
            entries[index].placements.remove(placement)
        }
    }

    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { entries[$0] }
        let remaining = entries.indices.filter { !source.contains($0) }.map { entries[$0] }
        let target = destination - source.count(in: 0..<destination)

        entries = remaining
        entries.insert(contentsOf: moving, at: min(max(0, target), entries.count))
    }

    private static func defaultPlacements(
        for bucket: UsageBucket,
        at index: Int,
        from provider: UsageProvider
    ) -> Set<GaugePlacement> {
        let inMenuBar =
            switch provider {
            case .claude: bucket.role == .session || bucket.role == .fable
            case .codex: index == 0
            }
        return inMenuBar ? [.menuBar, .menu] : [.menu]
    }

    private func insertionIndex(for provider: UsageProvider) -> Int {
        if let last = entries.lastIndex(where: { $0.provider == provider }) { return last + 1 }

        let rank = UsageProvider.allCases.firstIndex(of: provider) ?? 0
        return entries.firstIndex { (UsageProvider.allCases.firstIndex(of: $0.provider) ?? 0) > rank } ?? entries.count
    }
}

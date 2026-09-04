import Foundation

enum AppPaths {
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static var cachedPayload: URL { supportDirectory.appendingPathComponent("usage.json") }
    static var pollingState: URL { supportDirectory.appendingPathComponent("polling-state.json") }
    static var codexCachedPayload: URL { supportDirectory.appendingPathComponent("codex-usage.json") }
    static var codexPollingState: URL { supportDirectory.appendingPathComponent("codex-polling-state.json") }
    static var refreshLock: URL { supportDirectory.appendingPathComponent("refresh.lock") }
}

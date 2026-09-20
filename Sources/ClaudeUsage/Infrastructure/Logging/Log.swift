import Foundation
import os

enum Log {
    private static let subsystem = "com.fredrir.ClaudeUsage"
    private static let logger = Logger(subsystem: subsystem, category: "usage")
    private static let queue = DispatchQueue(label: "\(subsystem).log")

    static var fileURL: URL { AppPaths.supportDirectory.appendingPathComponent("usage.log") }

    static func write(_ message: String) {
        logger.log("\(message, privacy: .public)")

        queue.async {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let line = "\(formatter.string(from: Date()))  \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }

            trimIfNeeded()
        }
    }

    private static func trimIfNeeded() {
        let limit = 256 * 1024
        guard
            let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
            size > limit,
            let contents = try? String(contentsOf: fileURL, encoding: .utf8)
        else { return }

        let kept = contents.split(separator: "\n", omittingEmptySubsequences: false).suffix(500)
        try? kept.joined(separator: "\n").data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }
}

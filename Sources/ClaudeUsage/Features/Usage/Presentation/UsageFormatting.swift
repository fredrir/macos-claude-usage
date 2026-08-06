import Foundation

enum ResetFormatter {
    static func text(for date: Date?, relativeTo now: Date) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "Resets now" }

        if interval < 24 * 3600 {
            let hours = Int(interval) / 3600
            let minutes = (Int(interval) % 3600) / 60
            return hours > 0 ? "Resets in \(hours)h \(minutes)m" : "Resets in \(minutes)m"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE HH:mm"
        return "Resets \(formatter.string(from: date))"
    }
}

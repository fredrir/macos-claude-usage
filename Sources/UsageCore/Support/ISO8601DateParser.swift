import Foundation

public enum ISO8601DateParser {
    public static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return try? Date(value, strategy: .iso8601)
    }
}

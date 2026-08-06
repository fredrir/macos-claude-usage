import Foundation

/// Parses the ISO-8601 timestamps emitted by the usage endpoint.
///
/// `Date.ISO8601FormatStyle` is a value type, avoiding shared mutable formatter instances and
/// accepting timestamps with no fractional seconds as well as millisecond and microsecond
/// precision.
public enum ISO8601DateParser {
    public static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return try? Date(value, strategy: .iso8601)
    }
}

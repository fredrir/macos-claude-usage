import Foundation

/// "Now", with a seam for `--screenshot`.
///
/// Everything the UI renders from a date — reset countdowns, the freshness line, the staleness
/// dimming — reads the clock through here, so pinning it makes a rendered screenshot
/// byte-identical between runs. `fixedNow` is nil in the shipping app.
enum AppClock {
    static var fixedNow: Date?
    static var now: Date { fixedNow ?? Date() }
}

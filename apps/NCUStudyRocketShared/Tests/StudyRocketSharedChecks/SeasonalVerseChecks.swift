import Foundation
import StudyRocketShared

func runSeasonalVerseChecks() {
    let calendar = SeasonalVerse.calendar
    precondition(calendar.timeZone.identifier == "Asia/Shanghai")
    let first = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
    var ids = Set<String>()
    for offset in 0..<366 {
        let date = calendar.date(byAdding: .day, value: offset, to: first)!
        guard let verse = SeasonalVerse.on(date) else {
            preconditionFailure("Missing bundled verse for \(date)")
        }
        let parts = calendar.dateComponents([.month, .day], from: date)
        precondition(verse.id == String(format: "%02d-%02d", parts.month!, parts.day!))
        precondition(!verse.text.isEmpty && !verse.author.isEmpty && !verse.work.isEmpty)
        precondition(verse.source.scheme == "https" && verse.source.host != nil)
        precondition(verse.punctuatedText.hasSuffix("。"))
        ids.insert(verse.id)
    }
    precondition(ids.count == 366 && ids.contains("02-29"))
    let iso = ISO8601DateFormatter()
    for (timestamp, beforeID, afterID) in [
        ("2026-11-14T15:59:59Z", "11-14", "11-15"),
        ("2026-02-28T15:59:59Z", "02-28", "03-01"),
        ("2024-02-28T15:59:59Z", "02-28", "02-29"),
        ("2024-02-29T15:59:59Z", "02-29", "03-01"),
        ("2026-12-31T15:59:59Z", "12-31", "01-01")
    ] {
        let before = iso.date(from: timestamp)!
        let capturedVerse = SeasonalVerse.on(before)!
        precondition(capturedVerse.id == beforeID)
        precondition(SeasonalVerse.on(before.addingTimeInterval(1))?.id == afterID)
        precondition(capturedVerse.id == beforeID, "A presented source must keep its captured verse")
    }
    let originalTimeZone = NSTimeZone.default
    defer { NSTimeZone.default = originalTimeZone }
    let instant = iso.date(from: "2026-11-14T16:00:00Z")!
    for identifier in ["America/Los_Angeles", "Europe/London", "Pacific/Auckland"] {
        NSTimeZone.default = TimeZone(identifier: identifier)!
        precondition(SeasonalVerse.on(instant)?.id == "11-15")
    }
    print("Seasonal verse checks passed: 366 bundled dates, leap/non-leap boundaries, Beijing midnight, year rollover and device time zones")
}

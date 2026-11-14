import Foundation

/// The same bundled verse for each Beijing calendar day, independent of connection or device time zone.
public struct SeasonalVerse: Identifiable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let author: String
    public let work: String
    public let source: URL

    public var punctuatedText: String { text.hasSuffix("。") ? text : text + "。" }

    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private static let verses: [String: Self] = {
        let url = Bundle.module.url(forResource: "SeasonalVerses", withExtension: "tsv")
        guard let url, let data = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var entries: [String: Self] = [:]
        for line in data.split(separator: "\n") {
            let columns = line.components(separatedBy: "\t")
            guard columns.count == 5, let link = URL(string: columns[4]) else { continue }
            entries[columns[0]] = Self(id: columns[0], text: columns[1], author: columns[2], work: columns[3], source: link)
        }
        return entries
    }()

    public static func on(_ date: Date) -> Self? {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return verses[String(format: "%02d-%02d", parts.month!, parts.day!)]
    }
}

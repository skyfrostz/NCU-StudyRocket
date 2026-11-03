import Foundation

/// Keep checked deliveries until the next Monday in Beijing. Raw edits and older clients
/// may leave an item undated; keep it until a plan save establishes its first known week.
public enum WeeklyDeliveryRollover {
    private static let historyHeading = "## 历史已完成交付物"
    private static let marker = "<!-- studyrocket:delivery-completed-week:"
    public static func weekStart(_ date: Date) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let monday = calendar.dateInterval(of: .weekOfYear, for: date)!.start
        let parts = calendar.dateComponents([.year, .month, .day], from: monday)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private struct Item {
        let lines: ArraySlice<String>
        let completed: Bool
        let week: String?
        var key: String { lines.joined(separator: "\n") }
    }

    private struct Section {
        let range: Range<Int>
        let items: [Item]
        init?(_ lines: [String]) {
            guard let heading = lines.firstIndex(where: { $0.hasPrefix("## 交付物") }) else { return nil }
            let start = heading + 1
            let end = lines[start...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
            let block = lines[start..<end]
            let left = block.indices.filter { lines[$0] == "<!-- studyrocket:deliveries:start -->" }
            let right = block.indices.filter { lines[$0] == "<!-- studyrocket:deliveries:end -->" }
            if left.isEmpty && right.isEmpty { range = start..<end }
            else if left.count == 1, right.count == 1, left[0] < right[0] { range = left[0]+1..<right[0] }
            else { return nil }
            var cursor = range.lowerBound
            var found: [Item] = []
            while cursor < range.upperBound {
                let first = cursor
                let line = lines[cursor]
                cursor += 1
                let completed = line.lowercased().hasPrefix("- [x] ")
                guard completed || line.hasPrefix("- [ ] ") else { continue }
                while cursor < range.upperBound, lines[cursor].hasPrefix("  ") { cursor += 1 }
                let body = lines[first..<cursor]
                var week: String?
                if cursor < range.upperBound, lines[cursor].hasPrefix(marker), lines[cursor].hasSuffix(" -->") {
                    let value = String(lines[cursor].dropFirst(marker.count).dropLast(4))
                    if value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil {
                        week = value
                        cursor += 1
                    }
                }
                found.append(Item(lines: body, completed: completed, week: week))
            }
            items = found
        }
    }

    /// Project the active list without writing. Use the projected document as the base
    /// of a full-plan replacement so its archive survives a client round trip.
    public static func projected(_ source: String, now: Date = .now, fileURL: URL? = nil) -> String {
        transform(source, previous: nil, now: now, lastKnown: observedWeek(fileURL, now: now))
    }

    public static func forSave(_ source: String, previous: String, now: Date = .now, fileURL: URL? = nil) -> String {
        transform(source, previous: previous, now: now, lastKnown: observedWeek(fileURL, now: now))
    }

    // For an undated legacy checkbox, the file timestamp proves it was already
    // checked by that week, even when the original completion date is unknown.
    private static func observedWeek(_ url: URL?, now: Date) -> String? {
        guard let url, let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        return weekStart(min(now, date))
    }

    private static func transform(_ source: String, previous: String?, now: Date, lastKnown: String?) -> String {
        let newline = source.contains("\r\n") ? "\r\n" : "\n"
        var lines = source.components(separatedBy: newline)
        guard let section = Section(lines) else { return source }
        let current = weekStart(now)
        var known: [String: String] = [:]
        if let previous, let old = Section(previous.components(separatedBy: previous.contains("\r\n") ? "\r\n" : "\n")) {
            for item in old.items where item.completed { known[item.key] = item.week ?? lastKnown }
        }
        var archived: [[String]] = []
        for item in section.items.reversed() {
            let end = item.lines.endIndex + (item.week == nil ? 0 : 1)
            let span = item.lines.startIndex..<end
            guard item.completed else {
                if item.week != nil { lines.remove(at: item.lines.endIndex) }
                continue
            }
            guard let week = item.week ?? known[item.key] ?? (previous == nil ? lastKnown : current) else { continue }
            let tag = marker + week + " -->"
            if week < current {
                archived.append(Array(item.lines) + [tag])
                lines.removeSubrange(span)
            } else if item.week == nil {
                lines.insert(tag, at: item.lines.endIndex)
            }
        }
        if !archived.isEmpty {
            if let index = lines.firstIndex(of: historyHeading) {
                let start = index + 1
                let end = lines[start...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
                // An editor opened on Sunday can submit the old list after Monday's
                // archive was projected. Consume matching archived occurrences once.
                var existing = Array(lines[start..<end])
                let missing = archived.reversed().filter { block in
                    guard let offset = existing.indices.first(where: { existing[$0...].starts(with: block) }) else { return true }
                    existing.removeSubrange(offset..<(offset + block.count))
                    return false
                }
                lines.insert(contentsOf: missing.flatMap { $0 }, at: start)
            } else {
                let index = section.range.lowerBound
                let nextHeading = lines[index...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
                lines.insert(contentsOf: ["", historyHeading] + archived.reversed().flatMap { $0 } + [""], at: nextHeading)
            }
        }
        return lines.joined(separator: newline)
    }
}

import Foundation

public struct OneOffEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var date: String
    public var start: String
    public var end: String?
    public var title: String
    public var location: String?
    public var note: String?
    public init(id: String = UUID().uuidString, date: String, start: String, end: String? = nil, title: String, location: String? = nil, note: String? = nil) {
        self.id = id; self.date = date; self.start = start; self.end = end
        self.title = title; self.location = location; self.note = note
    }
}

public enum OneOffSchedule {
    public static let startMarker = "<!-- studyrocket:events:start -->"
    public static let endMarker = "<!-- studyrocket:events:end -->"
    public static func minutes(_ value: String) -> Int? {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }
    public static func validate(_ events: [OneOffEvent]) throws {
        guard Set(events.map(\.id)).count == events.count else { throw TaskLinkageError.malformed }
        for event in events {
            guard !event.id.isEmpty, !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  PlanningDate.date(event.date).map(PlanningDate.key) == event.date,
                  let start = minutes(event.start), event.end == nil || minutes(event.end!) != nil,
                  event.end == nil || minutes(event.end!)! > start else { throw TaskLinkageError.malformed }
        }
    }
    public static func read(_ source: String) throws -> [OneOffEvent] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let left = lines.indices.filter { lines[$0] == startMarker }, right = lines.indices.filter { lines[$0] == endMarker }
        if left.isEmpty && right.isEmpty { return [] }
        guard left.count == 1, right.count == 1, let a = left.first, let b = right.first, a < b else { throw TaskLinkageError.malformed }
        var events: [OneOffEvent] = []
        for line in lines[(a + 1)..<b] where line.hasPrefix("|") {
            let c = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map {
                $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "&#124;", with: "|").replacingOccurrences(of: "<br>", with: "\n")
            }
            if c.first == "ID" || c.first?.allSatisfy({ $0 == "-" || $0 == " " }) == true { continue }
            guard c.count == 7 else { throw TaskLinkageError.malformed }
            events.append(OneOffEvent(id: c[0], date: c[1], start: c[2], end: c[3].isEmpty ? nil : c[3], title: c[4], location: c[5].isEmpty ? nil : c[5], note: c[6].isEmpty ? nil : c[6]))
        }
        try validate(events)
        return events
    }
    public static func write(_ events: [OneOffEvent], in source: String) throws -> String {
        try validate(events); _ = try read(source)
        func escape(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "&#124;").replacingOccurrences(of: "\n", with: "<br>") }
        let rows = events.sorted { ($0.date, $0.start, $0.id) < ($1.date, $1.start, $1.id) }.map { e in
            "| " + [e.id, e.date, e.start, e.end ?? "", e.title, e.location ?? "", e.note ?? ""].map(escape).joined(separator: " | ") + " |"
        }
        let block = ([startMarker, "| ID | 日期 | 开始 | 结束 | 名称 | 地点 | 说明 |", "| --- | --- | --- | --- | --- | --- | --- |"] + rows + [endMarker]).joined(separator: "\n")
        if let a = source.range(of: startMarker), let b = source.range(of: endMarker) {
            return source.replacingCharacters(in: a.lowerBound..<b.upperBound, with: block)
        }
        return source + "\n\n" + block + "\n"
    }
    public static func merged(_ snapshot: TimetableSnapshot, source: String?, now: Date, selectedWeek: Bool = false) -> TimetableSnapshot {
        guard let source else { return snapshot }
        guard let events = try? read(source), !events.isEmpty else { return snapshot }
        let calendar = PlanningDate.calendar
        let start: Date
        if (selectedWeek || snapshot.status == .available), let first = snapshot.days.first, let date = PlanningDate.date(first.id) { start = date }
        else {
            guard !selectedWeek else { return snapshot }
            let day = calendar.startOfDay(for: now)
            start = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: day) + 5) % 7), to: day)!
        }
        let days = (0..<7).map { offset -> TimetableDaySnapshot in
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            let key = PlanningDate.key(date)
            let old = snapshot.days.first(where: { $0.id == key })
            var entries = old?.entries ?? []
            for event in events where event.date == key {
                // The same dated activity may already have been entered in the imported document.
                guard !entries.contains(where: { $0.title == event.title && $0.startTime == event.start && $0.location == event.location }) else { continue }
                let conflicts = entries.contains { other in
                    guard other.kind != .holiday, let s = other.startTime.flatMap(minutes), let e = other.endTime.flatMap(minutes),
                          let a = minutes(event.start) else { return false }
                    let b = event.end.flatMap(minutes) ?? a + 1
                    return a < e && s < b
                }
                let note = [event.note, conflicts ? "⚠️ 与当天其他安排时间冲突" : nil].compactMap { $0 }.joined(separator: "；")
                entries.append(TimetableEntrySnapshot(id: event.id, kind: .event, title: event.title, startTime: event.start,
                    endTime: event.end, location: event.location, note: note.isEmpty ? nil : note))
            }
            // Mark both sides, including event/event overlaps. Keep all original entries.
            let warning = "⚠️ 与当天其他安排时间冲突"
            let conflicting = entries.indices.filter { i in
                guard entries[i].kind != .holiday, let a = entries[i].startTime.flatMap(minutes) else { return false }
                let b = entries[i].endTime.flatMap(minutes) ?? a + 1
                return entries.indices.contains { j in
                    guard j != i, entries[j].kind != .holiday, let c = entries[j].startTime.flatMap(minutes) else { return false }
                    let d = entries[j].endTime.flatMap(minutes) ?? c + 1
                    return a < d && c < b
                }
            }
            for i in conflicting where entries[i].note?.contains(warning) != true {
                let old = entries[i]
                entries[i] = TimetableEntrySnapshot(id: old.id, kind: old.kind, title: old.title, startTime: old.startTime,
                    endTime: old.endTime, periodLabel: old.periodLabel, location: old.location, instructor: old.instructor,
                    note: [old.note, warning].compactMap { $0 }.joined(separator: "；"))
            }
            entries.sort { ($0.startTime ?? "99:99", $0.id) < ($1.startTime ?? "99:99", $1.id) }
            return TimetableDaySnapshot(id: key, dateLabel: old?.dateLabel ?? key, week: old?.week ?? 0,
                weekday: old?.weekday ?? (calendar.component(.weekday, from: date) + 5) % 7 + 1,
                weekdayLabel: old?.weekdayLabel ?? "周" + ["一", "二", "三", "四", "五", "六", "日"][(calendar.component(.weekday, from: date) + 5) % 7], entries: entries)
        }
        let hasEvents = days.contains { !$0.entries.isEmpty }
        return TimetableSnapshot(status: hasEvents ? .available : snapshot.status, classLabel: snapshot.classLabel, termLabel: snapshot.termLabel,
            referenceDate: snapshot.referenceDate, teachingWeek: snapshot.status == .available || selectedWeek ? snapshot.teachingWeek : nil,
            weekLabel: snapshot.status == .available || selectedWeek ? snapshot.weekLabel : "当周活动",
            weekStartDate: PlanningDate.key(start), firstImportedDate: snapshot.firstImportedDate,
            lastImportedDate: snapshot.lastImportedDate, days: days)
    }
}

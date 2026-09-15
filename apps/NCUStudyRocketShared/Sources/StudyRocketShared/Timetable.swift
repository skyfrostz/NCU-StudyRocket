import Foundation
import CryptoKit

public enum TimetableStatus: String, Codable, Equatable, Sendable {
    case available
    case notImported
    case invalid
    case beforeTerm
    case afterTerm
}

public enum TimetableEntryKind: String, Codable, Equatable, Sendable {
    case course
    case support
    case officeHour
    case event
    case holiday
}

public struct TimetableEntrySnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: TimetableEntryKind
    public let title: String
    public let startTime: String?
    public let endTime: String?
    public let periodLabel: String?
    public let location: String?
    public let instructor: String?
    public let note: String?

    public init(
        id: String,
        kind: TimetableEntryKind,
        title: String,
        startTime: String? = nil,
        endTime: String? = nil,
        periodLabel: String? = nil,
        location: String? = nil,
        instructor: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.periodLabel = periodLabel
        self.location = location
        self.instructor = instructor
        self.note = note
    }
}

public struct TimetableDaySnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let dateLabel: String
    public let week: Int
    public let weekday: Int
    public let weekdayLabel: String
    public let entries: [TimetableEntrySnapshot]

    public init(
        id: String,
        dateLabel: String,
        week: Int,
        weekday: Int,
        weekdayLabel: String,
        entries: [TimetableEntrySnapshot]
    ) {
        self.id = id
        self.dateLabel = dateLabel
        self.week = week
        self.weekday = weekday
        self.weekdayLabel = weekdayLabel
        self.entries = entries
    }
}

/// A dated entry from the complete Markdown timetable.  Week snapshots stay
/// compact for the homepage, while this value gives importers and timetable
/// browsers a typed representation of the whole source document.
public struct TimetableRecord: Equatable, Sendable, Identifiable {
    public let id: String
    public let date: String
    public let teachingWeek: Int?
    public let entry: TimetableEntrySnapshot

    public init(date: String, teachingWeek: Int? = nil, entry: TimetableEntrySnapshot) {
        self.id = entry.id
        self.date = date
        self.teachingWeek = teachingWeek
        self.entry = entry
    }
}

/// The validated, complete content of the managed timetable section.  It is
/// deliberately not persisted as a second database: callers render it back
/// into Markdown before saving through the existing repository guard.
public struct TimetableDocument: Equatable, Sendable {
    public let classLabel: String
    public let termLabel: String
    public let firstImportedDate: String
    public let lastImportedDate: String
    public let entries: [TimetableRecord]

    public init(
        classLabel: String,
        termLabel: String,
        firstImportedDate: String,
        lastImportedDate: String,
        entries: [TimetableRecord]
    ) {
        self.classLabel = classLabel
        self.termLabel = termLabel
        self.firstImportedDate = firstImportedDate
        self.lastImportedDate = lastImportedDate
        self.entries = entries
    }

    public var teachingWeeks: [Int] {
        Array(Set(entries.compactMap(\.teachingWeek))).sorted()
    }
}

public struct TimetableSnapshot: Codable, Equatable, Sendable {
    public let status: TimetableStatus
    public let classLabel: String
    public let termLabel: String
    public let referenceDate: String
    public let teachingWeek: Int?
    public let weekLabel: String?
    public let weekStartDate: String?
    public let firstImportedDate: String?
    public let lastImportedDate: String?
    public let days: [TimetableDaySnapshot]

    public init(
        status: TimetableStatus,
        classLabel: String,
        termLabel: String,
        referenceDate: String,
        teachingWeek: Int? = nil,
        weekLabel: String? = nil,
        weekStartDate: String? = nil,
        firstImportedDate: String? = nil,
        lastImportedDate: String? = nil,
        days: [TimetableDaySnapshot] = []
    ) {
        self.status = status
        self.classLabel = classLabel
        self.termLabel = termLabel
        self.referenceDate = referenceDate
        self.teachingWeek = teachingWeek
        self.weekLabel = weekLabel
        self.weekStartDate = weekStartDate
        self.firstImportedDate = firstImportedDate
        self.lastImportedDate = lastImportedDate
        self.days = days
    }
}

/// Parses the managed timetable Markdown used by both the Mac app and Host.
/// The parser returns only the teaching week containing the reference date,
/// keeping the mobile snapshot small while the Markdown remains the full source.
public enum StudyRocketTimetableParser {
    public static let sourceFile = "工作台/学期/2026秋季个人课表.md"
    public static let defaultClassLabel = "261 一班"

    public static func snapshot(from source: String?, now: Date = .now) -> TimetableSnapshot {
        let calendar = makeCalendar()
        let referenceDate = isoDate(now, calendar: calendar)
        guard let source else {
            return TimetableSnapshot(
                status: .notImported,
                classLabel: defaultClassLabel,
                termLabel: "2026-2027 秋季学期",
                referenceDate: referenceDate
            )
        }

        do {
            let parsed = try parse(source, calendar: calendar)
            let reference = calendar.startOfDay(for: now)
            let first = parsed.firstDate
            let last = parsed.lastDate
            if reference < first {
                return TimetableSnapshot(
                    status: .beforeTerm,
                    classLabel: parsed.classLabel,
                    termLabel: parsed.termLabel,
                    referenceDate: referenceDate,
                    teachingWeek: 1,
                    weekLabel: "第1周",
                    weekStartDate: isoDate(first, calendar: calendar),
                    firstImportedDate: isoDate(first, calendar: calendar),
                    lastImportedDate: isoDate(last, calendar: calendar)
                )
            }
            if reference > last {
                return TimetableSnapshot(
                    status: .afterTerm,
                    classLabel: parsed.classLabel,
                    termLabel: parsed.termLabel,
                    referenceDate: referenceDate,
                    firstImportedDate: isoDate(first, calendar: calendar),
                    lastImportedDate: isoDate(last, calendar: calendar)
                )
            }

            let dayOffset = calendar.dateComponents([.day], from: first, to: reference).day ?? 0
            let week = max(1, dayOffset / 7 + 1)
            let weekStart = calendar.date(byAdding: .day, value: (week - 1) * 7, to: first) ?? first
            let days = (0..<7).compactMap { offset -> TimetableDaySnapshot? in
                guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
                let id = isoDate(date, calendar: calendar)
                let entries = parsed.entriesByDate[id, default: []].sorted(by: entrySort)
                return TimetableDaySnapshot(
                    id: id,
                    dateLabel: dateLabel(date, calendar: calendar),
                    week: week,
                    weekday: weekdayNumber(date, calendar: calendar),
                    weekdayLabel: weekdayLabel(date, calendar: calendar),
                    entries: entries
                )
            }
            return TimetableSnapshot(
                status: .available,
                classLabel: parsed.classLabel,
                termLabel: parsed.termLabel,
                referenceDate: referenceDate,
                teachingWeek: week,
                weekLabel: "第\(week)周",
                weekStartDate: isoDate(weekStart, calendar: calendar),
                firstImportedDate: isoDate(first, calendar: calendar),
                lastImportedDate: isoDate(last, calendar: calendar),
                days: days
            )
        } catch {
            return TimetableSnapshot(
                status: .invalid,
                classLabel: defaultClassLabel,
                termLabel: "2026-2027 秋季学期",
                referenceDate: referenceDate
            )
        }
    }

    /// Returns the whole managed timetable after applying the same validation
    /// used by the homepage and Host snapshot builder.
    public static func document(from source: String) throws -> TimetableDocument {
        let calendar = makeCalendar()
        let parsed = try parse(source, calendar: calendar)
        return TimetableDocument(
            classLabel: parsed.classLabel,
            termLabel: parsed.termLabel,
            firstImportedDate: isoDate(parsed.firstDate, calendar: calendar),
            lastImportedDate: isoDate(parsed.lastDate, calendar: calendar),
            entries: parsed.records.sorted(by: recordSort)
        )
    }

    /// Builds a chosen teaching-week view without changing the reference date
    /// used by the rest of the snapshot.  This is used by read-only timetable
    /// browsers on Mac and iPhone.
    public static func snapshot(
        from source: String?,
        teachingWeek: Int,
        now: Date = .now
    ) -> TimetableSnapshot {
        let calendar = makeCalendar()
        let referenceDate = isoDate(now, calendar: calendar)
        guard let source else {
            return TimetableSnapshot(
                status: .notImported,
                classLabel: defaultClassLabel,
                termLabel: "2026-2027 秋季学期",
                referenceDate: referenceDate
            )
        }

        do {
            let parsed = try parse(source, calendar: calendar)
            let dayCount = (calendar.dateComponents([.day], from: parsed.firstDate, to: parsed.lastDate).day ?? 0) + 1
            let lastWeek = max(1, Int(ceil(Double(dayCount) / 7)))
            guard teachingWeek >= 1 else {
                return TimetableSnapshot(
                    status: .beforeTerm,
                    classLabel: parsed.classLabel,
                    termLabel: parsed.termLabel,
                    referenceDate: referenceDate,
                    teachingWeek: 1,
                    weekLabel: "第1周",
                    weekStartDate: isoDate(parsed.firstDate, calendar: calendar),
                    firstImportedDate: isoDate(parsed.firstDate, calendar: calendar),
                    lastImportedDate: isoDate(parsed.lastDate, calendar: calendar)
                )
            }
            guard teachingWeek <= lastWeek else {
                return TimetableSnapshot(
                    status: .afterTerm,
                    classLabel: parsed.classLabel,
                    termLabel: parsed.termLabel,
                    referenceDate: referenceDate,
                    firstImportedDate: isoDate(parsed.firstDate, calendar: calendar),
                    lastImportedDate: isoDate(parsed.lastDate, calendar: calendar)
                )
            }
            let weekStart = calendar.date(byAdding: .day, value: (teachingWeek - 1) * 7, to: parsed.firstDate) ?? parsed.firstDate
            let days = (0..<7).compactMap { offset -> TimetableDaySnapshot? in
                guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
                let id = isoDate(date, calendar: calendar)
                return TimetableDaySnapshot(
                    id: id,
                    dateLabel: dateLabel(date, calendar: calendar),
                    week: teachingWeek,
                    weekday: weekdayNumber(date, calendar: calendar),
                    weekdayLabel: weekdayLabel(date, calendar: calendar),
                    entries: parsed.entriesByDate[id, default: []].sorted(by: entrySort)
                )
            }
            return TimetableSnapshot(
                status: .available,
                classLabel: parsed.classLabel,
                termLabel: parsed.termLabel,
                referenceDate: referenceDate,
                teachingWeek: teachingWeek,
                weekLabel: "第\(teachingWeek)周",
                weekStartDate: isoDate(weekStart, calendar: calendar),
                firstImportedDate: isoDate(parsed.firstDate, calendar: calendar),
                lastImportedDate: isoDate(parsed.lastDate, calendar: calendar),
                days: days
            )
        } catch {
            return TimetableSnapshot(
                status: .invalid,
                classLabel: defaultClassLabel,
                termLabel: "2026-2027 秋季学期",
                referenceDate: referenceDate
            )
        }
    }

    public static func teachingWeekRange(from source: String?) -> ClosedRange<Int>? {
        guard let source,
              let document = try? document(from: source) else { return nil }
        let calendar = makeCalendar()
        guard let first = try? parseISODate(document.firstImportedDate, calendar: calendar),
              let last = try? parseISODate(document.lastImportedDate, calendar: calendar) else { return nil }
        let dayCount = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        return 1...max(1, Int(ceil(Double(dayCount) / 7)))
    }

    /// Renders only the managed block.  Desktop callers retain the title and
    /// any explanatory text outside this boundary when they save an import.
    public static func managedMarkdown(for document: TimetableDocument) -> String {
        let records = document.entries.sorted(by: recordSort)
        var lines = [
            "<!-- studyrocket:timetable:start -->",
            "",
            "| 字段 | 内容 |",
            "| --- | --- |",
            "| 班级 | \(escapeTableCell(document.classLabel)) |",
            "| 学期 | \(escapeTableCell(document.termLabel)) |",
            "| 起始日期 | \(escapeTableCell(document.firstImportedDate)) |",
            "| 结束日期 | \(escapeTableCell(document.lastImportedDate)) |",
            "",
            "| 日期 | 周次 | 类型 | 开始 | 结束 | 节次 | 名称 | 地点 | 教师 | 备注 |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
        ]
        lines.append(contentsOf: records.map { record in
            let entry = record.entry
            let values = [
                record.date,
                record.teachingWeek.map(String.init) ?? "",
                entryKindLabel(entry.kind),
                entry.startTime ?? "",
                entry.endTime ?? "",
                entry.periodLabel ?? "",
                entry.title,
                entry.location ?? "",
                entry.instructor ?? "",
                entry.note ?? ""
            ]
            .map(escapeTableCell)
            return "| \(values.joined(separator: " | ")) |"
        })
        lines.append("")
        lines.append("<!-- studyrocket:timetable:end -->")
        return lines.joined(separator: "\n")
    }

    private struct ParsedSource {
        let classLabel: String
        let termLabel: String
        let firstDate: Date
        let lastDate: Date
        let entriesByDate: [String: [TimetableEntrySnapshot]]
        let records: [TimetableRecord]
    }

    private enum ParseError: Error {
        case malformedMetadata
        case malformedEntry
        case invalidDate
        case invalidRange
        case invalidKind
        case duplicateEntry
    }

    private static func parse(_ source: String, calendar: Calendar) throws -> ParsedSource {
        let lines = source.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { isMarker($0, "studyrocket:timetable:start") }),
              let end = lines[(start + 1)..<lines.count].firstIndex(where: { isMarker($0, "studyrocket:timetable:end") }) else {
            throw ParseError.malformedMetadata
        }

        var classLabel = defaultClassLabel
        var termLabel = "2026-2027 秋季学期"
        var firstDate: Date?
        var lastDate: Date?
        var inEntries = false
        var entryHeader: [String: Int] = [:]
        var entries: [TimetableEntrySnapshot] = []
        var entryDates: [String] = []
        var records: [TimetableRecord] = []
        var seenIDs = Set<String>()

        for line in lines[(start + 1)..<end] {
            guard let cells = tableCells(from: line) else { continue }
            if cells.count >= 2, !isDivider(cells), !inEntries {
                let key = normalized(cells[0])
                let value = cells[1].trimmingCharacters(in: .whitespacesAndNewlines)
                switch key {
                case "班级", "class", "classlabel":
                    if !value.isEmpty { classLabel = value }
                case "学期", "term", "termlabel":
                    if !value.isEmpty { termLabel = value }
                case "起始日期", "首周周一", "开始日期", "start", "startdate":
                    firstDate = try parseISODate(value, calendar: calendar)
                case "结束日期", "最后日期", "end", "enddate":
                    lastDate = try parseISODate(value, calendar: calendar)
                default:
                    break
                }
            }

            let normalizedHeader = cells.map(normalized)
            if normalizedHeader.contains("日期") && normalizedHeader.contains("类型") && normalizedHeader.contains("名称") {
                inEntries = true
                var header: [String: Int] = [:]
                for (index, value) in normalizedHeader.enumerated() where !value.isEmpty {
                    guard header[value] == nil else { throw ParseError.malformedMetadata }
                    header[value] = index
                }
                entryHeader = header
                continue
            }
            guard inEntries, !isDivider(cells), cells.count >= 3 else { continue }
            let value: (String) -> String = { key in
                guard let index = entryHeader[key], cells.indices.contains(index) else { return "" }
                return cells[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let dateText = value("日期")
            guard !dateText.isEmpty else { throw ParseError.malformedEntry }
            let date = try parseISODate(dateText, calendar: calendar)
            let kindText = normalized(value("类型"))
            if kindText == "break" || kindText == "休息" { continue }
            guard let sourceKind = entryKind(kindText) else {
                throw ParseError.invalidKind
            }
            let rawTitle = value("名称")
            guard !rawTitle.isEmpty else { throw ParseError.malformedEntry }
            let presentation = StudyRocketTimetableCourseCatalog.presentation(kind: sourceKind, title: rawTitle)
            let kind = presentation.kind
            let title = presentation.title
            let week = value("周次")
            let period = value("节次")
            let startTime = value("开始")
            let endTime = value("结束")
            let location = value("地点")
            let instructor = value("教师")
            let note = value("备注")
            let id = stableID([
                isoDate(date, calendar: calendar), week, kind.rawValue, startTime, endTime,
                period, title, location, instructor, note
            ])
            guard seenIDs.insert(id).inserted else { throw ParseError.duplicateEntry }
            let entry = TimetableEntrySnapshot(
                id: id,
                kind: kind,
                title: title,
                startTime: startTime.isEmpty ? nil : startTime,
                endTime: endTime.isEmpty ? nil : endTime,
                periodLabel: period.isEmpty ? nil : period,
                location: location.isEmpty ? nil : location,
                instructor: instructor.isEmpty ? nil : instructor,
                note: note.isEmpty ? nil : note
            )
            let normalizedDate = isoDate(date, calendar: calendar)
            entries.append(entry)
            entryDates.append(normalizedDate)
            records.append(TimetableRecord(
                date: normalizedDate,
                teachingWeek: teachingWeek(from: week),
                entry: entry
            ))
        }

        guard let firstDate, let lastDate else { throw ParseError.malformedMetadata }
        guard firstDate <= lastDate else { throw ParseError.invalidRange }
        guard !entries.isEmpty else { throw ParseError.malformedEntry }
        var entriesByDate: [String: [TimetableEntrySnapshot]] = [:]
        for (entry, date) in zip(entries, entryDates) {
            entriesByDate[date, default: []].append(entry)
        }
        for dateText in entryDates {
            let date = try parseISODate(dateText, calendar: calendar)
            guard date >= firstDate && date <= lastDate else { throw ParseError.invalidDate }
        }
        return ParsedSource(
            classLabel: classLabel,
            termLabel: termLabel,
            firstDate: firstDate,
            lastDate: lastDate,
            entriesByDate: entriesByDate,
            records: records
        )
    }

    private static func entryKind(_ value: String) -> TimetableEntryKind? {
        switch value {
        case "course", "课程", "正式课": return .course
        case "support", "答疑", "学术答疑", "学术技能": return .support
        case "officehour", "office", "办公时间": return .officeHour
        case "event", "活动", "会议", "见面会": return .event
        case "holiday", "假期", "节假日": return .holiday
        default: return nil
        }
    }

    private static func entrySort(_ lhs: TimetableEntrySnapshot, _ rhs: TimetableEntrySnapshot) -> Bool {
        let left = minutes(lhs.startTime)
        let right = minutes(rhs.startTime)
        if left != right { return left < right }
        return lhs.id < rhs.id
    }

    private static func recordSort(_ lhs: TimetableRecord, _ rhs: TimetableRecord) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return entrySort(lhs.entry, rhs.entry)
    }

    private static func teachingWeek(from value: String) -> Int? {
        guard let range = value.range(of: #"\d+"#, options: .regularExpression),
              let week = Int(value[range]), week > 0 else { return nil }
        return week
    }

    private static func entryKindLabel(_ value: TimetableEntryKind) -> String {
        switch value {
        case .course: "课程"
        case .support: "答疑"
        case .officeHour: "officeHour"
        case .event: "活动"
        case .holiday: "假期"
        }
    }

    private static func escapeTableCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func minutes(_ value: String?) -> Int {
        guard let value,
              let match = value.range(of: #"^\s*(\d{1,2})\s*[:：]\s*(\d{2})"#, options: .regularExpression) else { return Int.max }
        let numbers = String(value[match]).split { !$0.isNumber }.compactMap { Int($0) }
        guard numbers.count == 2 else { return Int.max }
        return numbers[0] * 60 + numbers[1]
    }

    private static func tableCells(from line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("|") else { return nil }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
                current.append(character)
            } else if character == "|" {
                cells.append(unescape(current.trimmingCharacters(in: .whitespaces)))
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { cells.append(unescape(current.trimmingCharacters(in: .whitespaces))) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    private static func isDivider(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            return !value.isEmpty && value.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .lowercased()
    }

    private static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\|", with: "|").replacingOccurrences(of: "<br>", with: "\n")
    }

    private static func isMarker(_ line: String, _ marker: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == "<!-- \(marker) -->"
    }

    private static func parseISODate(_ value: String, calendar: Calendar) throws -> Date {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw ParseError.invalidDate
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { throw ParseError.invalidDate }
        return calendar.startOfDay(for: date)
    }

    private static func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }

    private static func isoDate(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func dateLabel(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日 · EEE"
        return formatter.string(from: date)
    }

    private static func weekdayLabel(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    private static func weekdayNumber(_ date: Date, calendar: Calendar) -> Int {
        let sundayBased = calendar.component(.weekday, from: date)
        return (sundayBased + 5) % 7 + 1
    }

    private static func stableID(_ parts: [String]) -> String {
        let input = parts.joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(input.utf8))
        return "timetable-" + digest.map { String(format: "%02x", $0) }.joined().prefix(24)
    }
}

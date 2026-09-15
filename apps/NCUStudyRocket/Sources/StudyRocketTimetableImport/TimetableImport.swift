import Foundation
import StudyRocketShared

public enum TimetableImportFormat: String, Equatable, Sendable {
    case markdown
    case csv
    case xlsx

    public var title: String {
        switch self {
        case .markdown: "Markdown"
        case .csv: "CSV"
        case .xlsx: "Excel"
        }
    }
}

public struct TimetableImportDefaults: Equatable, Sendable {
    public let classLabel: String
    public let termLabel: String
    public let sourceClassLabel: String
    public let maximumTeachingWeek: Int?

    public init(
        classLabel: String = StudyRocketTimetableParser.defaultClassLabel,
        termLabel: String = "2026-2027 秋季学期",
        sourceClassLabel: String = "一班",
        maximumTeachingWeek: Int? = 16
    ) {
        self.classLabel = classLabel
        self.termLabel = termLabel
        self.sourceClassLabel = sourceClassLabel
        self.maximumTeachingWeek = maximumTeachingWeek
    }
}

public struct TimetableImportPreview: Equatable, Sendable {
    public let fileName: String
    public let format: TimetableImportFormat
    public let document: TimetableDocument
    public let managedMarkdown: String
    public let warnings: [String]

    public init(
        fileName: String,
        format: TimetableImportFormat,
        document: TimetableDocument,
        managedMarkdown: String,
        warnings: [String]
    ) {
        self.fileName = fileName
        self.format = format
        self.document = document
        self.managedMarkdown = managedMarkdown
        self.warnings = warnings
    }
}

public enum TimetableImportError: LocalizedError, Equatable {
    case unsupportedFormat
    case invalidFile
    case fileTooLarge
    case invalidContents(String)
    case unreadableWorkbook

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "仅支持 .xlsx、.csv 和 StudyRocket 课表 Markdown。"
        case .invalidFile:
            "所选文件不是可读取的普通文件。"
        case .fileTooLarge:
            "课表文件过大，未读取。"
        case .invalidContents(let message):
            message
        case .unreadableWorkbook:
            "无法读取 Excel 课表结构。"
        }
    }
}

public enum StudyRocketTimetableImport {
    public static let maximumFileBytes = 12 * 1024 * 1024

    public static func preview(
        fileURL: URL,
        defaults: TimetableImportDefaults = .init()
    ) throws -> TimetableImportPreview {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw TimetableImportError.invalidFile
        }
        guard (values.fileSize ?? 0) <= maximumFileBytes else {
            throw TimetableImportError.fileTooLarge
        }

        let extensionName = fileURL.pathExtension.lowercased()
        let format: TimetableImportFormat
        let document: TimetableDocument
        var warnings: [String] = []

        switch extensionName {
        case "md", "markdown":
            format = .markdown
            do {
                document = try StudyRocketTimetableParser.document(
                    from: String(contentsOf: fileURL, encoding: .utf8)
                )
            } catch {
                throw TimetableImportError.invalidContents("Markdown 课表格式无效：\(error.localizedDescription)")
            }
        case "csv":
            format = .csv
            do {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                document = try TimetableImportNormalization.document(
                    fromRows: try TimetableImportNormalization.csvRows(from: source),
                    defaults: defaults
                )
            } catch let error as TimetableImportError {
                throw error
            } catch {
                throw TimetableImportError.invalidContents("CSV 课表格式无效：\(error.localizedDescription)")
            }
        case "xlsx":
            format = .xlsx
            do {
                let imported = try XLSXTimetableImporter.document(from: fileURL, defaults: defaults)
                document = imported.document
                warnings = imported.warnings
            } catch let error as TimetableImportError {
                throw error
            } catch {
                throw TimetableImportError.invalidContents("Excel 课表格式无效：\(error.localizedDescription)")
            }
        default:
            throw TimetableImportError.unsupportedFormat
        }

        do {
            let markdown = StudyRocketTimetableParser.managedMarkdown(for: document)
            let validated = try StudyRocketTimetableParser.document(from: markdown)
            return TimetableImportPreview(
                fileName: fileURL.lastPathComponent,
                format: format,
                document: validated,
                managedMarkdown: markdown,
                warnings: warnings
            )
        } catch {
            throw TimetableImportError.invalidContents("导入结果未通过课表校验：\(error.localizedDescription)")
        }
    }
}

enum TimetableImportNormalization {
    private struct Draft {
        let date: Date
        let week: Int?
        let entry: TimetableEntrySnapshot
    }

    static func document(
        fromRows rows: [[String]],
        defaults: TimetableImportDefaults
    ) throws -> TimetableDocument {
        guard let headerIndex = rows.firstIndex(where: hasNormalizedTableHeader) else {
            throw TimetableImportError.invalidContents("未找到包含“日期、类型、名称”的表头。")
        }

        let header = rows[headerIndex]
        var indexes: [String: Int] = [:]
        for (index, value) in header.map(normalized).enumerated() where !value.isEmpty {
            guard indexes[value] == nil else {
                throw TimetableImportError.invalidContents("课表表头存在重复字段。")
            }
            indexes[value] = index
        }

        func value(_ row: [String], _ names: [String]) -> String {
            for name in names {
                if let index = indexes[name], row.indices.contains(index) {
                    return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return ""
        }

        var classLabel = defaults.classLabel
        var termLabel = defaults.termLabel
        var drafts: [Draft] = []
        for (rowIndex, row) in rows.dropFirst(headerIndex + 1).enumerated() {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { continue }
            let dateValue = value(row, ["日期", "date"])
            if dateValue.isEmpty { continue }
            let date = try parseDate(dateValue)
            let kindText = value(row, ["类型", "type"])
            let rawTitle = value(row, ["名称", "name", "课程"])
            guard !rawTitle.isEmpty else {
                throw TimetableImportError.invalidContents("第\(headerIndex + rowIndex + 2)行缺少课程名称。")
            }
            guard let sourceKind = entryKind(kindText) else {
                throw TimetableImportError.invalidContents("第\(headerIndex + rowIndex + 2)行课程类型无效。")
            }
            if sourceKind == .holiday, normalized(kindText) == "break" { continue }

            let presentation = StudyRocketTimetableCourseCatalog.presentation(kind: sourceKind, title: rawTitle)
            let kind = presentation.kind
            let title = presentation.title

            let start = try normalizedTime(value(row, ["开始", "start", "starttime"]))
            let end = try normalizedTime(value(row, ["结束", "end", "endtime"]))
            if let start, let end, timeMinutes(start) > timeMinutes(end) {
                throw TimetableImportError.invalidContents("第\(headerIndex + rowIndex + 2)行结束时间早于开始时间。")
            }
            let week = try teachingWeek(value(row, ["周次", "week", "teachingweek"]))
            let entry = TimetableEntrySnapshot(
                id: "import-\(headerIndex + rowIndex + 2)",
                kind: kind,
                title: title,
                startTime: start,
                endTime: end,
                periodLabel: emptyToNil(value(row, ["节次", "period", "periodlabel"])),
                location: emptyToNil(value(row, ["地点", "location", "room"])),
                instructor: emptyToNil(value(row, ["教师", "teacher", "instructor"])),
                note: emptyToNil(value(row, ["备注", "note", "remarks"]))
            )
            drafts.append(Draft(date: date, week: week, entry: entry))
            let importedClass = value(row, ["班级", "class", "classlabel"])
            if !importedClass.isEmpty { classLabel = importedClass }
            let importedTerm = value(row, ["学期", "term", "termlabel"])
            if !importedTerm.isEmpty { termLabel = importedTerm }
        }

        guard let sourceFirst = drafts.map(\.date).min() else {
            throw TimetableImportError.invalidContents("课表中没有可导入的课程行。")
        }
        let imported = drafts.compactMap { draft -> TimetableRecord? in
            let resolvedWeek = draft.week ?? weekNumber(for: draft.date, firstDate: sourceFirst)
            guard defaults.maximumTeachingWeek.map({ resolvedWeek <= $0 }) ?? true else { return nil }
            return TimetableRecord(
                date: dateString(draft.date),
                teachingWeek: resolvedWeek,
                entry: draft.entry
            )
        }
        guard let first = imported.compactMap({ try? parseDate($0.date) }).min(),
              let last = imported.compactMap({ try? parseDate($0.date) }).max(),
              !imported.isEmpty else {
            throw TimetableImportError.invalidContents("课表没有落在当前导入周次范围内的课程行。")
        }
        return TimetableDocument(
            classLabel: classLabel,
            termLabel: termLabel,
            firstImportedDate: dateString(first),
            lastImportedDate: dateString(last),
            entries: imported
        )
    }

    static func csvRows(from source: String) throws -> [[String]] {
        let characters = Array(source.drop(while: { $0 == "\u{feff}" }))
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var inQuotes = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if inQuotes, index + 1 < characters.count, characters[index + 1] == "\"" {
                    cell.append("\"")
                    index += 2
                    continue
                }
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                row.append(cell)
                cell = ""
            } else if (character == "\n" || character == "\r"), !inQuotes {
                row.append(cell)
                rows.append(row)
                row = []
                cell = ""
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" {
                    index += 1
                }
            } else {
                cell.append(character)
            }
            index += 1
        }
        guard !inQuotes else {
            throw TimetableImportError.invalidContents("CSV 引号未闭合。")
        }
        if !row.isEmpty || !cell.isEmpty { rows.append(row + [cell]) }
        return rows
    }

    static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .lowercased()
    }

    static func hasNormalizedTableHeader(_ row: [String]) -> Bool {
        let values = Set(row.map(normalized))
        let chinese = Set(["日期", "周次", "类型", "开始", "结束", "节次", "名称", "地点", "教师", "备注"])
        let english = Set(["date", "week", "type", "start", "end", "period", "name", "location", "teacher", "note"])
        return chinese.isSubset(of: values) || english.isSubset(of: values)
    }

    static func dateString(_ value: Date) -> String {
        dateFormatter.string(from: value)
    }

    static func parseDate(_ value: String) throws -> Date {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              parts[0] >= 2000,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              dateString(date) == trimmed else {
            throw TimetableImportError.invalidContents("日期必须为 YYYY-MM-DD。")
        }
        return date
    }

    static func normalizedTime(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pieces = trimmed.replacingOccurrences(of: "：", with: ":").split(separator: ":")
        guard pieces.count == 2,
              let hour = Int(pieces[0]), let minute = Int(pieces[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else {
            throw TimetableImportError.invalidContents("时间必须为 HH:mm。")
        }
        return String(format: "%02d:%02d", hour, minute)
    }

    static func timeMinutes(_ value: String) -> Int {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        return (parts.first ?? 0) * 60 + (parts.last ?? 0)
    }

    static func teachingWeek(_ value: String) throws -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let range = trimmed.range(of: #"\d+"#, options: .regularExpression),
              let week = Int(trimmed[range]), week > 0 else {
            throw TimetableImportError.invalidContents("周次必须为正整数。")
        }
        return week
    }

    static func entryKind(_ value: String) -> TimetableEntryKind? {
        switch normalized(value) {
        case "course", "课程", "正式课": .course
        case "support", "答疑", "学术答疑", "学术技能": .support
        case "officehour", "office", "办公时间": .officeHour
        case "event", "活动", "会议", "见面会": .event
        case "holiday", "假期", "节假日", "break", "休息": .holiday
        default: nil
        }
    }

    static func weekNumber(for date: Date, firstDate: Date) -> Int {
        let offset = calendar.dateComponents([.day], from: firstDate, to: date).day ?? 0
        return max(1, offset / 7 + 1)
    }

    static func emptyToNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

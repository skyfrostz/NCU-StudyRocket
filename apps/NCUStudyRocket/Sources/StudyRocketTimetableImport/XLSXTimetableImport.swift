import Foundation
import StudyRocketShared

enum XLSXTimetableImporter {
    struct ImportedDocument {
        let document: TimetableDocument
        let warnings: [String]
    }

    private struct WeekColumn {
        let sheet: XLSXWorksheet
        let column: Int
        let headerRow: Int
        let teachingWeek: Int
        let firstDate: Date
    }

    static func document(from fileURL: URL, defaults: TimetableImportDefaults) throws -> ImportedDocument {
        let workbook = try XLSXWorkbook(url: fileURL)
        if let normalizedRows = workbook.normalizedTimetableRows() {
            return ImportedDocument(
                document: try TimetableImportNormalization.document(fromRows: normalizedRows, defaults: defaults),
                warnings: []
            )
        }

        var records: [TimetableRecord] = []
        var firstDate: Date?
        var lastDate: Date?
        var termLabel = defaults.termLabel
        var matchedColumns = 0
        var skippedColumns = 0

        for sheet in workbook.sheets {
            let sheetTerm = Self.termLabel(in: sheet)
            if let sheetTerm { termLabel = sheetTerm }
            let baseYear = sheetTerm.flatMap { Self.termStartYear(in: $0) } ?? Self.termStartYear(in: termLabel)
            let columns = try weekColumns(in: sheet, defaults: defaults, baseYear: baseYear)
            for context in columns {
                guard defaults.maximumTeachingWeek.map({ context.teachingWeek <= $0 }) ?? true else {
                    skippedColumns += 1
                    continue
                }
                matchedColumns += 1
                let extracted = try Self.records(for: context)
                records.append(contentsOf: extracted)
                firstDate = min(firstDate ?? context.firstDate, context.firstDate)
                let weekEnd = TimetableImportNormalization.calendar.date(byAdding: .day, value: 6, to: context.firstDate) ?? context.firstDate
                lastDate = max(lastDate ?? weekEnd, weekEnd)
            }
        }

        guard matchedColumns > 0 else {
            throw TimetableImportError.invalidContents("未在 Excel 中找到“\(defaults.sourceClassLabel)”对应的周课表列。")
        }
        guard let firstDate, let lastDate, !records.isEmpty else {
            throw TimetableImportError.invalidContents("Excel 课表未包含可识别的课程、答疑、活动或假期。")
        }

        var warnings = ["已按源表“\(defaults.sourceClassLabel)”列导入；未在课程格或总安排中明确的教师保持为空。"]
        if skippedColumns > 0, let maximumTeachingWeek = defaults.maximumTeachingWeek {
            warnings.append("第\(maximumTeachingWeek + 1)周及以后未导入，以保留当前学期范围。")
        }
        return ImportedDocument(
            document: TimetableDocument(
                classLabel: defaults.classLabel,
                termLabel: termLabel,
                firstImportedDate: TimetableImportNormalization.dateString(firstDate),
                lastImportedDate: TimetableImportNormalization.dateString(lastDate),
                entries: records
            ),
            warnings: warnings
        )
    }

    private static func weekColumns(
        in sheet: XLSXWorksheet,
        defaults: TimetableImportDefaults,
        baseYear: Int?
    ) throws -> [WeekColumn] {
        let target = TimetableImportNormalization.normalized(defaults.sourceClassLabel)
        return sheet.cells.compactMap { coordinate, value -> WeekColumn? in
            guard TimetableImportNormalization.normalized(value) == target else { return nil }
            guard let week = nearestWeek(to: coordinate, in: sheet),
                  let dateText = nearestDateRange(to: coordinate, week: week, in: sheet),
                  let firstDate = parseFirstDate(from: dateText.value, baseYear: baseYear) else {
                return nil
            }
            return WeekColumn(
                sheet: sheet,
                column: coordinate.column,
                headerRow: coordinate.row,
                teachingWeek: week.value,
                firstDate: firstDate
            )
        }
        .sorted { lhs, rhs in
            if lhs.teachingWeek != rhs.teachingWeek { return lhs.teachingWeek < rhs.teachingWeek }
            return lhs.sheet.name < rhs.sheet.name
        }
    }

    private static func nearestWeek(to coordinate: XLSXCellCoordinate, in sheet: XLSXWorksheet) -> (value: Int, row: Int)? {
        let candidates = sheet.cells.compactMap { candidate, value -> (value: Int, row: Int, score: Int)? in
            guard candidate.row < coordinate.row,
                  candidate.row >= max(1, coordinate.row - 4),
                  candidate.column <= coordinate.column,
                  candidate.column >= max(1, coordinate.column - 2),
                  let week = parseWeek(value) else { return nil }
            let score = (coordinate.row - candidate.row) * 10 + (coordinate.column - candidate.column)
            return (week, candidate.row, score)
        }
        return candidates.min { $0.score < $1.score }.map { ($0.value, $0.row) }
    }

    private static func nearestDateRange(
        to coordinate: XLSXCellCoordinate,
        week: (value: Int, row: Int),
        in sheet: XLSXWorksheet
    ) -> (value: String, row: Int)? {
        let candidates = sheet.cells.compactMap { candidate, value -> (value: String, row: Int, score: Int)? in
            guard candidate.row >= week.row,
                  candidate.row < coordinate.row,
                  candidate.column <= coordinate.column,
                  candidate.column >= max(1, coordinate.column - 2),
                  containsMonthDay(value) else { return nil }
            let score = (coordinate.row - candidate.row) * 10 + (coordinate.column - candidate.column)
            return (value, candidate.row, score)
        }
        return candidates.min { $0.score < $1.score }.map { ($0.value, $0.row) }
    }

    private static func records(for context: WeekColumn) throws -> [TimetableRecord] {
        let sheet = context.sheet
        let structure = SheetStructure.detect(in: sheet, before: context.headerRow)
        var weekday: Int?
        var records: [TimetableRecord] = []

        guard context.headerRow < sheet.maximumRow else { return [] }
        for row in (context.headerRow + 1)...sheet.maximumRow {
            if let dayLabel = sheet.value(row: row, column: structure.weekdayColumn),
               let parsedWeekday = weekdayNumber(dayLabel) {
                weekday = parsedWeekday
            }
            guard let weekday,
                  let periodText = sheet.value(row: row, column: structure.periodColumn),
                  let startPeriod = positiveInteger(periodText),
                  let rawValue = sheet.value(row: row, column: context.column)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawValue.isEmpty else { continue }

            let date = TimetableImportNormalization.calendar.date(byAdding: .day, value: weekday - 1, to: context.firstDate) ?? context.firstDate
            if TimetableImportNormalization.normalized(rawValue) == "break" { continue }

            let endingRow = sheet.mergedEndingRow(for: XLSXCellCoordinate(row: row, column: context.column)) ?? row
            let endPeriod = positiveInteger(sheet.value(row: endingRow, column: structure.periodColumn) ?? "") ?? startPeriod
            let fallbackTimes = try times(
                start: sheet.value(row: row, column: structure.timeColumn),
                end: sheet.value(row: endingRow, column: structure.timeColumn)
            )
            let parsed = try parseCell(rawValue, fallbackTimes: fallbackTimes)
            guard let parsed else { continue }
            let periodLabel: String?
            if parsed.kind == .holiday {
                periodLabel = nil
            } else if startPeriod == endPeriod {
                periodLabel = "\(startPeriod)"
            } else {
                periodLabel = "\(startPeriod)-\(endPeriod)"
            }
            let entry = TimetableEntrySnapshot(
                id: "xlsx-\(sheet.name)-\(row)-\(context.column)",
                kind: parsed.kind,
                title: parsed.title,
                startTime: parsed.kind == .holiday ? nil : parsed.startTime,
                endTime: parsed.kind == .holiday ? nil : parsed.endTime,
                periodLabel: periodLabel,
                location: parsed.kind == .holiday ? nil : parsed.location,
                instructor: nil,
                note: nil
            )
            records.append(TimetableRecord(
                date: TimetableImportNormalization.dateString(date),
                teachingWeek: context.teachingWeek,
                entry: entry
            ))
        }
        return records
    }

    private static func parseCell(
        _ rawValue: String,
        fallbackTimes: (start: String?, end: String?)
    ) throws -> (kind: TimetableEntryKind, title: String, startTime: String?, endTime: String?, location: String?)? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = TimetableImportNormalization.normalized(trimmed)
        if normalized == "break" || normalized == "休息" { return nil }
        let sourceKind = classifiedKind(trimmed)
        let explicit = try explicitTime(in: trimmed)
        let content = (explicit?.title ?? trimmed)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let title = content.first, !title.isEmpty else { return nil }
        let presentation = StudyRocketTimetableCourseCatalog.presentation(kind: sourceKind, title: title)
        let location = content.dropFirst().joined(separator: " ").nilIfEmpty
        return (
            presentation.kind,
            presentation.title,
            explicit?.start ?? fallbackTimes.start,
            explicit?.end ?? fallbackTimes.end,
            location
        )
    }

    private static func classifiedKind(_ value: String) -> TimetableEntryKind {
        let normalized = TimetableImportNormalization.normalized(value)
        if normalized.contains("假期") || normalized.contains("festival") || normalized.contains("holiday") {
            return .holiday
        }
        if normalized.contains("officehour") {
            return .officeHour
        }
        if normalized.contains("academicandskills") || normalized.contains("答疑") || normalized.contains("学术技能") || normalized.contains("learningunderthepavillion") {
            return .support
        }
        if normalized.contains("见面会") || normalized.contains("调休") || normalized.contains("活动") || normalized.contains("meeting") {
            return .event
        }
        return .course
    }

    private static func times(start: String?, end: String?) throws -> (start: String?, end: String?) {
        let first = try timeRange(start)
        let last = try timeRange(end)
        return (first?.start, last?.end ?? first?.end)
    }

    private static func timeRange(_ value: String?) throws -> (start: String, end: String)? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = normalized.split(separator: "-", maxSplits: 1).map(String.init)
        guard pieces.count == 2,
              let start = try TimetableImportNormalization.normalizedTime(pieces[0]),
              let end = try TimetableImportNormalization.normalizedTime(pieces[1]) else {
            return nil
        }
        return (start, end)
    }

    private static func explicitTime(in value: String) throws -> (start: String, end: String, title: String)? {
        let expression = try NSRegularExpression(
            pattern: #"^\s*(\d{1,2}[:：]\d{2})\s*[-—–]\s*(\d{1,2}[:：]\d{2})\s*"#
        )
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range),
              let startRange = Range(match.range(at: 1), in: value),
              let endRange = Range(match.range(at: 2), in: value),
              let wholeRange = Range(match.range, in: value),
              let start = try TimetableImportNormalization.normalizedTime(String(value[startRange])),
              let end = try TimetableImportNormalization.normalizedTime(String(value[endRange])) else {
            return nil
        }
        return (start, end, String(value[wholeRange.upperBound...]))
    }

    private static func weekdayNumber(_ value: String) -> Int? {
        let normalized = TimetableImportNormalization.normalized(value)
        if normalized.contains("星期一") || normalized.contains("mon") { return 1 }
        if normalized.contains("星期二") || normalized.contains("tues") { return 2 }
        if normalized.contains("星期三") || normalized.contains("wed") { return 3 }
        if normalized.contains("星期四") || normalized.contains("thur") { return 4 }
        if normalized.contains("星期五") || normalized.contains("fri") { return 5 }
        if normalized.contains("星期六") || normalized.contains("sat") { return 6 }
        if normalized.contains("星期日") || normalized.contains("星期天") || normalized.contains("sun") { return 7 }
        return nil
    }

    private static func parseWeek(_ value: String) -> Int? {
        guard value.contains("周"),
              let range = value.range(of: #"\d+"#, options: .regularExpression),
              let week = Int(value[range]), week > 0 else { return nil }
        return week
    }

    private static func containsMonthDay(_ value: String) -> Bool {
        value.range(of: #"\d{1,2}月\d{1,2}日"#, options: .regularExpression) != nil
    }

    private static func parseFirstDate(from value: String, baseYear: Int?) -> Date? {
        guard let range = value.range(of: #"\d{1,2}月\d{1,2}日"#, options: .regularExpression) else { return nil }
        let parts = value[range]
            .replacingOccurrences(of: "月", with: "-")
            .replacingOccurrences(of: "日", with: "")
            .split(separator: "-")
            .compactMap { Int($0) }
        guard parts.count == 2, let baseYear else { return nil }
        let year = parts[0] <= 6 ? baseYear + 1 : baseYear
        return TimetableImportNormalization.calendar.date(from: DateComponents(year: year, month: parts[0], day: parts[1]))
    }

    private static func termLabel(in sheet: XLSXWorksheet) -> String? {
        let text = sheet.cells
            .filter { $0.key.row <= 5 }
            .map(\.value)
            .joined(separator: " ")
        guard let years = academicYears(in: text) else { return nil }
        return "\(years.0)-\(years.1) 秋季学期"
    }

    private static func termStartYear(in value: String) -> Int? {
        academicYears(in: value)?.0
    }

    private static func academicYears(in value: String) -> (Int, Int)? {
        guard let range = value.range(of: #"(\d{4})\s*-\s*(\d{4})"#, options: .regularExpression) else { return nil }
        let years = value[range].split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard years.count == 2 else { return nil }
        return (years[0], years[1])
    }

    private static func positiveInteger(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed).flatMap { $0 > 0 ? $0 : nil }
    }
}

private struct SheetStructure {
    let weekdayColumn: Int
    let periodColumn: Int
    let timeColumn: Int

    static func detect(in sheet: XLSXWorksheet, before row: Int) -> SheetStructure {
        var weekdayColumn = 1
        var periodColumn = 3
        var timeColumn = 4
        for (coordinate, value) in sheet.cells where coordinate.row <= row {
            switch TimetableImportNormalization.normalized(value) {
            case "星期", "weekday": weekdayColumn = coordinate.column
            case "节次", "period": periodColumn = coordinate.column
            case "时间", "time": timeColumn = coordinate.column
            default: break
            }
        }
        return SheetStructure(weekdayColumn: weekdayColumn, periodColumn: periodColumn, timeColumn: timeColumn)
    }
}

private struct XLSXWorkbook {
    let sheets: [XLSXWorksheet]

    init(url: URL) throws {
        let archive = try ReadOnlyXLSXArchive(url: url)
        guard let workbookData = try archive.data(named: "xl/workbook.xml"),
              let relationshipsData = try archive.data(named: "xl/_rels/workbook.xml.rels") else {
            throw TimetableImportError.unreadableWorkbook
        }
        let sharedStrings = try archive.data(named: "xl/sharedStrings.xml").map(parseSharedStrings) ?? []
        let references = try parseWorkbookReferences(workbookData)
        let relationships = try parseWorkbookRelationships(relationshipsData)
        var parsedSheets: [XLSXWorksheet] = []
        for reference in references {
            guard let target = relationships[reference.relationshipID],
                  let path = workbookPath(for: target),
                  let data = try archive.data(named: path) else { continue }
            parsedSheets.append(try parseWorksheet(data, name: reference.name, sharedStrings: sharedStrings))
        }
        guard !parsedSheets.isEmpty else { throw TimetableImportError.unreadableWorkbook }
        sheets = parsedSheets
    }

    func normalizedTimetableRows() -> [[String]]? {
        for sheet in sheets {
            for row in 1...min(sheet.maximumRow, 40) {
                let values = (1...min(sheet.maximumColumn, 32)).map { sheet.value(row: row, column: $0) ?? "" }
                guard TimetableImportNormalization.hasNormalizedTableHeader(values) else { continue }
                let following = row < sheet.maximumRow ? ((row + 1)...sheet.maximumRow).map { dataRow in
                    (1...min(sheet.maximumColumn, 32)).map { column in
                        sheet.value(row: dataRow, column: column) ?? ""
                    }
                } : []
                return [values] + following
            }
        }
        return nil
    }
}

private struct ReadOnlyXLSXArchive {
    private static let maximumUncompressedBytes = 28 * 1024 * 1024
    private static let maximumEntries = 128
    private static let maximumXMLBytes = 8 * 1024 * 1024
    private let url: URL
    private let entryNames: Set<String>

    init(url: URL) throws {
        self.url = url
        let namesData = try Self.run(arguments: ["-Z1", url.path], maximumOutputBytes: 64 * 1024)
        let names = Set((String(data: namesData, encoding: .utf8) ?? "").split(separator: "\n").map(String.init))
        guard names.contains("xl/workbook.xml"), names.count <= Self.maximumEntries,
              names.allSatisfy({ !$0.contains("..") && !$0.hasPrefix("/") }) else {
            throw TimetableImportError.unreadableWorkbook
        }
        let listingData = try Self.run(arguments: ["-l", url.path], maximumOutputBytes: 64 * 1024)
        let total = Self.uncompressedBytes(in: String(data: listingData, encoding: .utf8) ?? "")
        guard total > 0, total <= Self.maximumUncompressedBytes else {
            throw TimetableImportError.fileTooLarge
        }
        entryNames = names
    }

    func data(named entry: String) throws -> Data? {
        guard entryNames.contains(entry) else { return nil }
        let data = try Self.run(arguments: ["-p", url.path, entry], maximumOutputBytes: Self.maximumXMLBytes)
        return data
    }

    private static func isSafeEntry(_ value: String) -> Bool {
        value.hasPrefix("xl/") && !value.contains("..") && !value.hasPrefix("/")
    }

    private static func uncompressedBytes(in listing: String) -> Int {
        listing.components(separatedBy: .newlines).reduce(0) { total, line in
            let pieces = line.split(whereSeparator: \.isWhitespace)
            guard pieces.count >= 4, let size = Int(pieces[0]) else { return total }
            return total + size
        }
    }

    private static func run(arguments: [String], maximumOutputBytes: Int) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw TimetableImportError.unreadableWorkbook
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= maximumOutputBytes else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TimetableImportError.invalidContents(message?.isEmpty == false ? message! : "无法解压 Excel 文件。")
        }
        return data
    }
}

private struct XLSXCellCoordinate: Hashable {
    let row: Int
    let column: Int

    init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    init?(_ reference: String) {
        let letters = reference.prefix { $0.isLetter }
        let digits = reference.dropFirst(letters.count)
        guard !letters.isEmpty, let row = Int(digits), row > 0 else { return nil }
        var column = 0
        for letter in letters.uppercased().unicodeScalars {
            let asciiA: UInt32 = 65
            let asciiZ: UInt32 = 90
            guard letter.value >= asciiA, letter.value <= asciiZ else { return nil }
            column = column * 26 + Int(letter.value - asciiA + 1)
        }
        guard column > 0 else { return nil }
        self.init(row: row, column: column)
    }
}

private struct XLSXCellRange {
    let start: XLSXCellCoordinate
    let end: XLSXCellCoordinate

    init?(_ reference: String) {
        let pieces = reference.split(separator: ":", maxSplits: 1).map(String.init)
        guard let start = XLSXCellCoordinate(pieces[0]),
              let end = XLSXCellCoordinate(pieces.count == 2 ? pieces[1] : pieces[0]),
              start.row <= end.row, start.column <= end.column else { return nil }
        self.start = start
        self.end = end
    }
}

private struct XLSXWorksheet {
    let name: String
    let cells: [XLSXCellCoordinate: String]
    let merges: [XLSXCellRange]

    var maximumRow: Int { cells.keys.map(\.row).max() ?? 0 }
    var maximumColumn: Int { cells.keys.map(\.column).max() ?? 0 }

    func value(row: Int, column: Int) -> String? {
        cells[XLSXCellCoordinate(row: row, column: column)]
    }

    func mergedEndingRow(for coordinate: XLSXCellCoordinate) -> Int? {
        merges.first(where: { $0.start == coordinate && $0.start.column == $0.end.column })?.end.row
    }
}

private struct XLSXWorkbookReference {
    let name: String
    let relationshipID: String
}

private func parseSharedStrings(_ data: Data) throws -> [String] {
    let delegate = SharedStringsDelegate()
    try parseXML(data, delegate: delegate)
    return delegate.values
}

private func parseWorkbookReferences(_ data: Data) throws -> [XLSXWorkbookReference] {
    let delegate = WorkbookReferenceDelegate()
    try parseXML(data, delegate: delegate)
    return delegate.references
}

private func parseWorkbookRelationships(_ data: Data) throws -> [String: String] {
    let delegate = WorkbookRelationshipDelegate()
    try parseXML(data, delegate: delegate)
    return delegate.relationships
}

private func parseWorksheet(_ data: Data, name: String, sharedStrings: [String]) throws -> XLSXWorksheet {
    let delegate = WorksheetDelegate(sharedStrings: sharedStrings)
    try parseXML(data, delegate: delegate)
    return XLSXWorksheet(name: name, cells: delegate.cells, merges: delegate.merges)
}

private func parseXML(_ data: Data, delegate: XMLParserDelegate) throws {
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else {
        throw TimetableImportError.invalidContents(parser.parserError?.localizedDescription ?? "Excel XML 无法解析。")
    }
}

private func workbookPath(for target: String) -> String? {
    let normalized = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/\(target)"
    guard normalized.hasPrefix("xl/"), !normalized.contains("..") else { return nil }
    return normalized
}

private final class SharedStringsDelegate: NSObject, XMLParserDelegate {
    var values: [String] = []
    private var insideItem = false
    private var insideText = false
    private var current = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "si":
            insideItem = true
            current = ""
        case "t" where insideItem:
            insideText = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideText { current.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "t": insideText = false
        case "si":
            values.append(current)
            insideItem = false
        default:
            break
        }
    }
}

private final class WorkbookReferenceDelegate: NSObject, XMLParserDelegate {
    var references: [XLSXWorkbookReference] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "sheet",
              let name = attributeDict["name"],
              let relationshipID = attributeDict["r:id"] ?? attributeDict["id"] else { return }
        references.append(XLSXWorkbookReference(name: name, relationshipID: relationshipID))
    }
}

private final class WorkbookRelationshipDelegate: NSObject, XMLParserDelegate {
    var relationships: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "Relationship",
              let id = attributeDict["Id"],
              let target = attributeDict["Target"] else { return }
        relationships[id] = target
    }
}

private final class WorksheetDelegate: NSObject, XMLParserDelegate {
    var cells: [XLSXCellCoordinate: String] = [:]
    var merges: [XLSXCellRange] = []
    private let sharedStrings: [String]
    private var currentCoordinate: XLSXCellCoordinate?
    private var currentType = ""
    private var valueBuffer = ""
    private var inlineBuffer = ""
    private var captureValue = false
    private var captureInlineText = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "c":
            currentCoordinate = attributeDict["r"].flatMap(XLSXCellCoordinate.init)
            currentType = attributeDict["t"] ?? ""
            valueBuffer = ""
            inlineBuffer = ""
        case "v":
            captureValue = currentCoordinate != nil
        case "t" where currentCoordinate != nil && currentType == "inlineStr":
            captureInlineText = true
        case "mergeCell":
            if let reference = attributeDict["ref"], let range = XLSXCellRange(reference) { merges.append(range) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if captureValue { valueBuffer.append(string) }
        if captureInlineText { inlineBuffer.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "v": captureValue = false
        case "t": captureInlineText = false
        case "c":
            defer {
                currentCoordinate = nil
                currentType = ""
                valueBuffer = ""
                inlineBuffer = ""
            }
            guard let coordinate = currentCoordinate else { return }
            let value: String?
            switch currentType {
            case "s":
                value = Int(valueBuffer).flatMap { sharedStrings.indices.contains($0) ? sharedStrings[$0] : nil }
            case "inlineStr":
                value = inlineBuffer
            default:
                value = valueBuffer
            }
            if let value, !value.isEmpty { cells[coordinate] = value }
        default:
            break
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

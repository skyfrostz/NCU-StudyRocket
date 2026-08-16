import Foundation
import CryptoKit
import StudyRocketShared

final class HostSnapshotBuilder {
    private let root: URL
    private let calendar: Calendar

    init(root: URL) {
        self.root = root
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        self.calendar = calendar
    }

    func build(now: Date = .now) -> SnapshotResponse {
        let planText = read("工作台/下周计划.md")
        let plan = parsePlan(planText, now: now)
        let daily = parseDaily(now: now)
        let visibleDeliveries = plan.deliveries.filter { delivery in
            guard let label = delivery.dateLabel, let date = parseDate(label, relativeTo: now) else { return true }
            return !calendar.isDate(date, inSameDayAs: now)
        }
        let home = HomeSnapshot(
            dateLabel: dateLabel(now),
            periods: plan.days.first(where: { calendar.isDate(parseDate($0.dateLabel, relativeTo: now) ?? .distantPast, inSameDayAs: now) })?.slots ?? Self.emptyPeriods,
            firstOpenTask: plan.days.first(where: { calendar.isDate(parseDate($0.dateLabel, relativeTo: now) ?? .distantPast, inSameDayAs: now) })?.slots.first(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text,
            visibleDeliveries: visibleDeliveries,
            completedDeliveries: visibleDeliveries.filter { $0.isCompleted }.count,
            totalDeliveries: visibleDeliveries.count
        )
        let month = DateFormatter.monthFile.string(from: now)
        let revision = revision(for: ["工作台/下周计划.md", "工作台/每日记录/\(month).md", "工作台/进度日志.md", "工作台/航线/课程.md", "工作台/航线/科研.md", "工作台/航线/保研.md", "工作台/航线/生活.md", "智库/学校文件/来源索引.md"])
        return SnapshotResponse(revision: revision, home: home, week: plan, daily: daily, summaries: summaries())
    }

    private static let emptyPeriods = [
        PeriodSnapshot(id: "morning", title: "上午", text: ""),
        PeriodSnapshot(id: "noon", title: "中午", text: ""),
        PeriodSnapshot(id: "evening", title: "晚上", text: "")
    ]

    private func parsePlan(_ source: String, now: Date) -> WeeklyPlanSnapshot {
        let window = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: now))! }
        var dayValues: [Date: [String]] = [:]
        var deliveries: [DeliverySnapshot] = []
        var pendingDelivery: (text: String, completed: Bool)?
        var inWeekly = false
        var inHiddenWeeklySection = false
        var inDeliveries = false
        var tableRows: [[String]] = []
        for line in source.components(separatedBy: .newlines) {
            if line.contains("studyrocket:weekly:start") { inWeekly = true; continue }
            if line.contains("studyrocket:weekly:end") { inWeekly = false; continue }
            if line.contains("studyrocket:weekly:history:start") || line.contains("studyrocket:weekly:future:start") {
                inHiddenWeeklySection = true
                continue
            }
            if line.contains("studyrocket:weekly:history:end") || line.contains("studyrocket:weekly:future:end") {
                inHiddenWeeklySection = false
                continue
            }
            if line.hasPrefix("## 交付物") { inDeliveries = true; continue }
            if inDeliveries, line.hasPrefix("## ") { inDeliveries = false }
            if inWeekly, !inHiddenWeeklySection, line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                var rawCells = line.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
                if rawCells.first?.isEmpty == true { rawCells.removeFirst() }
                if rawCells.last?.isEmpty == true { rawCells.removeLast() }
                let cells = rawCells.map(unescape)
                guard !cells.isEmpty else { continue }
                let isDivider = cells[0].allSatisfy { character in character == "-" || character == ":" || character == " " }
                if cells.count >= 2, !isDivider { tableRows.append(cells) }
            }
            if inDeliveries {
                if let delivery = parseDelivery(line, reference: now) {
                    if let pendingDelivery { deliveries.append(makeDelivery(pendingDelivery.text, completed: pendingDelivery.completed, reference: now)) }
                    pendingDelivery = (delivery.text, delivery.isCompleted)
                } else if line.hasPrefix("  "), pendingDelivery != nil {
                    pendingDelivery!.text += "\n" + line.dropFirst(2)
                }
            }
        }

        if let pendingDelivery { deliveries.append(makeDelivery(pendingDelivery.text, completed: pendingDelivery.completed, reference: now)) }

        var visibleRows: [(label: String, slots: [String], unassigned: String, completed: Bool)] = []
        if let header = tableRows.first, header.first?.contains("日期") == true {
            let hasExplicitSlots = header.count >= 4 && header.dropFirst().contains(where: { $0.contains("上午") })
            // Legacy dated rows have two columns; structured rows have four or
            // more.  Accept both so the current repository does not silently
            // turn every day into an empty schedule.
            for row in tableRows.dropFirst() where row.count >= 2 {
                guard let date = parseDate(row[0], relativeTo: now) else { continue }
                let periods: [String]
                if hasExplicitSlots && row.count >= 4 {
                    periods = (1...3).map { row[safe: $0] ?? "" }
                } else {
                    let values = Array(row[1..<row.count]).map { String($0) }
                    periods = splitIntoPeriods(values.joined(separator: "；"))
                }
                visibleRows.append((row[0], periods, row[safe: 4] ?? "", row.indices.contains(5) && parseBoolean(row[5])))
                dayValues[calendar.startOfDay(for: date)] = periods
            }
        } else if let header = tableRows.first, header.first?.contains("时段") == true {
            var headers = Array(header[1..<header.count]).map { String($0) }
            if headers.count > 7 { headers = Array(headers.prefix(7)) }
            for row in tableRows.dropFirst() where row.count >= 2 {
                let period = normalizedPeriod(row[0])
                for (index, value) in row.dropFirst().enumerated() where index < headers.count {
                    guard let date = parseDate(headers[index], relativeTo: now) else { continue }
                    let key = calendar.startOfDay(for: date)
                    var periods = dayValues[key] ?? ["", "", ""]
                    periods[period] = value
                    dayValues[key] = periods
                }
            }
            for date in window {
                let values = dayValues[calendar.startOfDay(for: date)] ?? ["", "", ""]
                visibleRows.append((dateLabel(date), values, "", false))
            }
        }

        let days = window.map { date -> DaySnapshot in
            let values = dayValues[calendar.startOfDay(for: date)] ?? ["", "", ""]
            return DaySnapshot(id: isoDate(date), dateLabel: dateLabel(date), slots: [
                PeriodSnapshot(id: "morning", title: "上午", text: values[safe: 0] ?? ""),
                PeriodSnapshot(id: "noon", title: "中午", text: values[safe: 1] ?? ""),
                PeriodSnapshot(id: "evening", title: "晚上", text: values[safe: 2] ?? "")
            ])
        }
        let hiddenRows = parseHiddenRows(source)
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        var historicalRows: [ScheduledRowSnapshot] = []
        var futureRows: [ScheduledRowSnapshot] = []
        for row in visibleRows.map(makeScheduledRow) + hiddenRows {
            guard let date = parseDate(row.dateLabel, relativeTo: now) else {
                futureRows.append(row)
                continue
            }
            if date < start { historicalRows.append(row) }
            else if date >= end { futureRows.append(row) }
        }
        return WeeklyPlanSnapshot(days: days, bufferRules: parseBuffers(source), deliveries: deliveries, historicalRows: historicalRows, futureRows: futureRows)
    }

    private func makeScheduledRow(_ row: (label: String, slots: [String], unassigned: String, completed: Bool)) -> ScheduledRowSnapshot {
        ScheduledRowSnapshot(
            id: stableID("schedule", row.label, row.slots.joined(separator: "\u{1f}"), row.unassigned),
            dateLabel: row.label,
            slots: [
                PeriodSnapshot(id: "morning", title: "上午", text: row.slots[safe: 0] ?? ""),
                PeriodSnapshot(id: "noon", title: "中午", text: row.slots[safe: 1] ?? ""),
                PeriodSnapshot(id: "evening", title: "晚上", text: row.slots[safe: 2] ?? "")
            ],
            unassigned: row.unassigned,
            isCompleted: row.completed
        )
    }

    private func parseHiddenRows(_ source: String) -> [ScheduledRowSnapshot] {
        let markers = [
            ("studyrocket:weekly:history:start", "studyrocket:weekly:history:end"),
            ("studyrocket:weekly:future:start", "studyrocket:weekly:future:end")
        ]
        var result: [ScheduledRowSnapshot] = []
        for (startMarker, endMarker) in markers {
            guard let start = source.range(of: startMarker),
                  let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else { continue }
            for line in String(source[start.upperBound..<end.lowerBound]).components(separatedBy: .newlines) {
                var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
                if cells.first?.isEmpty == true { cells.removeFirst() }
                if cells.last?.isEmpty == true { cells.removeLast() }
                guard cells.count >= 4, cells.first?.contains("日期") != true, cells.first?.contains("---") != true else { continue }
                let values = cells.map(unescape)
                result.append(makeScheduledRow((
                    values[0],
                    (1...3).map { values[safe: $0] ?? "" },
                    values[safe: 4] ?? "",
                    values.indices.contains(5) && parseBoolean(values[5])
                )))
            }
        }
        return result
    }

    private func parseDelivery(_ line: String, reference: Date) -> DeliverySnapshot? {
        let pattern = #"^\s*-\s*\[([ xX])\]\s*(.+)$"#
        guard let match = line.range(of: pattern, options: .regularExpression) else { return nil }
        let value = String(line[match])
        let completed = value.contains("x") || value.contains("X")
        let text = value.replacingOccurrences(of: #"^\s*-\s*\[[ xX]\]\s*"#, with: "", options: .regularExpression)
        let date = leadingDate(in: text, reference: reference)
        return DeliverySnapshot(id: stableID("delivery", date.map(dateLabel) ?? "", text), text: text, isCompleted: completed, dateLabel: date.map(dateLabel))
    }

    private func makeDelivery(_ text: String, completed: Bool, reference: Date) -> DeliverySnapshot {
        let date = leadingDate(in: text, reference: reference)
        return DeliverySnapshot(id: stableID("delivery", date.map(dateLabel) ?? "", text), text: text, isCompleted: completed, dateLabel: date.map(dateLabel))
    }

    private func parseBuffers(_ source: String) -> [BufferRuleSnapshot] {
        guard let range = source.range(of: "## 缓冲") else { return [] }
        let tail = source[range.upperBound...]
        var category = "daily"
        var result: [BufferRuleSnapshot] = []
        var current: (category: String, text: String)?
        for rawLine in tail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if rawLine.hasPrefix("## ") { break }
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed == "### 日常缓冲" { category = "daily"; continue }
            if trimmed == "### 撞车降级" { category = "collision"; continue }
            if trimmed == "### 最低底线" { category = "minimum"; continue }
            if trimmed.hasPrefix("<!-- studyrocket:buffer:") { continue }
            if let match = trimmed.range(of: #"^-\s+(.*)$"#, options: .regularExpression) {
                if let current { result.append(BufferRuleSnapshot(id: stableID("buffer", current.category, current.text), category: current.category, text: current.text)) }
                let text = String(trimmed[match]).replacingOccurrences(of: #"^-\s+"#, with: "", options: .regularExpression)
                current = (category, text)
            } else if rawLine.hasPrefix("  "), current != nil {
                current!.text += "\n" + rawLine.dropFirst(2)
            }
        }
        if let current { result.append(BufferRuleSnapshot(id: stableID("buffer", current.category, current.text), category: current.category, text: current.text)) }
        return result
    }

    private func parseDaily(now: Date) -> DailySnapshot {
        let month = DateFormatter.monthFile.string(from: now)
        let source = read("工作台/每日记录/\(month).md")
        guard let heading = source.range(of: "### \(isoDate(now))") else { return DailySnapshot(date: isoDate(now)) }
        let remainder = source[heading.upperBound...]
        let section = remainder.split(separator: "###", maxSplits: 1).first.map(String.init) ?? String(remainder)
        func field(_ names: [String]) -> String {
            for name in names {
                if let line = section.components(separatedBy: .newlines).first(where: { $0.contains(name) }) {
                    return line.replacingOccurrences(of: #"^.*?[:：]\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                }
            }
            return ""
        }
        return DailySnapshot(date: isoDate(now), deliverables: field(["完成交付物"]), studyTime: field(["净学习时长"]), sleep: field(["睡眠"]), exercise: field(["运动"]), firstTask: field(["明日第一任务"]))
    }

    /// The mobile client only sees logical document keys.  Keeping the path
    /// map here prevents a network caller from choosing an arbitrary file.
    static let documentMap: [String: (title: String, path: String)] = [
        "course": ("课程", "工作台/航线/课程.md"),
        "research": ("科研", "工作台/航线/科研.md"),
        "recommendation": ("保研", "工作台/航线/保研.md"),
        "life": ("生活", "工作台/航线/生活.md"),
        "library": ("资料库", "智库/学校文件/来源索引.md")
    ]

    func document(documentKey: String) -> DocumentDetail? {
        guard let entry = Self.documentMap[documentKey] else { return nil }
        let content = read(entry.path).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        let revision = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        return DocumentDetail(documentKey: documentKey, title: entry.title, markdown: content, revision: revision)
    }

    private func summaries() -> [SummaryCard] {
        Self.documentMap.compactMap { key, entry in
            guard let document = document(documentKey: key) else { return nil }
            let detail = document.markdown
                .components(separatedBy: .newlines)
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? entry.title
            return SummaryCard(id: key, title: entry.title, detail: detail, updatedAt: document.fetchedAt, documentKey: key)
        }
        .sorted { lhs, rhs in
            let order = ["course", "research", "recommendation", "life", "library"]
            return (order.firstIndex(of: lhs.documentKey ?? "") ?? .max) < (order.firstIndex(of: rhs.documentKey ?? "") ?? .max)
        }
    }

    private func splitIntoPeriods(_ text: String) -> [String] {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: "；;\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return ["", "", ""] }
        let firstCount = Int(ceil(Double(parts.count) / 3.0))
        let secondCount = Int(ceil(Double(max(0, parts.count - firstCount)) / 2.0))
        let first = parts.prefix(firstCount).joined(separator: "；")
        let second = parts.dropFirst(firstCount).prefix(secondCount).joined(separator: "；")
        let third = parts.dropFirst(firstCount + secondCount).joined(separator: "；")
        return [first, second, third]
    }

    private func normalizedPeriod(_ value: String) -> Int {
        value.contains("晚上") ? 2 : (value.contains("中午") || value.contains("下午") ? 1 : 0)
    }

    private func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\|", with: "|").replacingOccurrences(of: "<br>", with: "\n")
    }

    private func parseBoolean(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "[x]" || normalized == "x" || normalized == "true" || normalized == "是"
    }

    private func leadingDate(in text: String, reference: Date) -> Date? {
        guard let match = text.range(of: #"(?:\d{4}\s*[-年]\s*)?\d{1,2}\s*月\s*\d{1,2}\s*日"#, options: .regularExpression) else { return nil }
        return parseDate(String(text[match]), relativeTo: reference)
    }

    private func parseDate(_ text: String, relativeTo reference: Date) -> Date? {
        guard let match = text.range(of: #"(?:(\d{4})\s*[-年]\s*)?(\d{1,2})\s*月\s*(\d{1,2})\s*日?"#, options: .regularExpression) else { return nil }
        let value = String(text[match])
        let numbers = value.split { !$0.isNumber }.compactMap { Int($0) }
        guard numbers.count >= 2 else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: reference)
        if numbers.count == 3 { components.year = numbers[0]; components.month = numbers[1]; components.day = numbers[2] }
        else { components.month = numbers[0]; components.day = numbers[1] }
        guard let date = calendar.date(from: components) else { return nil }
        if numbers.count == 2, date < calendar.date(byAdding: .month, value: -6, to: reference)! { return calendar.date(byAdding: .year, value: 1, to: date) }
        return date
    }

    private func read(_ relative: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)) ?? ""
    }

    private func revision(for paths: [String]) -> String {
        let joined = paths.map { read($0) }.joined(separator: "\u{0}" )
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日 · EEE"
        return formatter.string(from: date)
    }

    private func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func stableID(_ parts: String...) -> String {
        let input = parts.joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(24).description
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

private extension DateFormatter {
    static let monthFile: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()
}

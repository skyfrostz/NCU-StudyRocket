import Foundation
import CryptoKit
import StudyRocketShared

struct HostWriteError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

final class HostWriteService {
    private let root: URL
    private let snapshotBuilder: HostSnapshotBuilder
    private let fileManager = FileManager.default
    private var calendar: Calendar
    private let replayLock = NSLock()
    private var replayed: [String: SnapshotResponse] = [:]

    init(root: URL) {
        self.root = root.standardizedFileURL
        snapshotBuilder = HostSnapshotBuilder(root: root.standardizedFileURL)
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        self.calendar = calendar
    }

    func applyWeek(_ request: PlanWriteRequest) throws -> SnapshotResponse {
        if let cached = replayedValue(for: request.metadata.idempotencyKey) { return cached }
        try ensureAPIVersion(request.metadata.apiVersion)
        try ensureRevision(request.metadata.baseRevision)
        let relative = "工作台/下周计划.md"
        let source = try read(relative)
        // The mobile client edits the schedule, deliveries and fallback rules in
        // one screen.  Keep those edits in the same atomic save so a successful
        // response can never silently drop two thirds of the submitted plan.
        let scheduled = updateWeekly(source, plan: request.plan)
        let deliveries = updateDeliveries(scheduled, deliveries: request.plan.deliveries)
        let updated = updateBuffers(deliveries, rules: request.plan.bufferRules)
        try save(updated, relative: relative, expectedHash: hash(source))
        let value = snapshotBuilder.build()
        storeReplay(value, for: request.metadata.idempotencyKey)
        return value
    }

    func toggleDelivery(_ request: DeliveryToggleRequest) throws -> SnapshotResponse {
        if let cached = replayedValue(for: request.metadata.idempotencyKey) { return cached }
        try ensureAPIVersion(request.metadata.apiVersion)
        try ensureRevision(request.metadata.baseRevision)
        let relative = "工作台/下周计划.md"
        let source = try read(relative)
        let marker = request.isCompleted ? "- [x]" : "- [ ]"
        let other = request.isCompleted ? "- [ ]" : "- [x]"
        let lines = source.components(separatedBy: .newlines)
        var found = false
        let updatedLines = lines.map { line -> String in
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix(other) else { return line }
            let currentText = line.replacingOccurrences(of: #"^\s*-\s*\[[ xX]\]\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            guard currentText == request.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return line }
            found = true
            let prefix = line.prefix { $0 == " " || $0 == "\t" }
            return String(prefix) + marker + " " + currentText
        }
        guard found else { throw HostWriteError(code: "delivery_not_found", message: "找不到对应交付物，文件可能已被外部修改。") }
        try save(updatedLines.joined(separator: "\n"), relative: relative, expectedHash: hash(source))
        let value = snapshotBuilder.build()
        storeReplay(value, for: request.metadata.idempotencyKey)
        return value
    }

    func applyDaily(_ request: DailyWriteRequest) throws -> SnapshotResponse {
        if let cached = replayedValue(for: request.metadata.idempotencyKey) { return cached }
        try ensureAPIVersion(request.metadata.apiVersion)
        try ensureRevision(request.metadata.baseRevision)
        let relative = "工作台/每日记录/\(request.entry.date.prefix(7)).md"
        let fileURL = root.appendingPathComponent(relative).standardizedFileURL
        let exists = fileManager.fileExists(atPath: fileURL.path)
        let source = (try? read(relative)) ?? "# 每日行为账 · \(request.entry.date.prefix(7))\n\n"
        let updated = updateDaily(source, entry: request.entry)
        if exists {
            try save(updated, relative: relative, expectedHash: hash(source))
        } else {
            let resolvedRoot = root.resolvingSymlinksInPath()
            let resolvedURL = fileURL.resolvingSymlinksInPath()
            guard resolvedURL.path.hasPrefix(resolvedRoot.path + "/"), !isSymlink(fileURL) else { throw HostWriteError(code: "path_denied", message: "目标文件不在仓库允许范围内。") }
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(updated.utf8).write(to: fileURL, options: .atomic)
        }
        let value = snapshotBuilder.build()
        storeReplay(value, for: request.metadata.idempotencyKey)
        return value
    }

    private func ensureRevision(_ expected: String) throws {
        let current = snapshotBuilder.build().revision
        guard current == expected else {
            throw HostWriteError(code: "conflict", message: "仓库内容已变化，请重新加载后再保存。")
        }
    }

    private func ensureAPIVersion(_ version: Int) throws {
        guard version == StudyRocketAPI.version else {
            throw HostWriteError(code: "unsupported_version", message: "客户端版本不兼容，请更新 StudyRocket。")
        }
    }

    private func updateWeekly(_ source: String, plan: WeeklyPlanSnapshot) -> String {
        let startToken = "<!-- studyrocket:weekly:start -->"
        let endToken = "<!-- studyrocket:weekly:end -->"
        guard let start = source.range(of: startToken), let end = source.range(of: endToken, range: start.upperBound..<source.endIndex) else { return source }
        let body = String(source[start.upperBound..<end.lowerBound])
        let lines = body.components(separatedBy: .newlines)
        let header = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }) ?? ""
        let headerCells = splitTable(header)
        let isStructured = headerCells.first?.contains("日期") == true && headerCells.count >= 4
        var seen = Set<String>()
        var movedToHistory: [[String]] = []
        var insideHistory = false
        let today = calendar.startOfDay(for: .now)
        let updatedLines = lines.compactMap { line -> String? in
            if line.contains("studyrocket:weekly:history:start") { insideHistory = true; return line }
            if line.contains("studyrocket:weekly:history:end") { insideHistory = false; return line }
            if insideHistory { return line }
            let cells = splitTable(line)
            guard cells.count >= 2, let existingDate = cells.first, let existingDateValue = parseDate(existingDate, relativeTo: .now) else { return line }
            if existingDateValue < today {
                movedToHistory.append(historyCells(from: cells, structured: isStructured))
                return nil
            }
            guard let day = plan.days.first(where: { sameDate($0.dateLabel, existingDate) }) else { return line }
            seen.insert(day.id)
            if isStructured {
                var values = cells
                while values.count < 6 { values.append("") }
                values[1] = encodeCell(day.slots[safe: 0]?.text ?? "")
                values[2] = encodeCell(day.slots[safe: 1]?.text ?? "")
                values[3] = encodeCell(day.slots[safe: 2]?.text ?? "")
                values[4] = encodeCell(day.unassigned)
                return renderTable(values)
            }
            let text = day.slots.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "；")
            return renderTable([existingDate, encodeCell(text)])
        }
        let missing = plan.days.filter { !seen.contains($0.id) }.filter { day in day.slots.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }.map { day in
            let label = normalizeDate(day.dateLabel)
            if isStructured {
                return renderTable([label, encodeCell(day.slots[safe: 0]?.text ?? ""), encodeCell(day.slots[safe: 1]?.text ?? ""), encodeCell(day.slots[safe: 2]?.text ?? "")])
            }
            let text = day.slots.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "；")
            return renderTable([label, encodeCell(text)])
        }
        var all = updatedLines
        if !missing.isEmpty {
            let insertion = all.lastIndex { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("|") } ?? all.endIndex
            all.insert(contentsOf: missing, at: insertion + 1)
        }
        if !movedToHistory.isEmpty {
            let existingHistory = hiddenHistoryRows(in: all)
            let merged = uniqueHistoryRows(existingHistory + movedToHistory)
            if let startIndex = all.firstIndex(where: { $0.contains("studyrocket:weekly:history:start") }),
               let endIndex = all[(startIndex + 1)..<all.count].firstIndex(where: { $0.contains("studyrocket:weekly:history:end") }) {
                let block = ["<!-- studyrocket:weekly:history:start -->", "", "| 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |", "|------|------|------|------|----------|------|"]
                    + merged.map(renderTable)
                    + ["<!-- studyrocket:weekly:history:end -->"]
                all.replaceSubrange(startIndex...endIndex, with: block)
            } else {
                all += ["", "<!-- studyrocket:weekly:history:start -->", "", "| 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |", "|------|------|------|------|----------|------|"]
                all += merged.map(renderTable)
                all += ["<!-- studyrocket:weekly:history:end -->", ""]
            }
        }
        var result = source
        result.replaceSubrange(start.upperBound..<end.lowerBound, with: "\n" + all.joined(separator: "\n") + "\n")
        return result
    }

    private func historyCells(from cells: [String], structured: Bool) -> [String] {
        if structured {
            var values = Array(cells.prefix(6))
            while values.count < 6 { values.append("") }
            return values
        }
        let parsed = cells.count > 1 ? parseCompletion(cells[1]) : (text: "", completed: false)
        return [cells.first ?? "", encodeCell(parsed.text), "", "", "", parsed.completed ? "[x]" : "[ ]"]
    }

    private func hiddenHistoryRows(in lines: [String]) -> [[String]] {
        guard let start = lines.firstIndex(where: { $0.contains("studyrocket:weekly:history:start") }),
              let end = lines[(start + 1)..<lines.count].firstIndex(where: { $0.contains("studyrocket:weekly:history:end") }) else { return [] }
        return lines[(start + 1)..<end].compactMap { line in
            let cells = splitTable(line)
            guard cells.count >= 4, cells.first?.contains("日期") != true, cells.first?.contains("---") != true else { return nil }
            var values = Array(cells.prefix(6))
            while values.count < 6 { values.append("") }
            return values
        }
    }

    private func uniqueHistoryRows(_ rows: [[String]]) -> [[String]] {
        var seen = Set<String>()
        return rows.filter { row in
            let key = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\u{1f}")
            return seen.insert(key).inserted
        }
    }

    private func sameDate(_ left: String, _ right: String) -> Bool {
        guard let lhs = parseDate(left, relativeTo: .now), let rhs = parseDate(right, relativeTo: .now) else {
            return normalizeDate(left) == normalizeDate(right)
        }
        return calendar.isDate(lhs, inSameDayAs: rhs)
    }

    private func parseDate(_ text: String, relativeTo reference: Date) -> Date? {
        if let match = text.range(of: #"\b\d{4}-\d{1,2}-\d{1,2}\b"#, options: .regularExpression) {
            let values = text[match].split(separator: "-").compactMap { Int($0) }
            if values.count == 3 { return calendar.date(from: DateComponents(year: values[0], month: values[1], day: values[2])) }
        }
        guard let match = text.range(of: #"(?:(\d{4})\s*年\s*)?(\d{1,2})\s*月\s*(\d{1,2})\s*日?"#, options: .regularExpression) else { return nil }
        let values = String(text[match]).split { !$0.isNumber }.compactMap { Int($0) }
        guard values.count >= 2 else { return nil }
        if values.count == 3 { return calendar.date(from: DateComponents(year: values[0], month: values[1], day: values[2])) }
        let referenceYear = calendar.component(.year, from: reference)
        return (referenceYear - 1...referenceYear + 1).compactMap { year in
            calendar.date(from: DateComponents(year: year, month: values[0], day: values[1]))
        }.min { abs($0.timeIntervalSince(reference)) < abs($1.timeIntervalSince(reference)) }
    }

    private func parseCompletion(_ value: String) -> (text: String, completed: Bool) {
        let completed = value.contains("[x]") || value.contains("[X]")
        let text = value.replacingOccurrences(of: #"^\s*\[[ xX]\]\s*"#, with: "", options: .regularExpression)
        return (text, completed)
    }

    private func updateDaily(_ source: String, entry: DailySnapshot) -> String {
        let heading = "### \(entry.date)"
        let section = "\n\(heading)\n- [ ] 今日完成的具体交付物：\(entry.deliverables)\n- 净学习时长：\(entry.studyTime)\n- 入睡/起床：\(entry.sleep)\n- 运动：\(entry.exercise)\n- 明日第一任务：\(entry.firstTask)\n"
        if let start = source.range(of: heading) {
            let end = source[start.upperBound...].range(of: "\n### ")?.lowerBound ?? source.endIndex
            var result = source
            result.replaceSubrange(start.lowerBound..<end, with: section)
            return result
        }
        return source.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + section
    }

    private func updateDeliveries(_ source: String, deliveries: [DeliverySnapshot]) -> String {
        let lines = source.components(separatedBy: .newlines)
        guard let heading = lines.firstIndex(where: { $0.hasPrefix("## 交付物") }) else { return source }
        let content = deliveryLines(for: deliveries)
        return replacingManagedSection(
            in: lines,
            headingIndex: heading,
            markers: ("studyrocket:deliveries:start", "studyrocket:deliveries:end"),
            content: content
        ).joined(separator: "\n")
    }

    private func updateBuffers(_ source: String, rules: [BufferRuleSnapshot]) -> String {
        let lines = source.components(separatedBy: .newlines)
        guard let heading = lines.firstIndex(where: { $0.hasPrefix("## 缓冲") }) else { return source }
        return replacingManagedSection(
            in: lines,
            headingIndex: heading,
            markers: ("studyrocket:buffer:start", "studyrocket:buffer:end"),
            content: bufferLines(for: rules)
        ).joined(separator: "\n")
    }

    private func replacingManagedSection(
        in source: [String],
        headingIndex: Int,
        markers: (start: String, end: String),
        content: [String]
    ) -> [String] {
        var lines = source
        let sectionStart = headingIndex + 1
        var sectionEnd = sectionStart
        while sectionEnd < lines.count, !lines[sectionEnd].hasPrefix("## ") { sectionEnd += 1 }

        if let markerStart = lines[sectionStart..<sectionEnd].firstIndex(where: { $0.contains(markers.start) }),
           let markerEnd = lines[(markerStart + 1)..<sectionEnd].firstIndex(where: { $0.contains(markers.end) }) {
            lines.replaceSubrange((markerStart + 1)..<markerEnd, with: content)
        } else {
            let managed = ["<!-- \(markers.start) -->"] + content + ["<!-- \(markers.end) -->"]
            lines.replaceSubrange(sectionStart..<sectionEnd, with: managed)
        }
        return lines
    }

    private func deliveryLines(for deliveries: [DeliverySnapshot]) -> [String] {
        deliveries.flatMap { delivery in
            let pieces = delivery.text.components(separatedBy: .newlines)
            guard let first = pieces.first else { return ["- [\(delivery.isCompleted ? "x" : " ")] "] }
            return ["- [\(delivery.isCompleted ? "x" : " ")] \(first)"]
                + pieces.dropFirst().map { "  \($0)" }
        }
    }

    private func bufferLines(for rules: [BufferRuleSnapshot]) -> [String] {
        let categories: [(id: String, title: String)] = [
            ("daily", "日常缓冲"),
            ("collision", "撞车降级"),
            ("minimum", "最低底线")
        ]
        var lines: [String] = []
        for (index, category) in categories.enumerated() {
            if index > 0 { lines.append("") }
            lines.append("### \(category.title)")
            for rule in rules where rule.category == category.id {
                let pieces = rule.text.components(separatedBy: .newlines)
                guard let first = pieces.first else { continue }
                lines.append("- \(first)")
                lines.append(contentsOf: pieces.dropFirst().map { "  \($0)" })
            }
        }
        return lines
    }

    private func splitTable(_ line: String) -> [String] {
        guard line.trimmingCharacters(in: .whitespaces).hasPrefix("|") else { return [] }
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    private func renderTable(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
    private func encodeCell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>") }
    private func normalizeDate(_ text: String) -> String {
        let prefix = text.components(separatedBy: "·").first ?? text
        return prefix.replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func read(_ relative: String) throws -> String {
        let url = root.appendingPathComponent(relative).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedURL = url.resolvingSymlinksInPath()
        guard resolvedURL.path.hasPrefix(resolvedRoot.path + "/"), !isSymlink(url) else { throw HostWriteError(code: "path_denied", message: "目标文件不在仓库允许范围内。") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func save(_ text: String, relative: String, expectedHash: String) throws {
        let url = root.appendingPathComponent(relative).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedURL = url.resolvingSymlinksInPath()
        guard resolvedURL.path.hasPrefix(resolvedRoot.path + "/"), !isSymlink(url) else { throw HostWriteError(code: "path_denied", message: "目标文件不在仓库允许范围内。") }
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard hash(current) == expectedHash else { throw HostWriteError(code: "conflict", message: "文件已被其他程序修改，请重新加载。") }
        let backupRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NCU StudyRocket/Backups", isDirectory: true)
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        if let oldData = current.data(using: .utf8) {
            let backup = backupRoot.appendingPathComponent(relative.replacingOccurrences(of: "/", with: "_") + ".\(Int(Date().timeIntervalSince1970)).bak")
            try oldData.write(to: backup, options: .atomic)
        }
        try Data(text.utf8).write(to: url, options: .atomic)
        pruneBackups(in: backupRoot, prefix: relative.replacingOccurrences(of: "/", with: "_") + ".")
    }

    private func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func isSymlink(_ url: URL) -> Bool { ((try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false) }

    private func replayedValue(for key: String) -> SnapshotResponse? {
        guard !key.isEmpty else { return nil }
        replayLock.lock(); defer { replayLock.unlock() }
        return replayed[key]
    }

    private func storeReplay(_ value: SnapshotResponse, for key: String) {
        guard !key.isEmpty else { return }
        replayLock.lock(); replayed[key] = value
        if replayed.count > 128 { replayed.removeValue(forKey: replayed.keys.first!) }
        replayLock.unlock()
    }

    private func pruneBackups(in directory: URL, prefix: String) {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        let matches = files.filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        for file in matches.dropFirst(20) { try? fileManager.removeItem(at: file) }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

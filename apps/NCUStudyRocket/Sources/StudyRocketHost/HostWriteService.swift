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
    private let backupRoot: URL
    private var calendar: Calendar
    private let writeLock = NSLock()
    private let replayLock = NSLock()
    private var replayed: [String: SnapshotResponse] = [:]

    init(
        root: URL,
        backupRoot: URL? = StudyRocketSelfCheckConfiguration.current?.backupDirectory
    ) {
        self.root = root.standardizedFileURL
        snapshotBuilder = HostSnapshotBuilder(root: root.standardizedFileURL)
        self.backupRoot = (backupRoot
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/NCU StudyRocket/Backups", isDirectory: true)
        ).standardizedFileURL
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        self.calendar = calendar
    }

    func applyWeek(_ request: PlanWriteRequest) throws -> SnapshotResponse {
        writeLock.lock(); defer { writeLock.unlock() }
        if let cached = replayedValue(for: request.metadata.idempotencyKey) { return cached }
        try ensureAPIVersion(request.metadata.apiVersion)
        let plan = WeeklyPlanTaskNormalizer.normalized(request.plan)
        try ensureNoReservedMarkers(in: plan)
        let relative = "工作台/下周计划.md"
        let source = try read(relative)
        let current = try ensureRevision(request.metadata.baseRevision)
        var completionRecords = try parsePeriodCompletionRecords(source)
        let sourceMigrations: [String: String] = Dictionary(uniqueKeysWithValues: plan.deliveries.compactMap { delivery -> (String, String)? in
            guard let previous = current.week.deliveries.first(where: { $0.id == delivery.id }),
                  previous.text != delivery.text else { return nil }
            return (DeliveryPeriodMatcher.sourceKey(for: previous.text), DeliveryPeriodMatcher.sourceKey(for: delivery.text))
        })
        completionRecords = Set(completionRecords.map { record in
            guard let source = record.source, let migrated = sourceMigrations[source] else { return record }
            return PersistedPeriodCompletion(dayID: record.dayID, periodID: record.periodID, textHash: record.textHash, source: migrated)
        })
        // The mobile client edits the schedule, deliveries and fallback rules in
        // one screen.  Keep those edits in the same atomic save so a successful
        // response can never silently drop two thirds of the submitted plan.
        let scheduled = try updateWeekly(source, plan: plan)
        let deliveries = try updateDeliveries(scheduled, deliveries: plan.deliveries)
        let buffered = try updateBuffers(deliveries, rules: plan.bufferRules)
        let validKeys = periodCompletionKeys(in: plan)
        let validRecords = Set(completionRecords.filter { validKeys.contains($0.key) })
        let updated = try updatePeriodCompletionBlock(buffered, records: validRecords)
        try save(updated, relative: relative, expectedHash: hash(source))
        let value = snapshotBuilder.build()
        storeReplay(value, for: request.metadata.idempotencyKey)
        return value
    }

    func toggleDelivery(_ request: DeliveryToggleRequest) throws -> SnapshotResponse {
        writeLock.lock(); defer { writeLock.unlock() }
        if let cached = replayedValue(for: request.metadata.idempotencyKey) { return cached }
        try ensureAPIVersion(request.metadata.apiVersion)
        let current = try ensureRevision(request.metadata.baseRevision)
        let relative = "工作台/下周计划.md"
        let source = try read(relative)
        let marker = request.isCompleted ? "- [x]" : "- [ ]"
        let other = request.isCompleted ? "- [ ]" : "- [x]"
        var lines = source.components(separatedBy: .newlines)
        let section = try sectionContentRange(in: lines, headingPrefix: "## 交付物")
        let contentRange = try managedContentRange(
            in: lines,
            section: section,
            markers: ("studyrocket:deliveries:start", "studyrocket:deliveries:end")
        ) ?? section
        var matches: [Int] = []
        var index = contentRange.lowerBound
        while index < contentRange.upperBound {
            let line = lines[index]
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix(other) else { index += 1; continue }
            var currentText = line.replacingOccurrences(of: #"^\s*-\s*\[[ xX]\]\s*"#, with: "", options: .regularExpression)
            var next = index + 1
            while next < contentRange.upperBound, lines[next].hasPrefix("  ") {
                currentText += "\n" + lines[next].dropFirst(2)
                next += 1
            }
            if currentText.trimmingCharacters(in: .whitespacesAndNewlines) == request.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                matches.append(index)
            }
            index = next
        }
        guard matches.count == 1, let match = matches.first else {
            throw HostWriteError(code: "delivery_not_found", message: "找不到唯一对应的交付物，文件可能已被外部修改。")
        }
        guard let delivery = current.week.deliveries.first(where: {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                == request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }) else {
            throw HostWriteError(code: "delivery_not_found", message: "找不到对应的交付物，请重新加载计划。")
        }
        let firstLine = lines[match].replacingOccurrences(of: #"^\s*-\s*\[[ xX]\]\s*"#, with: "", options: .regularExpression)
        let prefix = lines[match].prefix { $0 == " " || $0 == "\t" }
        lines[match] = String(prefix) + marker + " " + firstLine
        var updated = lines.joined(separator: "\n")
        let validKeys = periodCompletionKeys(in: current.week)
        var records = Set(try parsePeriodCompletionRecords(source).filter { validKeys.contains($0.key) })
        let deliverySource = DeliveryPeriodMatcher.sourceKey(for: delivery.text)
        if request.isCompleted, let dayID = deliveryDayID(delivery) {
            for period in periods(on: dayID, in: current.week)
            {
                for task in period.tasks
                    where DeliveryPeriodMatcher.matches(deliveryText: delivery.text, periodText: task.text) {
                    records.insert(PersistedPeriodCompletion(
                        dayID: dayID,
                        periodID: period.id,
                        textHash: task.id,
                        source: deliverySource
                    ))
                }
            }
        } else if !request.isCompleted {
            records = Set(records.filter { $0.source != deliverySource })
        }
        updated = try updatePeriodCompletionBlock(updated, records: records)
        try save(updated, relative: relative, expectedHash: hash(source))
        let value = snapshotBuilder.build()
        storeReplay(value, for: request.metadata.idempotencyKey)
        return value
    }

    func togglePeriod(_ request: PeriodCompletionToggleRequest) throws -> SnapshotResponse {
        writeLock.lock(); defer { writeLock.unlock() }
        if let cached = replayedValue(for: request.metadata.idempotencyKey) { return cached }
        try ensureAPIVersion(request.metadata.apiVersion)
        let relative = "工作台/下周计划.md"
        let source = try read(relative)
        let current = try ensureRevision(request.metadata.baseRevision)
        guard isISODate(request.dayID), Self.periodIDs.contains(request.periodID) else {
            throw HostWriteError(code: "invalid_period", message: "日期或时段无效，请重新加载计划。")
        }
        guard let period = periods(on: request.dayID, in: current.week).first(where: { $0.id == request.periodID }),
              !period.tasks.isEmpty else {
            throw HostWriteError(code: "period_not_found", message: "找不到对应时段任务，请重新加载计划。")
        }

        let taskID: String
        if let requestedTaskID = request.taskID {
            guard PeriodCompletion.isTaskKey(requestedTaskID),
                  period.tasks.contains(where: { $0.id == requestedTaskID }) else {
                throw HostWriteError(code: "period_task_changed", message: "时段任务已变化，请重新加载后再操作。")
            }
            taskID = requestedTaskID
        } else if let legacyTextHash = request.textHash?.lowercased(),
                  PeriodCompletion.isLegacyTextHash(legacyTextHash),
                  period.tasks.count == 1,
                  PeriodCompletion.textHash(for: period.text) == legacyTextHash {
            // Old phones can still toggle a one-item period. A multi-task
            // period deliberately requires the updated client so it cannot
            // change several tasks with one stale whole-period request.
            taskID = period.tasks[0].id
        } else {
            throw HostWriteError(
                code: "period_upgrade_required",
                message: "该时段包含多个任务，请更新手机应用后再操作。"
            )
        }

        let validKeys = periodCompletionKeys(in: current.week)
        var records = Set(try parsePeriodCompletionRecords(source).filter { validKeys.contains($0.key) })
        records = expandingLegacyRecords(
            records,
            dayID: request.dayID,
            period: period
        )
        records = Set(records.filter {
            $0.dayID != request.dayID || $0.periodID != request.periodID || $0.textHash != taskID
        })
        if request.isCompleted {
            records.insert(PersistedPeriodCompletion(dayID: request.dayID, periodID: request.periodID, textHash: taskID, source: nil))
        }
        let updated = try updatePeriodCompletionBlock(source, records: records)
        if updated != source { try save(updated, relative: relative, expectedHash: hash(source)) }
        let value = snapshotBuilder.build()
        storeReplay(value, for: request.metadata.idempotencyKey)
        return value
    }

    func applyDaily(_ request: DailyWriteRequest) throws -> SnapshotResponse {
        writeLock.lock(); defer { writeLock.unlock() }
        if let cached = replayedValue(for: request.metadata.idempotencyKey) { return cached }
        try ensureAPIVersion(request.metadata.apiVersion)
        guard isISODate(request.entry.date) else {
            throw HostWriteError(code: "invalid_date", message: "行为账日期必须使用有效的 yyyy-MM-dd 格式。")
        }
        try ensureNoReservedMarkers(in: [request.entry.deliverables, request.entry.studyTime, request.entry.sleep, request.entry.exercise, request.entry.firstTask])
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

    @discardableResult
    private func ensureRevision(_ expected: String) throws -> SnapshotResponse {
        let current = snapshotBuilder.build()
        guard current.revision == expected else {
            throw HostWriteError(code: "conflict", message: "仓库内容已变化，请重新加载后再保存。")
        }
        return current
    }

    private func ensureAPIVersion(_ version: Int) throws {
        guard version == StudyRocketAPI.version else {
            throw HostWriteError(code: "unsupported_version", message: "客户端版本不兼容，请更新 StudyRocket。")
        }
    }

    private func ensureNoReservedMarkers(in plan: WeeklyPlanSnapshot) throws {
        let dayText = plan.days.flatMap { day in day.slots.map(\.text) + [day.unassigned] }
        let archivedText = (plan.historicalRows + plan.futureRows).flatMap { row in row.slots.map(\.text) + [row.unassigned] }
        try ensureNoReservedMarkers(in: dayText + archivedText + plan.deliveries.map(\.text) + plan.bufferRules.map(\.text))
    }

    private func ensureNoReservedMarkers(in values: [String]) throws {
        guard !values.contains(where: { $0.localizedCaseInsensitiveContains("<!-- studyrocket:") }) else {
            throw HostWriteError(code: "reserved_marker", message: "正文包含 StudyRocket 保留边界，未写入。")
        }
    }

    private func updateWeekly(_ source: String, plan: WeeklyPlanSnapshot) throws -> String {
        let startToken = "<!-- studyrocket:weekly:start -->"
        let endToken = "<!-- studyrocket:weekly:end -->"
        let sourceLines = source.components(separatedBy: .newlines)
        guard sourceLines.filter({ $0.trimmingCharacters(in: .whitespaces) == startToken }).count == 1,
              sourceLines.filter({ $0.trimmingCharacters(in: .whitespaces) == endToken }).count == 1,
              let start = source.range(of: startToken),
              let end = source.range(of: endToken, range: start.upperBound..<source.endIndex) else {
            throw HostWriteError(code: "managed_block_invalid", message: "周计划管理边界缺失、重复或顺序错误，未写入。")
        }
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
            if isMarker(line, "studyrocket:weekly:history:start") { insideHistory = true; return line }
            if isMarker(line, "studyrocket:weekly:history:end") { insideHistory = false; return line }
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
        let missing = plan.days.filter { !seen.contains($0.id) }.filter { day in
            day.slots.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                || !day.unassigned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map { day in
            let label = normalizeDate(day.dateLabel)
            if isStructured {
                return renderTable([
                    label,
                    encodeCell(day.slots[safe: 0]?.text ?? ""),
                    encodeCell(day.slots[safe: 1]?.text ?? ""),
                    encodeCell(day.slots[safe: 2]?.text ?? ""),
                    encodeCell(day.unassigned),
                    "[ ]"
                ])
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
            if let startIndex = all.firstIndex(where: { isMarker($0, "studyrocket:weekly:history:start") }),
               let endIndex = all[(startIndex + 1)..<all.count].firstIndex(where: { isMarker($0, "studyrocket:weekly:history:end") }) {
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
        guard let start = lines.firstIndex(where: { isMarker($0, "studyrocket:weekly:history:start") }),
              let end = lines[(start + 1)..<lines.count].firstIndex(where: { isMarker($0, "studyrocket:weekly:history:end") }) else { return [] }
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

    private static let periodIDs: Set<String> = ["morning", "noon", "evening"]

    private func periodCompletionKeys(in plan: WeeklyPlanSnapshot) -> Set<PeriodCompletionKey> {
        let scheduledRows = (plan.historicalRows + plan.futureRows).compactMap { row -> (String, [PeriodSnapshot])? in
            guard let date = parseDate(row.dateLabel, relativeTo: .now) else { return nil }
            return (isoDateString(date), row.slots)
        }
        let rows = plan.days.map { ($0.id, $0.slots) } + scheduledRows
        return Set(rows.flatMap { dayID, slots in
            slots.flatMap { period -> [PeriodCompletionKey] in
                guard Self.periodIDs.contains(period.id),
                      !period.tasks.isEmpty else { return [] }
                return [
                    PeriodCompletionKey(
                        dayID: dayID,
                        periodID: period.id,
                        textHash: PeriodCompletion.textHash(for: period.text)
                    )
                ] + period.tasks.map {
                    PeriodCompletionKey(dayID: dayID, periodID: period.id, textHash: $0.id)
                }
            }
        })
    }

    private func expandingLegacyRecords(
        _ records: Set<PersistedPeriodCompletion>,
        dayID: String,
        period: PeriodSnapshot
    ) -> Set<PersistedPeriodCompletion> {
        let legacyHash = PeriodCompletion.textHash(for: period.text)
        let legacyRecords = records.filter {
            $0.dayID == dayID && $0.periodID == period.id && $0.textHash == legacyHash
        }
        guard !legacyRecords.isEmpty else { return records }

        var expanded = records
        expanded.subtract(legacyRecords)
        for record in legacyRecords {
            for task in period.tasks {
                expanded.insert(PersistedPeriodCompletion(
                    dayID: dayID,
                    periodID: period.id,
                    textHash: task.id,
                    source: record.source
                ))
            }
        }
        return expanded
    }

    private func parsePeriodCompletionRecords(_ source: String) throws -> Set<PersistedPeriodCompletion> {
        let lines = source.components(separatedBy: .newlines)
        let starts = lines.indices.filter { isMarker(lines[$0], "studyrocket:period-completion:start") }
        let ends = lines.indices.filter { isMarker(lines[$0], "studyrocket:period-completion:end") }
        guard starts.count <= 1, ends.count <= 1, starts.count == ends.count else {
            throw HostWriteError(code: "managed_block_invalid", message: "时段完成状态边界已损坏，请先修复计划文件。")
        }
        guard let start = starts.first, let end = ends.first else { return [] }
        guard start < end else {
            throw HostWriteError(code: "managed_block_invalid", message: "时段完成状态边界已损坏，请先修复计划文件。")
        }
        return Set(lines[(start + 1)..<end].compactMap { line in
            let cells = splitTable(line)
            guard cells.count >= 4,
                  isISODate(cells[0]),
                  Self.periodIDs.contains(cells[1]),
                  PeriodCompletion.isValidRecordKey(cells[2]),
                  cells[3].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "[x]" else { return nil }
            let source = cells.indices.contains(4) ? cells[4].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            guard source.isEmpty || source.range(of: #"^delivery:[0-9a-f]{64}$"#, options: .regularExpression) != nil else { return nil }
            return PersistedPeriodCompletion(
                dayID: cells[0],
                periodID: cells[1],
                textHash: cells[2].lowercased(),
                source: source.isEmpty ? nil : source
            )
        })
    }

    private func updatePeriodCompletionBlock(_ source: String, records: Set<PersistedPeriodCompletion>) throws -> String {
        var lines = source.components(separatedBy: .newlines)
        let starts = lines.indices.filter { isMarker(lines[$0], "studyrocket:period-completion:start") }
        let ends = lines.indices.filter { isMarker(lines[$0], "studyrocket:period-completion:end") }
        guard starts.count <= 1, ends.count <= 1, starts.count == ends.count else {
            throw HostWriteError(code: "managed_block_invalid", message: "时段完成状态边界已损坏，请先修复计划文件。")
        }
        if let start = starts.first, let end = ends.first {
            guard start < end else {
                throw HostWriteError(code: "managed_block_invalid", message: "时段完成状态边界已损坏，请先修复计划文件。")
            }
            lines.removeSubrange(start...end)
        }
        guard let weeklyEnd = lines.firstIndex(where: { isMarker($0, "studyrocket:weekly:end") }) else {
            throw HostWriteError(code: "managed_block_missing", message: "找不到周计划管理边界，未写入完成状态。")
        }
        let order = ["morning": 0, "noon": 1, "evening": 2]
        let rows = records.sorted {
            ($0.dayID, order[$0.periodID] ?? .max, $0.textHash, $0.source ?? "")
                < ($1.dayID, order[$1.periodID] ?? .max, $1.textHash, $1.source ?? "")
        }.map { "| \($0.dayID) | \($0.periodID) | \($0.textHash) | [x] | \($0.source ?? "") |" }
        let block = [
            "<!-- studyrocket:period-completion:start -->",
            "| 日期 | 时段 | 任务标识 | 完成 | 来源 |",
            "|------|------|----------|------|------|"
        ] + rows + ["<!-- studyrocket:period-completion:end -->"]
        lines.insert(contentsOf: block, at: weeklyEnd + 1)
        return lines.joined(separator: "\n")
    }

    private func isISODate(_ text: String) -> Bool {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let values = text.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3,
              let date = calendar.date(from: DateComponents(year: values[0], month: values[1], day: values[2])) else { return false }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date) == text
    }

    private func deliveryDayID(_ delivery: DeliverySnapshot) -> String? {
        guard let label = delivery.dateLabel, let date = parseDate(label, relativeTo: .now) else { return nil }
        return isoDateString(date)
    }

    private func isoDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func periods(on dayID: String, in plan: WeeklyPlanSnapshot) -> [PeriodSnapshot] {
        if let day = plan.days.first(where: { $0.id == dayID }) { return day.slots }
        return (plan.historicalRows + plan.futureRows).first(where: { row in
            guard let date = parseDate(row.dateLabel, relativeTo: .now) else { return false }
            return isoDateString(date) == dayID
        })?.slots ?? []
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

    private func updateDeliveries(_ source: String, deliveries: [DeliverySnapshot]) throws -> String {
        let lines = source.components(separatedBy: .newlines)
        guard let heading = lines.firstIndex(where: { $0.hasPrefix("## 交付物") }) else {
            throw HostWriteError(code: "managed_block_missing", message: "找不到交付物清单，未写入。")
        }
        let content = deliveryLines(for: deliveries)
        return try replacingManagedSection(
            in: lines,
            headingIndex: heading,
            markers: ("studyrocket:deliveries:start", "studyrocket:deliveries:end"),
            content: content
        ).joined(separator: "\n")
    }

    private func updateBuffers(_ source: String, rules: [BufferRuleSnapshot]) throws -> String {
        let lines = source.components(separatedBy: .newlines)
        guard let heading = lines.firstIndex(where: { $0.hasPrefix("## 缓冲") }) else {
            throw HostWriteError(code: "managed_block_missing", message: "找不到缓冲规则，未写入。")
        }
        return try replacingManagedSection(
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
    ) throws -> [String] {
        var lines = source
        let section = try sectionContentRange(in: lines, headingIndex: headingIndex)
        if let managed = try managedContentRange(in: lines, section: section, markers: markers) {
            lines.replaceSubrange(managed, with: content)
        } else {
            let managed = ["<!-- \(markers.start) -->"] + content + ["<!-- \(markers.end) -->"]
            lines.replaceSubrange(section, with: managed)
        }
        return lines
    }

    private func sectionContentRange(in lines: [String], headingPrefix: String) throws -> Range<Int> {
        guard let heading = lines.firstIndex(where: { $0.hasPrefix(headingPrefix) }) else {
            throw HostWriteError(code: "managed_block_missing", message: "找不到受管理内容，未写入。")
        }
        return try sectionContentRange(in: lines, headingIndex: heading)
    }

    private func sectionContentRange(in lines: [String], headingIndex: Int) throws -> Range<Int> {
        guard lines.indices.contains(headingIndex) else {
            throw HostWriteError(code: "managed_block_missing", message: "找不到受管理内容，未写入。")
        }
        let start = headingIndex + 1
        var end = start
        while end < lines.count, !lines[end].hasPrefix("## ") { end += 1 }
        return start..<end
    }

    private func managedContentRange(
        in lines: [String],
        section: Range<Int>,
        markers: (start: String, end: String)
    ) throws -> Range<Int>? {
        let startToken = "<!-- \(markers.start) -->"
        let endToken = "<!-- \(markers.end) -->"
        let starts = section.filter { lines[$0].trimmingCharacters(in: .whitespaces) == startToken }
        let ends = section.filter { lines[$0].trimmingCharacters(in: .whitespaces) == endToken }
        if starts.isEmpty, ends.isEmpty { return nil }
        guard starts.count == 1, ends.count == 1, starts[0] < ends[0] else {
            throw HostWriteError(code: "managed_block_invalid", message: "受管理内容边界缺失、重复或顺序错误，未写入。")
        }
        return (starts[0] + 1)..<ends[0]
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

    private func isMarker(_ line: String, _ marker: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "<!-- \(marker) -->"
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

private struct PersistedPeriodCompletion: Hashable {
    let dayID: String
    let periodID: String
    let textHash: String
    let source: String?

    var key: PeriodCompletionKey {
        PeriodCompletionKey(dayID: dayID, periodID: periodID, textHash: textHash)
    }
}

private struct PeriodCompletionKey: Hashable {
    let dayID: String
    let periodID: String
    let textHash: String
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

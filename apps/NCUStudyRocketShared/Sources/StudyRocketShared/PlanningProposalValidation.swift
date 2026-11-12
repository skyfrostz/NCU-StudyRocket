import Foundation

public enum PlanningProposalValidation {
    public static let instructions = """
    独立任务格式：编辑工作台/下周计划.md 时，同一时段中可以分别完成的事项必须用 <br> 分隔，每项单独勾选；不要用分号、顿号或“以及”把不同事项合为一个勾选项，也不要在时段单元格内写 Markdown 的 [ ] / [x] 复选框。例如“补齐并提交作业<br>给老师发送请假条”是两项；同一任务自身的步骤、条件和缓冲说明仍保留在该项内，不能按标点机械拆开。新增事项保留已有独立项及其完成状态；拆分旧合并项时不得把旧完成状态擅自复制给新项。
    有明确开始时间的任务归入上午（12:00 前）、中午（12:00–17:59）或晚上（18:00 起），仅有截止时间不等于开始时间，不因此移动原安排；无法判断执行时段才放待分配。
    计划分流规则：需要完成的学习、科研、作业、老师交办和班务事项写入今日任务，执行时间和截止时间保留在任务中；训练、会议、讲座和到场活动只进入指定日期的课表，不重复写到今日任务。活动缺日期或开始时间时先询问，不猜时间地点，不生成重复安排。单次活动写入工作台/学期/2026秋季个人课表.md 的 studyrocket:events 管理块，使用表头 | ID | 日期 | 开始 | 结束 | 名称 | 地点 | 说明 |，ID 为独立 UUID，日期 yyyy-MM-dd，时间 HH:mm；改时沿用原 ID，结束可留空。保留原课表导入区及边界外正文。涉及周计划和课表时对两个文件各生成一份草案，供用户成组确认。
    周计划中的 studyrocket:task-links 管理块是稳定任务关联记录，必须完整保留。单纯改期或改名保留任务 ID 和交付物 ID；安排实例 ID 独立，原安排保留为非活动记录；不同日期的重复练习不可自动当成同一任务。文字相似只用于建议关联，需要用户确认后绑定；不按相似内容自动完成任务。由你整理任务分类、交付物和改期建议，通过草案说明关系变化交给用户确认，不要求用户逐项操作复杂关联面板。仅对影响安排的真实歧义向用户提问，不编造完成状态。
    """
    public static func prepare(path: String, original: String, proposed: String) throws -> String {
        try validateManagedBoundaries(path: path, original: original, proposed: proposed)
        if path == StudyRocketTimetableParser.sourceFile {
            _ = try OneOffSchedule.read(proposed)
            return proposed
        }
        guard path == "工作台/下周计划.md" else { return proposed }
        let old = try TaskLinkageMarkdown.read(original)
        let graph = try TaskLinkageMarkdown.read(proposed)
        guard old == nil || graph != nil else { throw TaskLinkageError.malformed }
        if let old, let graph, old.activationDate != graph.activationDate { throw TaskLinkageError.changed }
        if let old, let graph { try preserveHistory(from: old, in: graph) }
        let normalized = WeeklyPlanTaskNormalizer.normalizedMarkdown(proposed)
        if let graph {
            let snapshot = rawSnapshot(normalized)
            let prepared = graph.applyingScheduleEdits(snapshot, previous: rawSnapshot(original))
            if prepared.tasks.contains(where: { !$0.cancelled && $0.category == .unclassified && $0.reminderForTaskID == nil }) {
                throw TaskLinkageError.categoryRequired
            }
            return prepared == graph ? normalized : try TaskLinkageMarkdown.write(prepared, in: normalized)
        }
        return normalized
    }

    public struct BoundaryError: LocalizedError {
        public var errorDescription: String? {
            "草案删除、重复、损坏或改变了既有管理边界的顺序。请保留完整边界后重新生成草案，尚未保存。"
        }
    }

    /// This is also checked immediately before applying persisted proposals.
    /// It validates structure only: authorized edits to content remain allowed.
    public static func validateManagedBoundaries(path: String, original: String, proposed: String) throws {
        guard path == "工作台/下周计划.md" || path == StudyRocketTimetableParser.sourceFile else { return }
        let before = try boundarySequence(original)
        let after = try boundarySequence(proposed)
        let existing = Set(before)
        guard after.filter({ existing.contains($0) }) == before else { throw BoundaryError() }
    }

    private static func boundarySequence(_ source: String) throws -> [String] {
        let pattern = #"^<!-- studyrocket:([a-z0-9-]+(?::[a-z0-9-]+)*):(start|end) -->$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var sequence: [String] = [], stack: [String] = [], seen: Set<String> = []
        for line in PlanningMarkdownLines.parse(source) {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("<!-- studyrocket:"), text.contains(":start") || text.contains(":end") else { continue }
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let nameRange = Range(match.range(at: 1), in: text),
                  let kindRange = Range(match.range(at: 2), in: text) else { throw BoundaryError() }
            let name = String(text[nameRange]), kind = String(text[kindRange])
            if kind == "start" {
                guard seen.insert(name).inserted else { throw BoundaryError() }
                stack.append(name)
            } else {
                guard stack.popLast() == name else { throw BoundaryError() }
            }
            sequence.append(text)
        }
        guard stack.isEmpty else { throw BoundaryError() }
        return sequence
    }

    /// Proposal editing may classify, rename, link, cancel or reschedule work.
    /// Its identity/history ledger is not a way to rewrite completion receipts.
    public static func preserveHistory(from original: TaskLinkage, in proposed: TaskLinkage) throws {
        for old in original.tasks {
            guard let next = proposed.tasks.first(where: { $0.id == old.id }),
                  next.originDate == old.originDate, next.completedAt == old.completedAt,
                  next.completionSource == old.completionSource else { throw TaskLinkageError.changed }
        }
        for old in original.deliveries {
            guard let next = proposed.deliveries.first(where: { $0.id == old.id }),
                  next.completedAt == old.completedAt, next.completionOperationID == old.completionOperationID,
                  next.carried == old.carried else { throw TaskLinkageError.changed }
        }
        for old in original.assignments {
            guard let next = proposed.assignments.first(where: { $0.id == old.id }),
                  next.taskID == old.taskID, next.date == old.date, next.periodID == old.periodID else { throw TaskLinkageError.changed }
        }
        let oldTasks = Set(original.tasks.map(\.id)), oldDeliveries = Set(original.deliveries.map(\.id))
        guard proposed.tasks.filter({ !oldTasks.contains($0.id) }).allSatisfy({ $0.completedAt == nil && $0.completionSource == nil }),
              proposed.deliveries.filter({ !oldDeliveries.contains($0.id) }).allSatisfy({ $0.completedAt == nil && $0.completionOperationID == nil }) else { throw TaskLinkageError.changed }
    }

    /// Reads dated rows only; used to finalize linkage metadata before showing a proposal diff.
    public static func rawSnapshot(_ markdown: String) -> WeeklyPlanSnapshot {
        var rows: [ScheduledRowSnapshot] = []
        var inTable = false
        for line in markdown.components(separatedBy: .newlines) {
            if line.contains("studyrocket:weekly") && line.contains(":start") { inTable = true; continue }
            if line.contains("studyrocket:weekly") && line.contains(":end") { inTable = false; continue }
            guard inTable, line.hasPrefix("|") else { continue }
            let c = line.replacingOccurrences(of: "\\|", with: "&#124;").split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map {
                $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "&#124;", with: "|").replacingOccurrences(of: "<br>", with: "\n")
            }
            guard c.count >= 4, PlanningDate.date(c[0]) != nil else { continue }
            let slots = ["morning", "noon", "evening"].enumerated().map { PeriodSnapshot(id: $0.element, title: $0.element, text: c[$0.offset + 1]) }
            rows.append(ScheduledRowSnapshot(id: c[0], dateLabel: c[0], slots: slots, unassigned: c.count > 4 ? c[4] : ""))
        }
        return WeeklyPlanSnapshot(days: [], bufferRules: [], deliveries: [], historicalRows: rows)
    }
}

/// Keep each original line terminator, including CRLF as one terminator. Using
/// CharacterSet.newlines + joined("\n") corrupts untouched CRLF/Unicode prose.
enum PlanningMarkdownLines {
    struct Line { var text: String; let ending: String }
    static func parse(_ source: String) -> [Line] {
        let scalars = source.unicodeScalars
        var lines: [Line] = [], start = scalars.startIndex, cursor = start
        while cursor < scalars.endIndex {
            guard CharacterSet.newlines.contains(scalars[cursor]) else {
                cursor = scalars.index(after: cursor); continue
            }
            var end = scalars.index(after: cursor)
            if scalars[cursor] == "\r", end < scalars.endIndex, scalars[end] == "\n" { end = scalars.index(after: end) }
            lines.append(Line(text: String(source[start..<cursor]), ending: String(source[cursor..<end])))
            start = end; cursor = end
        }
        if start < scalars.endIndex { lines.append(Line(text: String(source[start...]), ending: "")) }
        return lines
    }
    static func joined(_ lines: [Line]) -> String { lines.map { $0.text + $0.ending }.joined() }
}

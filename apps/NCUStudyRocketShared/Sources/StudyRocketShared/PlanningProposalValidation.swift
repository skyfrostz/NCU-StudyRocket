import Foundation

public enum PlanningProposalValidation {
    public static let instructions = """
    计划分流规则：需要完成的学习、科研、作业、老师交办和班务事项写入今日任务，执行时间和截止时间保留在任务中；训练、会议、讲座和到场活动只进入指定日期的课表，不重复写到今日任务。活动缺日期或开始时间时先询问，不猜时间地点，不生成重复安排。单次活动写入工作台/学期/2026秋季个人课表.md 的 studyrocket:events 管理块，使用表头 | ID | 日期 | 开始 | 结束 | 名称 | 地点 | 说明 |，ID 为独立 UUID，日期 yyyy-MM-dd，时间 HH:mm；改时沿用原 ID，结束可留空。保留原课表导入区及边界外正文。涉及周计划和课表时对两个文件各生成一份草案，供用户成组确认。
    周计划中的 studyrocket:task-links 管理块是稳定任务关联记录，必须完整保留。单纯改期或改名保留任务 ID 和交付物 ID；安排实例 ID 独立，原安排保留为非活动记录；不同日期的重复练习不可自动当成同一任务。文字相似只用于建议关联，需要用户确认后绑定；不按相似内容自动完成任务。模糊类别先询问，不能编造完成状态。复杂改期也可引导用户在“任务关联、改期与已完成”中选择原任务操作。
    """
    public static func prepare(path: String, original: String, proposed: String) throws -> String {
        if path == StudyRocketTimetableParser.sourceFile {
            _ = try OneOffSchedule.read(proposed)
            return proposed
        }
        guard path == "工作台/下周计划.md" else { return proposed }
        let old = try TaskLinkageMarkdown.read(original)
        let graph = try TaskLinkageMarkdown.read(proposed)
        guard old == nil || graph != nil else { throw TaskLinkageError.malformed }
        if let old, let graph, old.activationDate != graph.activationDate { throw TaskLinkageError.changed }
        let normalized = WeeklyPlanTaskNormalizer.normalizedMarkdown(proposed)
        if let graph {
            let snapshot = rawSnapshot(normalized)
            let prepared = graph.applyingScheduleEdits(snapshot, previous: rawSnapshot(original))
            if prepared.tasks.contains(where: { !$0.cancelled && $0.category == .unclassified && $0.reminderForTaskID == nil }) {
                throw TaskLinkageError.categoryRequired
            }
            return try TaskLinkageMarkdown.write(prepared, in: normalized)
        }
        return normalized
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

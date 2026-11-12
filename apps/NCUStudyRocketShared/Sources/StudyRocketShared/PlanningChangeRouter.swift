import Foundation

/// Routes dated attendance activities before the diff is presented, so approval and disk bytes agree.
public enum PlanningChangeRouter {
    public struct SnapshotResult {
        public let plan: WeeklyPlanSnapshot
        public let events: [OneOffEvent]?
    }
    public static func route(plan: WeeklyPlanSnapshot, timetable: String, now: Date = .now) throws -> SnapshotResult {
        var events = try OneOffSchedule.read(timetable)
        let previous = events
        var graph = plan.linkage
        func routePeriods(_ values: [PeriodSnapshot], date: String) throws -> [PeriodSnapshot] {
            try values.map { period in
                var retained: [PeriodTaskSnapshot] = []
                for task in period.tasks {
                    let linkedID = task.logicalTaskID ?? graph?.assignments.first(where: { $0.active && $0.date == date && $0.periodID == period.id && $0.legacyTaskID == task.id })?.taskID
                    let category = linkedID.flatMap { id in graph?.tasks.first(where: { $0.id == id })?.category } ?? task.category ?? PlanningCategory.infer(task.text)
                    guard date >= PlanningDate.key(now), category == .event else { retained.append(task); continue }
                    guard let time = times(task.text) else { throw RoutingError("活动“\(task.text)”缺少开始时间，请补充后保存。") }
                    let title = task.text.replacingOccurrences(of: #"^\s*\d{1,2}:\d{2}(?:\s*[-–—~至]\s*\d{1,2}:\d{2})?\s*"#, with: "", options: .regularExpression)
                    let eventID = linkedID.map { PlanningDate.stableID("event|" + $0) }
                    if let i = events.firstIndex(where: { $0.id == eventID }) {
                        events[i].date = date; events[i].start = time.0; events[i].end = time.1; events[i].title = title
                    } else if !events.contains(where: { $0.date == date && $0.start == time.0 && $0.title == title }) {
                        events.append(OneOffEvent(id: eventID ?? UUID().uuidString, date: date, start: time.0, end: time.1, title: title))
                    }
                    if let id = linkedID { try graph?.cancel(id) }
                }
                return PeriodSnapshot(id: period.id, title: period.title, text: retained.map(\.text).joined(separator: "\n"), tasks: retained)
            }
        }
        func slots(_ values: [PeriodSnapshot], unassigned: String, dateLabel: String) throws -> ([PeriodSnapshot], String) {
            guard let date = PlanningDate.date(dateLabel, relativeTo: now) else { return (values, unassigned) }
            let routed = try routePeriods(values + [PeriodSnapshot(id: "unassigned", title: "待分配", text: unassigned)], date: PlanningDate.key(date))
            return (Array(routed.dropLast()), routed.last?.text ?? "")
        }
        let days = try plan.days.map { day in
            let result = try slots(day.slots, unassigned: day.unassigned, dateLabel: day.dateLabel)
            return DaySnapshot(id: day.id, dateLabel: day.dateLabel, slots: result.0, unassigned: result.1)
        }
        func row(_ row: ScheduledRowSnapshot) throws -> ScheduledRowSnapshot {
            let result = try slots(row.slots, unassigned: row.unassigned, dateLabel: row.dateLabel)
            return ScheduledRowSnapshot(id: row.id, dateLabel: row.dateLabel, slots: result.0, unassigned: result.1, isCompleted: row.isCompleted)
        }
        try OneOffSchedule.validate(events)
        let routed = WeeklyPlanSnapshot(days: days, bufferRules: plan.bufferRules, deliveries: plan.deliveries,
            historicalRows: try plan.historicalRows.map(row), futureRows: try plan.futureRows.map(row), linkage: graph)
        return SnapshotResult(plan: graph?.projected(routed, now: now) ?? routed, events: events == previous ? nil : events)
    }
    public struct Result {
        public let week: String
        public let timetable: String?
    }
    public static func route(week proposed: String, original: String, timetable: String, now: Date = .now) throws -> Result {
        try PlanningProposalValidation.validateManagedBoundaries(path: "工作台/下周计划.md", original: original, proposed: proposed)
        var lines = PlanningMarkdownLines.parse(proposed)
        var events = try OneOffSchedule.read(timetable)
        var graph = try TaskLinkageMarkdown.read(proposed)
        let beforeGraph = graph
        let beforeEvents = events
        var inWeek = false
        for index in lines.indices {
            if lines[index].text == "<!-- studyrocket:weekly:start -->" { inWeek = true; continue }
            if lines[index].text == "<!-- studyrocket:weekly:end -->" { inWeek = false; continue }
            guard inWeek, var cells = cells(lines[index].text), cells.count >= 6,
                  let date = PlanningDate.date(cells[0], relativeTo: now), PlanningDate.key(date) >= PlanningDate.key(now) else { continue }
            let day = PlanningDate.key(date)
            var changed = false
            for column in 1...4 {
                var columnChanged = false
                let periodID = ["morning", "noon", "evening", "unassigned"][column - 1]
                let tasks = PeriodTaskParser.tasks(from: cells[column])
                var retained: [String] = []
                for task in tasks {
                    let assignment = graph?.assignments.first(where: { $0.active && $0.date == day && $0.periodID == periodID && $0.legacyTaskID == task.id })
                    let linked = assignment.flatMap { a in graph?.tasks.first(where: { $0.id == a.taskID }) }
                    let category = linked?.category ?? PlanningCategory.infer(task.text)
                    guard category == .event else { retained.append(task.text); continue }
                    guard let time = times(task.text) else {
                        throw RoutingError("活动“\(task.text)”缺少明确开始时间，请先询问用户，尚未生成修改草案。")
                    }
                    let title = task.text.replacingOccurrences(of: #"^\s*\d{1,2}:\d{2}(?:\s*[-–—~至]\s*\d{1,2}:\d{2})?\s*"#, with: "", options: .regularExpression)
                    let eventID = linked.map { PlanningDate.stableID("event|" + $0.id) }
                    if let index = events.firstIndex(where: { $0.id == eventID }) {
                        events[index].date = day; events[index].start = time.0; events[index].end = time.1; events[index].title = title
                    } else if !events.contains(where: { $0.date == day && $0.start == time.0 && $0.title == title }) {
                        events.append(OneOffEvent(id: eventID ?? UUID().uuidString, date: day, start: time.0, end: time.1, title: title))
                    }
                    if let a = graph?.assignments.first(where: { $0.date == day && $0.periodID == periodID && $0.legacyTaskID == task.id }),
                       let i = graph?.tasks.firstIndex(where: { $0.id == a.taskID }) {
                        graph?.tasks[i].cancelled = true
                        for j in graph!.assignments.indices where graph!.assignments[j].taskID == a.taskID { graph!.assignments[j].active = false }
                    }
                    changed = true
                    columnChanged = true
                }
                if columnChanged { cells[column] = retained.joined(separator: "<br>") }
            }
            if changed { lines[index].text = "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |" }
        }
        var week = PlanningMarkdownLines.joined(lines)
        if let graph, graph != beforeGraph { week = try TaskLinkageMarkdown.write(graph, in: week) }
        week = try PlanningProposalValidation.prepare(path: "工作台/下周计划.md", original: original, proposed: week)
        let routedTimetable = events == beforeEvents ? nil : try OneOffSchedule.write(events, in: timetable)
        if let routedTimetable {
            try PlanningProposalValidation.validateManagedBoundaries(path: StudyRocketTimetableParser.sourceFile, original: timetable, proposed: routedTimetable)
        }
        return Result(week: week, timetable: routedTimetable)
    }
    private static func cells(_ line: String) -> [String]? {
        let value = line.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("|"), value.hasSuffix("|") else { return nil }
        var result: [String] = [], current = "", escaped = false
        for c in value.dropFirst().dropLast() {
            if c == "|", !escaped { result.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else if c == "\\", !escaped { escaped = true; continue }
            else { current.append(c) }
            escaped = false
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }
    private static func times(_ text: String) -> (String, String?)? {
        let regex = try! NSRegularExpression(pattern: #"(\d{1,2}):(\d{2})(?:\s*[-–—~至]\s*(\d{1,2}):(\d{2}))?"#)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func number(_ n: Int) -> Int? { Range(match.range(at: n), in: text).flatMap { Int(text[$0]) } }
        guard let h = number(1), let m = number(2) else { return nil }
        let start = String(format: "%02d:%02d", h, m)
        let end = number(3).flatMap { h in number(4).map { String(format: "%02d:%02d", h, $0) } }
        guard OneOffSchedule.minutes(start) != nil else { return nil }
        return (start, end)
    }
    public struct RoutingError: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}

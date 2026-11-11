import Foundation

public enum PlanningCategory: String, Codable, CaseIterable, Sendable {
    case study, research, responsibility, life, event, unclassified
    public var carriesForward: Bool { [.study, .research, .responsibility].contains(self) }
    public var title: String {
        switch self {
        case .study: "学习"
        case .research: "科研"
        case .responsibility: "交办事务"
        case .life: "生活"
        case .event: "活动"
        case .unclassified: "待分类"
        }
    }
    /// Conservative defaults only. Ambiguous prose stays unclassified until explicitly chosen.
    public static func infer(_ text: String) -> Self {
        if ["原截止", "截止提醒", "已提交则", "若未完成", "如果未完成", "缓冲"].contains(where: text.contains) { return .unclassified }
        if ["论文", "科研", "模型训练", "baseline", "数据标注", "实验记录", "代码", "整理数据"].contains(where: text.localizedCaseInsensitiveContains) { return .research }
        let doing = ["整理", "复习", "总结", "作业", "提交", "准备", "完成", "发送", "统计", "帮老师", "给老师"].contains(where: text.contains)
        if !doing && ["参加", "出席", "训练", "会议", "讲座", "庆功会", "选拔", "到场", "羽毛球"].contains(where: text.contains) { return .event }
        if ["作业", "习题", "复习", "预习", "背单词", "课件", "高数", "雅思", "四级", "六级"].contains(where: text.contains) { return .study }
        if ["论文", "科研", "模型训练", "baseline", "数据标注", "实验记录", "代码", "整理数据"].contains(where: text.localizedCaseInsensitiveContains) { return .research }
        if ["给老师", "帮老师", "交材料", "交名单", "交表", "统计", "班务", "催办", "收集", "发送", "提交", "交办"].contains(where: text.contains) { return .responsibility }
        if !doing && ["参加", "训练", "会议", "讲座", "庆功会", "选拔", "到场"].contains(where: text.contains) { return .event }
        if ["吃饭", "健身", "购物", "洗衣", "打扫", "运动"].contains(where: text.contains) { return .life }
        return .unclassified
    }
}

public enum PlanningDate {
    public static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        value.firstWeekday = 2
        return value
    }
    public static func key(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    public static func date(_ label: String, relativeTo reference: Date = .now) -> Date? {
        let pattern = #"(?:(\d{4})\s*[-年]\s*)?(\d{1,2})\s*[-月]\s*(\d{1,2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) else { return nil }
        func number(_ n: Int) -> Int? { Range(m.range(at: n), in: label).flatMap { Int(label[$0]) } }
        let year = number(1) ?? calendar.component(.year, from: reference)
        guard let month = number(2), let day = number(3) else { return nil }
        if number(1) == nil {
            return (year - 1...year + 1).compactMap { candidate in
                calendar.date(from: DateComponents(year: candidate, month: month, day: day))
            }.filter { calendar.component(.month, from: $0) == month && calendar.component(.day, from: $0) == day }
                .min { abs($0.timeIntervalSince(reference)) < abs($1.timeIntervalSince(reference)) }
        }
        guard
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day else { return nil }
        return date
    }
    public static func stableID(_ text: String) -> String {
        let h = PeriodCompletion.textHash(for: text)
        return "\(h.prefix(8))-\(h.dropFirst(8).prefix(4))-\(h.dropFirst(12).prefix(4))-\(h.dropFirst(16).prefix(4))-\(h.dropFirst(20).prefix(12))".uppercased()
    }
}

public struct LinkedTask: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var category: PlanningCategory
    public var originDate: String
    public var deliveryID: String?
    public var dueAt: String?
    public var reminderForTaskID: String?
    public var completedAt: String?
    public var completionSource: String?
    public var cancelled: Bool = false
    public var isCompleted: Bool { completedAt != nil }
}

public struct TaskAssignment: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var taskID: String
    public var date: String
    public var periodID: String
    public var legacyTaskID: String
    public var active: Bool = true
}

public struct LinkedDelivery: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var completedAt: String?
    public var completionOperationID: String?
    public var carried: Bool = false
    public var cancelled: Bool = false
}

public enum TaskLinkageError: LocalizedError {
    case malformed, changed, confirmationRequired([String]), categoryRequired
    public var errorDescription: String? {
        switch self {
        case .malformed: "任务关联数据格式不正确，未保存。"
        case .changed: "任务或关联关系已变化，请刷新后重试。"
        case .confirmationRequired: "请先确认将一并完成的子任务。"
        case .categoryRequired: "请先选择任务类别。"
        }
    }
}

/// This ledger lives in the weekly Markdown. Snapshots are projections, never a second database.
public struct TaskLinkage: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var activationDate: String
    public var tasks: [LinkedTask] = []
    public var assignments: [TaskAssignment] = []
    public var deliveries: [LinkedDelivery] = []
    public init(activationDate: String) { self.activationDate = activationDate }

    public func children(of deliveryID: String) -> [LinkedTask] {
        tasks.filter { $0.deliveryID == deliveryID && !$0.cancelled }
    }
    public func isCompleted(_ delivery: LinkedDelivery) -> Bool {
        let children = children(of: delivery.id)
        return children.isEmpty ? delivery.completedAt != nil : children.allSatisfy(\.isCompleted)
    }
    public func pendingChildren(of deliveryID: String) -> [LinkedTask] { children(of: deliveryID).filter { !$0.isCompleted } }

    /// Only an explicit edit removes an assignment. Read-only projections never mutate history.
    public func applyingScheduleEdits(_ edited: WeeklyPlanSnapshot, previous: WeeklyPlanSnapshot, now: Date = .now) -> Self {
        var result = self
        let oldRows = previous.planningRows(now: now)
        let rows = edited.planningRows(now: now)
        for i in result.assignments.indices where result.assignments[i].active {
            let a = result.assignments[i]
            func contains(_ rows: [(String, [PeriodSnapshot], String)]) -> Bool {
                rows.contains { row in
                    guard row.0 == a.date else { return false }
                    let tasks = a.periodID == "unassigned" ? PeriodTaskParser.tasks(from: row.2) : row.1.first(where: { $0.id == a.periodID })?.tasks ?? []
                    return tasks.contains { $0.assignmentID == a.id || $0.id == a.legacyTaskID || (result.tasks.first(where: { $0.id == a.taskID })?.text == $0.text) }
                }
            }
            if contains(oldRows) && !contains(rows) { result.assignments[i].active = false }
        }
        return result.reconciled(with: edited, now: now)
    }

    public func reconciled(with plan: WeeklyPlanSnapshot, now: Date = .now) -> Self {
        var result = self
        let today = PlanningDate.key(now)
        var usedDeliveryIDs = Set<String>()
        for delivery in plan.deliveries {
            let identity = UUID(uuidString: delivery.id)?.uuidString ?? PlanningDate.stableID(delivery.id)
            if let index = result.deliveries.firstIndex(where: { ($0.id == delivery.id || $0.id == identity) && !usedDeliveryIDs.contains($0.id) }) {
                result.deliveries[index].text = delivery.text
                usedDeliveryIDs.insert(result.deliveries[index].id)
            } else if let existing = result.deliveries.first(where: { $0.text == delivery.text && !usedDeliveryIDs.contains($0.id) }) {
                // Exact text occurrence is legacy document compatibility, never a completion link.
                usedDeliveryIDs.insert(existing.id)
            } else {
                var id = identity
                if result.deliveries.contains(where: { $0.id == id }) {
                    id = PlanningDate.stableID("delivery|\(activationDate)|\(delivery.text)|\(usedDeliveryIDs.count)")
                }
                result.deliveries.append(LinkedDelivery(id: id, text: delivery.text, completedAt: delivery.isCompleted ? today : nil))
                usedDeliveryIDs.insert(id)
            }
        }
        for (date, periods, unassigned) in plan.planningRows(now: now) where date >= activationDate {
            let allPeriods = periods + [PeriodSnapshot(id: "unassigned", title: "待分配", text: unassigned)]
            for period in allPeriods {
                for task in period.tasks {
                    let known = result.assignments.firstIndex { $0.active && $0.date == date && $0.periodID == period.id && $0.legacyTaskID == task.id } ?? result.assignments.firstIndex { $0.date == date && $0.periodID == period.id && $0.legacyTaskID == task.id }
                    if known != nil {
                        continue
                    }
                    let renamed = result.assignments.indices.filter { index in
                        let a = result.assignments[index]
                        return a.active && a.date == date && a.periodID == period.id && !period.tasks.contains(where: { $0.id == a.legacyTaskID }) && result.tasks.first(where: { $0.id == a.taskID })?.text == task.text
                    }
                    if renamed.count == 1, let index = renamed.first {
                        result.assignments[index].legacyTaskID = task.id
                        continue
                    }
                    let id = task.logicalTaskID ?? PlanningDate.stableID("task|\(date)|\(period.id)|\(task.id)")
                    if !result.tasks.contains(where: { $0.id == id }) {
                        result.tasks.append(LinkedTask(id: id, text: task.text, category: PlanningCategory.infer(task.text), originDate: date, dueAt: Self.deadline(task.text, date: date),
                            completedAt: task.isCompleted ? today : nil, completionSource: task.isCompleted ? "independent" : nil))
                    }
                    result.assignments.append(TaskAssignment(id: task.assignmentID ?? PlanningDate.stableID("assignment|\(date)|\(period.id)|\(task.id)"),
                        taskID: id, date: date, periodID: period.id, legacyTaskID: task.id))
                }
            }
        }
        // An overdue logical task gets one stable parent, regardless of how often it is moved.
        for index in result.tasks.indices {
            let task = result.tasks[index]
            guard task.originDate < today, task.category.carriesForward, task.reminderForTaskID == nil, !task.cancelled, !task.isCompleted, task.deliveryID == nil else { continue }
            let id = PlanningDate.stableID("carry|\(task.id)")
            result.tasks[index].deliveryID = id
            if !result.deliveries.contains(where: { $0.id == id }) {
                result.deliveries.append(LinkedDelivery(id: id, text: task.text, carried: true))
            }
        }
        return result
    }

    public func projected(_ plan: WeeklyPlanSnapshot, now: Date = .now) -> WeeklyPlanSnapshot {
        let graph = reconciled(with: plan, now: now)
        func periods(_ periods: [PeriodSnapshot], date: String) -> [PeriodSnapshot] {
            periods.map { period in
                var values = period.tasks.compactMap { value -> PeriodTaskSnapshot? in
                    guard let a = graph.assignments.first(where: { $0.active && $0.date == date && $0.periodID == period.id && $0.legacyTaskID == value.id }) ?? graph.assignments.first(where: { $0.date == date && $0.periodID == period.id && $0.legacyTaskID == value.id }),
                          let task = graph.tasks.first(where: { $0.id == a.taskID }) else { return value }
                    guard a.active, !task.cancelled else { return nil }
                    return PeriodTaskSnapshot(id: value.id, text: task.text, isCompleted: task.isCompleted,
                        logicalTaskID: task.id, assignmentID: a.id, category: task.category)
                }
                for a in graph.assignments where a.active && a.date == date && a.periodID == period.id {
                    guard !values.contains(where: { $0.assignmentID == a.id }),
                          let task = graph.tasks.first(where: { $0.id == a.taskID }), !task.cancelled else { continue }
                    values.append(PeriodTaskSnapshot(id: a.legacyTaskID, text: task.text, isCompleted: task.isCompleted,
                        logicalTaskID: task.id, assignmentID: a.id, category: task.category))
                }
                return PeriodSnapshot(id: period.id, title: period.title, text: values.map(\.text).joined(separator: "\n"), tasks: values)
            }
        }
        func dateKey(_ label: String) -> String { PlanningDate.date(label, relativeTo: now).map(PlanningDate.key) ?? label }
        func row(_ row: ScheduledRowSnapshot) -> ScheduledRowSnapshot {
            ScheduledRowSnapshot(id: row.id, dateLabel: row.dateLabel, slots: periods(row.slots, date: dateKey(row.dateLabel)), unassigned: periods([PeriodSnapshot(id: "unassigned", title: "待分配", text: row.unassigned)], date: dateKey(row.dateLabel)).first?.text ?? "", isCompleted: row.isCompleted)
        }
        var future = plan.futureRows.map(row)
        var history = plan.historicalRows.map(row)
        let days = plan.days.map { day in
            DaySnapshot(id: day.id, dateLabel: day.dateLabel, slots: periods(day.slots, date: dateKey(day.dateLabel)), unassigned: periods([PeriodSnapshot(id: "unassigned", title: "待分配", text: day.unassigned)], date: dateKey(day.dateLabel)).first?.text ?? "")
        }
        let present = Set(plan.planningRows(now: now).map { $0.0 })
        for date in Set(graph.assignments.filter(\.active).map(\.date)).subtracting(present).sorted() {
            let empty = ["morning", "noon", "evening"].map { PeriodSnapshot(id: $0, title: $0, text: "") }
            let value = ScheduledRowSnapshot(id: "linked:\(date)", dateLabel: date, slots: periods(empty, date: date), unassigned: periods([PeriodSnapshot(id: "unassigned", title: "待分配", text: "")], date: date).first?.text ?? "")
            if date < PlanningDate.key(now) { history.append(value) } else { future.append(value) }
        }
        let currentWeek = WeeklyDeliveryRollover.weekStart(now)
        let deliveries = graph.deliveries.filter { delivery in
            guard !delivery.cancelled else { return false }
            if graph.isCompleted(delivery), let at = delivery.completedAt,
               let date = PlanningDate.date(at), WeeklyDeliveryRollover.weekStart(date) < currentWeek { return false }
            return true
        }.map { delivery in
            let origin = graph.children(of: delivery.id).map(\.originDate).min()
            return DeliverySnapshot(id: delivery.id, text: delivery.text, isCompleted: graph.isCompleted(delivery),
                dateLabel: delivery.carried ? origin : PlanningDate.date(delivery.text, relativeTo: now).map(PlanningDate.key))
        }
        return WeeklyPlanSnapshot(days: days, bufferRules: plan.bufferRules, deliveries: deliveries, historicalRows: history, futureRows: future, linkage: graph)
    }

    public mutating func setTask(_ id: String, completed: Bool, now: Date = .now, source: String = "independent") throws {
        guard let i = tasks.firstIndex(where: { $0.id == id }), !tasks[i].cancelled else { throw TaskLinkageError.changed }
        guard tasks[i].isCompleted != completed else { return }
        tasks[i].completedAt = completed ? PlanningDate.key(now) : nil
        tasks[i].completionSource = completed ? source : nil
        for reminder in tasks.filter({ $0.reminderForTaskID == id && !$0.cancelled }) {
            if completed || reminder.completionSource == "task:\(id)" {
                try setTask(reminder.id, completed: completed, now: now, source: "task:\(id)")
            }
        }
        if let parent = tasks[i].deliveryID, let p = deliveries.firstIndex(where: { $0.id == parent }) {
            deliveries[p].completedAt = children(of: parent).allSatisfy(\.isCompleted) ? PlanningDate.key(now) : nil
        }
    }
    public mutating func setDelivery(_ id: String, completed: Bool, confirmedTaskIDs: [String]? = nil, now: Date = .now) throws {
        guard let i = deliveries.firstIndex(where: { $0.id == id }), !deliveries[i].cancelled else { throw TaskLinkageError.changed }
        let pending = pendingChildren(of: id)
        if completed, !pending.isEmpty, Set(confirmedTaskIDs ?? []) != Set(pending.map(\.id)) {
            throw TaskLinkageError.confirmationRequired(pending.map(\.text))
        }
        let source: String
        if completed {
            guard !isCompleted(deliveries[i]) else { return }
            source = "delivery:\(id):\(UUID().uuidString)"
            deliveries[i].completionOperationID = source
        } else { source = deliveries[i].completionOperationID ?? "delivery:\(id)" }
        for task in children(of: id) where completed ? !task.isCompleted : task.completionSource == source {
            try setTask(task.id, completed: completed, now: now, source: source)
        }
        deliveries[i].completedAt = completed ? PlanningDate.key(now) : nil
        if !completed { deliveries[i].completionOperationID = nil }
    }
    public mutating func link(_ taskID: String, to deliveryID: String?) throws {
        guard let i = tasks.firstIndex(where: { $0.id == taskID }), deliveryID == nil || deliveries.contains(where: { $0.id == deliveryID && !$0.cancelled }) else { throw TaskLinkageError.changed }
        let old = tasks[i].deliveryID
        tasks[i].deliveryID = deliveryID
        if let old, let d = deliveries.firstIndex(where: { $0.id == old && $0.carried }), children(of: old).isEmpty { deliveries[d].cancelled = true }
        for parent in [old, deliveryID].compactMap({ $0 }) {
            if let d = deliveries.firstIndex(where: { $0.id == parent }), !children(of: parent).isEmpty {
                deliveries[d].completedAt = children(of: parent).allSatisfy(\.isCompleted) ? PlanningDate.key(.now) : nil
            }
        }
    }
    public mutating func setReminder(_ id: String, for taskID: String?) throws {
        guard let i = tasks.firstIndex(where: { $0.id == id }),
              taskID == nil || tasks.contains(where: { $0.id == taskID && $0.id != id && !$0.cancelled && $0.reminderForTaskID == nil }),
              !tasks.contains(where: { $0.reminderForTaskID == id }) else { throw TaskLinkageError.changed }
        tasks[i].reminderForTaskID = taskID
        if let target = tasks.first(where: { $0.id == taskID }) {
            try link(id, to: nil)
            tasks[i].category = target.category
            if target.isCompleted { try setTask(id, completed: true, source: "task:\(target.id)") }
        }
    }
    public mutating func reschedule(_ taskID: String, date: String, periodID: String) throws {
        guard PlanningDate.date(date).map(PlanningDate.key) == date, ["morning", "noon", "evening", "unassigned"].contains(periodID),
              let task = tasks.first(where: { $0.id == taskID }), !task.cancelled, !task.isCompleted else { throw TaskLinkageError.changed }
        for i in assignments.indices where assignments[i].taskID == taskID { assignments[i].active = false }
        // Distinct logical tasks may have identical titles in the same target period.
        let occurrence = assignments.filter { a in a.active && a.date == date && a.periodID == periodID && tasks.first(where: { $0.id == a.taskID })?.text == task.text }.count + 1
        assignments.append(TaskAssignment(id: UUID().uuidString, taskID: taskID, date: date, periodID: periodID,
            legacyTaskID: PeriodCompletion.taskKey(for: task.text, occurrence: occurrence)))
    }
    public mutating func removeAssignment(_ id: String) throws {
        guard let i = assignments.firstIndex(where: { $0.id == id }) else { throw TaskLinkageError.changed }
        assignments[i].active = false
    }
    public mutating func cancel(_ id: String) throws {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { throw TaskLinkageError.changed }
        tasks[i].cancelled = true
        if let parent = tasks[i].deliveryID, let p = deliveries.firstIndex(where: { $0.id == parent }) {
            if children(of: parent).isEmpty && deliveries[p].carried { deliveries[p].cancelled = true }
            else if !children(of: parent).isEmpty { deliveries[p].completedAt = children(of: parent).allSatisfy(\.isCompleted) ? PlanningDate.key(.now) : nil }
        }
    }
    public mutating func rename(_ id: String, text: String) throws {
        guard let i = tasks.firstIndex(where: { $0.id == id }), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TaskLinkageError.changed }
        tasks[i].text = text
        tasks[i].dueAt = Self.deadline(text, date: tasks[i].originDate)
        if let parent = tasks[i].deliveryID, let d = deliveries.firstIndex(where: { $0.id == parent && $0.carried }) { deliveries[d].text = text }
    }
    public mutating func cancelDelivery(_ id: String) throws {
        guard let i = deliveries.firstIndex(where: { $0.id == id }) else { throw TaskLinkageError.changed }
        for task in children(of: id) { try cancel(task.id) }
        deliveries[i].cancelled = true
    }
    public mutating func classify(_ id: String, as category: PlanningCategory) throws {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { throw TaskLinkageError.changed }
        tasks[i].category = category
    }
    private static func deadline(_ text: String, date: String) -> String? {
        guard text.contains("截止") || text.contains("前交") || text.contains("前提") else { return nil }
        guard let r = text.range(of: #"[0-2]?[0-9]:[0-5][0-9]"#, options: .regularExpression), let minutes = OneOffSchedule.minutes(String(text[r])) else { return nil }
        return date + String(format: "T%02d:%02d:00+08:00", minutes / 60, minutes % 60)
    }
    public func validated() throws -> Self {
        guard version == 1, PlanningDate.date(activationDate).map(PlanningDate.key) == activationDate,
              Set(tasks.map(\.id)).count == tasks.count, Set(assignments.map(\.id)).count == assignments.count,
              Set(deliveries.map(\.id)).count == deliveries.count,
              tasks.allSatisfy({ t in t.deliveryID == nil || deliveries.contains(where: { $0.id == t.deliveryID }) }),
              tasks.allSatisfy({ t in t.reminderForTaskID == nil || tasks.contains(where: { $0.id == t.reminderForTaskID && $0.id != t.id && $0.reminderForTaskID == nil }) }),
              tasks.allSatisfy({ !$0.id.isEmpty && PlanningDate.date($0.originDate).map(PlanningDate.key) == $0.originDate }),
              deliveries.allSatisfy({ !$0.id.isEmpty }),
              assignments.allSatisfy({ a in !a.id.isEmpty && ["morning", "noon", "evening", "unassigned"].contains(a.periodID) && tasks.contains(where: { $0.id == a.taskID }) && PlanningDate.date(a.date).map(PlanningDate.key) == a.date }),
              Set(assignments.filter(\.active).map(\.taskID)).count == assignments.filter(\.active).count,
              Set(assignments.filter(\.active).map { "\($0.date)|\($0.periodID)|\($0.legacyTaskID)" }).count == assignments.filter(\.active).count else { throw TaskLinkageError.malformed }
        return self
    }
}

extension WeeklyPlanSnapshot {
    public func planningRows(now: Date = .now) -> [(String, [PeriodSnapshot], String)] {
        let rows = days.map { ($0.dateLabel, $0.slots, $0.unassigned) }
            + historicalRows.map { ($0.dateLabel, $0.slots, $0.unassigned) }
            + futureRows.map { ($0.dateLabel, $0.slots, $0.unassigned) }
        return rows.compactMap { row in PlanningDate.date(row.0, relativeTo: now).map { (PlanningDate.key($0), row.1, row.2) } }
    }
}

public enum TaskLinkageMarkdown {
    public static let start = "<!-- studyrocket:task-links:start -->"
    public static let end = "<!-- studyrocket:task-links:end -->"
    public static func read(_ source: String) throws -> TaskLinkage? {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let starts = lines.indices.filter { lines[$0] == start }, ends = lines.indices.filter { lines[$0] == end }
        if starts.isEmpty && ends.isEmpty { return nil }
        guard starts.count == 1, ends.count == 1, let a = starts.first, let b = ends.first, a < b,
              lines[a + 1] == "```json", lines[b - 1] == "```" else { throw TaskLinkageError.malformed }
        let data = Data(lines[(a + 2)..<(b - 1)].joined(separator: "\n").utf8)
        do { return try JSONDecoder().decode(TaskLinkage.self, from: data).validated() } catch { throw TaskLinkageError.malformed }
    }
    public static func write(_ graph: TaskLinkage, in source: String) throws -> String {
        _ = try graph.validated()
        _ = try read(source)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(graph), as: UTF8.self)
        let block = [start, "```json", json, "```", end].joined(separator: "\n")
        if let a = source.range(of: start), let b = source.range(of: end), a.lowerBound < b.lowerBound {
            return source.replacingCharacters(in: a.lowerBound..<b.upperBound, with: block)
        }
        return source + (source.hasSuffix("\n") ? "\n" : "\n\n") + block + "\n"
    }
}

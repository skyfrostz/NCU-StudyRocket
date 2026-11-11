import Foundation
import StudyRocketShared

func runTaskLinkageChecks() throws {
    func date(_ s: String) -> Date { PlanningDate.date(s)! }
    func plan(_ text: String, date: String = "2026-11-10", deliveries: [DeliverySnapshot] = []) -> WeeklyPlanSnapshot {
        WeeklyPlanSnapshot(days: [DaySnapshot(id: date, dateLabel: date, slots: [PeriodSnapshot(id: "morning", title: "上午", text: text), PeriodSnapshot(id: "noon", title: "中午", text: ""), PeriodSnapshot(id: "evening", title: "晚上", text: "")])], bufferRules: [], deliveries: deliveries)
    }
    let original = plan("完成高数作业14\n帮老师整理数据")
    let day0 = date("2026-11-10"), day1 = date("2026-11-11")
    let graph = TaskLinkage(activationDate: "2026-11-10").reconciled(with: original, now: day0)
    precondition(graph.tasks.count == 2 && graph.deliveries.isEmpty)
    let rolled = graph.projected(original, now: day1)
    precondition(rolled.deliveries.count == 2)
    precondition(rolled.linkage!.projected(rolled, now: day1).deliveries.count == 2)
    var moved = rolled.linkage!
    let task = moved.tasks[0], root = task.deliveryID!
    try moved.reschedule(task.id, date: "2026-11-13", periodID: "evening")
    let scheduled = moved.projected(original, now: day1)
    precondition(scheduled.days[0].slots[0].tasks.count == 1)
    precondition(scheduled.futureRows.first?.slots.last?.tasks.first?.logicalTaskID == task.id)
    precondition(moved.assignments.contains { !$0.active && $0.taskID == task.id && $0.date == "2026-11-10" })
    try moved.setTask(task.id, completed: true, now: date("2026-11-13"))
    precondition(moved.deliveries.first(where: { $0.id == root }).map(moved.isCompleted) == true)
    precondition(moved.projected(scheduled, now: date("2026-11-16")).deliveries.allSatisfy { $0.id != root })
    precondition(moved.projected(scheduled, now: date("2026-12-01")).deliveries.contains { !$0.isCompleted })

    let old = plan("旧高数作业", date: "2026-11-09")
    precondition(TaskLinkage(activationDate: "2026-11-10").projected(old, now: day1).deliveries.isEmpty)
    let parent = DeliverySnapshot(id: UUID().uuidString, text: "完成两节课复习", isCompleted: false)
    var grouped = TaskLinkage(activationDate: "2026-11-10").reconciled(with: plan("复习第1节\n复习第2节", deliveries: [parent]), now: day0)
    for child in grouped.tasks { try grouped.link(child.id, to: parent.id) }
    let ids = grouped.tasks.map(\.id)
    try grouped.setTask(ids[0], completed: true, now: day0)
    precondition(!grouped.isCompleted(grouped.deliveries[0]))
    do { try grouped.setDelivery(parent.id, completed: true, confirmedTaskIDs: [], now: day0); preconditionFailure("bulk confirmation missing") }
    catch TaskLinkageError.confirmationRequired { }
    try grouped.setDelivery(parent.id, completed: true, confirmedTaskIDs: [ids[1]], now: day0)
    precondition(grouped.isCompleted(grouped.deliveries[0]))
    try grouped.setDelivery(parent.id, completed: false, now: day1)
    precondition(grouped.tasks[0].isCompleted && !grouped.tasks[1].isCompleted)
    try grouped.cancel(ids[1]); precondition(grouped.isCompleted(grouped.deliveries[0]))

    var renamed = graph
    try renamed.rename(task.id, text: "完成高数作业14并检查")
    let renameProjection = renamed.projected(original, now: day0)
    let reparsed = plan(renameProjection.days[0].slots[0].text)
    let afterRestart = renameProjection.linkage!.projected(reparsed, now: day1)
    precondition(afterRestart.linkage!.tasks.count == 2 && afterRestart.linkage!.tasks[0].id == task.id)
    let repeated = WeeklyPlanSnapshot(days: original.days + plan("完成高数作业14", date: "2026-11-11").days, bufferRules: [], deliveries: [])
    let distinct = TaskLinkage(activationDate: "2026-11-10").reconciled(with: repeated, now: day1)
    precondition(Set(distinct.tasks.map(\.id)).count == 3)
    let samePeriod = TaskLinkage(activationDate: "2026-11-10").reconciled(with: plan("高数作业\n高数作业"), now: day0)
    precondition(samePeriod.tasks.count == 2 && samePeriod.assignments.count == 2)
    var returned = graph
    try returned.reschedule(task.id, date: "2026-11-12", periodID: "noon")
    try returned.reschedule(task.id, date: "2026-11-10", periodID: "morning")
    precondition(returned.projected(original, now: day0).days[0].slots[0].tasks.filter { $0.logicalTaskID == task.id }.count == 1)
    var cancelledCarry = rolled.linkage!
    try cancelledCarry.cancel(task.id)
    precondition(!cancelledCarry.projected(original, now: day1).deliveries.contains { $0.id == root })
    var reminders = TaskLinkage(activationDate: "2026-11-10").reconciled(with: plan("高数作业\n高数作业原截止23:00"), now: day0)
    try reminders.setReminder(reminders.tasks[1].id, for: reminders.tasks[0].id)
    try reminders.setTask(reminders.tasks[0].id, completed: true, now: day1)
    precondition(reminders.tasks.allSatisfy(\.isCompleted))
    try reminders.setTask(reminders.tasks[0].id, completed: false, now: day1)
    precondition(reminders.tasks.allSatisfy { !$0.isCompleted })
    precondition(reminders.projected(plan("高数作业\n高数作业原截止23:00"), now: day1).deliveries.count == 1)
    let encoded = try TaskLinkageMarkdown.write(moved, in: "# 原有说明\n")
    let decoded = try TaskLinkageMarkdown.read(encoded)
    precondition(encoded.hasPrefix("# 原有说明\n") && decoded == moved)
    do { _ = try TaskLinkageMarkdown.read(encoded + TaskLinkageMarkdown.start); preconditionFailure("duplicate boundary accepted") }
    catch TaskLinkageError.malformed { }
    precondition(PlanningCategory.infer("23:00 前交作业") == .study)
    precondition(PlanningCategory.infer("14:00–16:00 帮老师整理数据").carriesForward)
    precondition(PlanningCategory.infer("19:00 羽毛球训练") == .event)
    precondition(PlanningCategory.infer("整理资料") == .unclassified)
    precondition(PlanningCategory.infer("模型训练") == .research)
    precondition(PlanningCategory.infer("高数作业原截止23:00") == .unclassified)
    precondition(PlanningDate.date("2026-02-30") == nil)

    let event = OneOffEvent(date: "2026-11-10", start: "19:00", end: "21:00", title: "羽毛球训练", location: "体育馆")
    let eventsSource = try OneOffSchedule.write([event], in: "# 原课表\n")
    let readEvents = try OneOffSchedule.read(eventsSource)
    precondition(readEvents == [event])
    let conflictSource = try OneOffSchedule.write([event, OneOffEvent(date: event.date, start: "20:00", title: "参加会议")], in: "# 课表")
    precondition(StudyRocketTimetableParser.snapshot(from: conflictSource, now: day0).days.flatMap(\.entries).allSatisfy { $0.note?.contains("⚠️") == true })
    let snapshot = StudyRocketTimetableParser.snapshot(from: eventsSource, now: day0)
    precondition(snapshot.status == .available && snapshot.teachingWeek == nil)
    precondition(snapshot.days.flatMap(\.entries).count == 1)
    precondition(snapshot.days.first(where: { $0.id == "2026-11-10" })?.entries.first?.title == event.title)
    precondition(StudyRocketTimetableParser.snapshot(from: eventsSource, now: date("2026-11-17")).days.flatMap(\.entries).isEmpty)
    var edited = event; edited.start = "20:00"; edited.end = nil
    let editedSource = try OneOffSchedule.write([edited], in: eventsSource)
    let readEdited = try OneOffSchedule.read(editedSource)
    precondition(readEdited.first?.id == event.id)
    do { _ = try OneOffSchedule.write([OneOffEvent(date: event.date, start: "25:00", title: "无效")], in: eventsSource); preconditionFailure("bad time accepted") }
    catch TaskLinkageError.malformed { }
    let routingSource = """
    <!-- studyrocket:weekly:start -->
    | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
    | --- | --- | --- | --- | --- | --- |
    | 2026-11-10 | 14:00-16:00 帮老师整理数据 | | 19:00-21:00 羽毛球训练<br>23:00 前交作业 | | [ ] |
    <!-- studyrocket:weekly:end -->
    """
    let routing = try PlanningChangeRouter.route(week: routingSource, original: routingSource, timetable: "# 课表", now: day0)
    precondition(routing.week.contains("帮老师整理数据") && routing.week.contains("23:00 前交作业") && !routing.week.contains("羽毛球训练"))
    let routedEvents = try OneOffSchedule.read(routing.timetable!)
    precondition(routedEvents.count == 1 && routedEvents[0].start == "19:00" && routedEvents[0].end == "21:00")
    let rerouted = try PlanningChangeRouter.route(week: routingSource, original: routingSource, timetable: routing.timetable!, now: day0)
    precondition(rerouted.timetable == nil)
    do { _ = try PlanningChangeRouter.route(week: routingSource.replacingOccurrences(of: "19:00-21:00 ", with: ""), original: routingSource, timetable: "# 课表", now: day0); preconditionFailure("missing activity time accepted") }
    catch is PlanningChangeRouter.RoutingError { }
    print("Task linkage checks passed: carryover, reschedule, cascade/undo, identities, migration, categories and one-off events")
}

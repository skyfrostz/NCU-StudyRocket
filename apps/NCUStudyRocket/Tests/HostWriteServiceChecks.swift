import Foundation
import StudyRocketShared

@main
struct HostWriteServiceChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("studyrocket-host-write-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("工作台", isDirectory: true),
            withIntermediateDirectories: true
        )

        let label = shortDateLabel(Date())
        let planFile = root.appendingPathComponent("工作台/下周计划.md")
        let source = """
        # 临时计划

        <!-- studyrocket:weekly:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        |------|------|------|------|----------|------|
        | \(label) | 原上午 | 原中午 | 原晚上 |  | [ ] |
        <!-- studyrocket:weekly:end -->

        ## 交付物清单
        - [ ] 原交付物

        ## 缓冲
        - 原缓冲

        ## 保留说明
        此段不属于移动端管理范围。
        """
        try Data(source.utf8).write(to: planFile)

        let builder = HostSnapshotBuilder(root: root)
        let initial = builder.build()
        guard var day = initial.week.days.first else { fatalError("missing current day") }
        day = DaySnapshot(
            id: day.id,
            dateLabel: day.dateLabel,
            slots: [
                PeriodSnapshot(id: "morning", title: "上午", text: "移动端上午计划"),
                PeriodSnapshot(id: "noon", title: "中午", text: "移动端中午计划"),
                PeriodSnapshot(id: "evening", title: "晚上", text: "移动端晚上计划")
            ]
        )
        let updatedDays = [day] + initial.week.days.dropFirst()
        let delivery = DeliverySnapshot(
            id: "delivery-1",
            text: "\(label)：已完成的移动端交付物\n附加验收条件",
            isCompleted: true,
            dateLabel: label
        )
        let buffer = BufferRuleSnapshot(
            id: "buffer-1",
            category: "collision",
            text: "发生撞车时保核心任务\n停止额外扩展"
        )
        let request = PlanWriteRequest(
            plan: WeeklyPlanSnapshot(
                days: updatedDays,
                bufferRules: [buffer],
                deliveries: [delivery],
                historicalRows: initial.week.historicalRows,
                futureRows: initial.week.futureRows
            ),
            metadata: WriteMetadata(baseRevision: initial.revision, idempotencyKey: "host-write-check")
        )

        let service = HostWriteService(root: root)
        let applied = try service.applyWeek(request)
        let written = try String(contentsOf: planFile, encoding: .utf8)
        try require(written.contains("移动端上午计划"), "schedule was not persisted")
        try require(written.contains("<!-- studyrocket:deliveries:start -->"), "delivery boundary missing")
        try require(written.contains("- [x] \(label)：已完成的移动端交付物\n  附加验收条件"), "multiline delivery or completion state was lost")
        try require(written.contains("<!-- studyrocket:buffer:start -->"), "buffer boundary missing")
        try require(written.contains("### 撞车降级\n- 发生撞车时保核心任务\n  停止额外扩展"), "multiline buffer rule was not persisted")
        try require(written.contains("此段不属于移动端管理范围。"), "unmanaged text changed")
        try require(written.contains("<!-- studyrocket:weekly:end -->\n<!-- studyrocket:period-completion:start -->"), "period completion block is not immediately after weekly:end")

        guard let appliedDay = applied.week.days.first,
              let appliedMorning = appliedDay.slots.first(where: { $0.id == "morning" }) else {
            fatalError("missing current morning period")
        }
        let morningHash = PeriodCompletion.textHash(for: appliedMorning.text)
        let toggleRequest = PeriodCompletionToggleRequest(
            dayID: appliedDay.id,
            periodID: appliedMorning.id,
            textHash: morningHash,
            isCompleted: true,
            metadata: WriteMetadata(baseRevision: applied.revision, idempotencyKey: "period-toggle-on")
        )
        let completed = try service.togglePeriod(toggleRequest)
        try require(completed.home.periods.first(where: { $0.id == "morning" })?.isCompleted == true, "completed period was not reflected in snapshot")
        try require(completed.home.firstOpenTask == "移动端中午计划", "first open task did not skip completed morning period")
        let completedSource = try String(contentsOf: planFile, encoding: .utf8)
        let completionBody = try managedCompletionBody(completedSource)
        try require(completionBody.contains("| \(appliedDay.id) | morning | \(morningHash) | [x] |"), "completed period row was not persisted")
        try require(completionBody.components(separatedBy: .newlines).filter { $0.hasPrefix("| \(appliedDay.id) |") }.count == 1, "completion block contains duplicate rows")
        try require(!completionBody.contains("[ ]"), "incomplete rows must not be persisted")

        let replayed = try service.togglePeriod(toggleRequest)
        try require(replayed == completed, "idempotent period toggle did not replay its original response")
        try require(try String(contentsOf: planFile, encoding: .utf8) == completedSource, "idempotent period toggle rewrote Markdown")

        let externallyEdited = completedSource.replacingOccurrences(of: "移动端上午计划", with: "外部改写上午")
        try Data(externallyEdited.utf8).write(to: planFile, options: .atomic)
        let stale = builder.build()
        try require(stale.home.periods.first(where: { $0.id == "morning" })?.isCompleted == false, "stale text hash incorrectly completed changed content")
        try require(stale.home.firstOpenTask == "外部改写上午", "stale completion incorrectly hid the first open task")

        guard let staleDay = stale.week.days.first else { fatalError("missing stale day") }
        var rewrittenSlots = staleDay.slots
        rewrittenSlots[0] = PeriodSnapshot(id: "morning", title: "上午", text: "重写后上午")
        let rewrittenDay = DaySnapshot(id: staleDay.id, dateLabel: staleDay.dateLabel, slots: rewrittenSlots, unassigned: staleDay.unassigned)
        let pruneRequest = PlanWriteRequest(
            plan: WeeklyPlanSnapshot(
                days: [rewrittenDay] + stale.week.days.dropFirst(),
                bufferRules: stale.week.bufferRules,
                deliveries: stale.week.deliveries,
                historicalRows: stale.week.historicalRows,
                futureRows: stale.week.futureRows
            ),
            metadata: WriteMetadata(baseRevision: stale.revision, idempotencyKey: "period-prune")
        )
        let pruned = try service.applyWeek(pruneRequest)
        let prunedSource = try String(contentsOf: planFile, encoding: .utf8)
        try require(!prunedSource.contains(morningHash), "applyWeek did not prune stale period completion")
        try require(pruned.home.periods.first(where: { $0.id == "morning" })?.isCompleted == false, "rewritten period inherited stale completion")

        guard let rewrittenMorning = pruned.home.periods.first(where: { $0.id == "morning" }) else { fatalError("missing rewritten morning") }
        let rewrittenHash = PeriodCompletion.textHash(for: rewrittenMorning.text)
        let checked = try service.togglePeriod(PeriodCompletionToggleRequest(
            dayID: staleDay.id,
            periodID: "morning",
            textHash: rewrittenHash,
            isCompleted: true,
            metadata: WriteMetadata(baseRevision: pruned.revision, idempotencyKey: "period-recheck")
        ))
        let unchecked = try service.togglePeriod(PeriodCompletionToggleRequest(
            dayID: staleDay.id,
            periodID: "morning",
            textHash: rewrittenHash,
            isCompleted: false,
            metadata: WriteMetadata(baseRevision: checked.revision, idempotencyKey: "period-toggle-off")
        ))
        try require(unchecked.home.periods.first(where: { $0.id == "morning" })?.isCompleted == false, "period toggle off was not reflected in snapshot")
        try require(!(try managedCompletionBody(String(contentsOf: planFile, encoding: .utf8))).contains("| \(staleDay.id) | morning |"), "unchecked period row remained persisted")
        try require((try String(contentsOf: planFile, encoding: .utf8)).contains("此段不属于移动端管理范围。"), "period writes changed unmanaged Markdown")
        print("HostWriteServiceChecks: plan writes and period completion lifecycle passed")
    }

    private static func shortDateLabel(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
    }

    private static func managedCompletionBody(_ source: String) throws -> String {
        guard let start = source.range(of: "<!-- studyrocket:period-completion:start -->"),
              let end = source.range(of: "<!-- studyrocket:period-completion:end -->", range: start.upperBound..<source.endIndex) else {
            throw NSError(domain: "HostWriteServiceChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "period completion block missing"])
        }
        return String(source[start.upperBound..<end.lowerBound])
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "HostWriteServiceChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}

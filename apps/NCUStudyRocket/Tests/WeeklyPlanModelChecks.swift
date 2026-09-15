#if STUDYROCKET_MODEL_TESTS
import Foundation
import StudyRocketShared

@main
struct WeeklyPlanModelChecks {
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    static func main() throws {
        var calendar = MarkdownParser.studyCalendar
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13))!
        let legacyDated = """
        # 下周计划

        前置内容保持不变

        <!-- studyrocket:weekly:start -->

        | 日期 | 计划 |
        |------|------|
        | 8 月 13 日 | [ ] 上午一；上午二；中午一；中午二；晚上一 |
        | 8 月 14 日 | [x] 无法安全拆分 |
        <!-- studyrocket:weekly:end -->

        ## 交付物清单
        - [ ] 8 月 13 日：今日任务
        - [x] 8 月 14 日：明日任务
        - [ ] 无日期任务

        ## 外部说明
        边界外必须逐字保留
        """
        let migrated = MarkdownParser.weekly(legacyDated, referenceDate: today)
        check(migrated.format == .timeGrid, "legacy dated rows present as a time grid")
        check(migrated.isMigratedPreview, "migration preview is exposed")
        check(migrated.migrationNotice != nil, "migration notice is exposed")
        check(migrated.dayDateLabels.count == 7 && migrated.cells.allSatisfy { $0.count == 7 }, "week is always seven days by three periods")
        check(migrated.cells[0][0] == "上午一；上午二", "legacy text is evenly split into morning")
        check(migrated.cells[1][0] == "中午一；中午二", "legacy text is evenly split into noon")
        check(migrated.cells[2][0] == "晚上一", "legacy text is evenly split into evening")
        check(migrated.unassignedByDay[1] == "无法安全拆分", "unsafe legacy text remains unassigned")
        check(migrated.dayCompletion[1], "legacy completion state is retained")
        check(migrated.datedRows.map(\.text) == ["上午一；上午二；中午一；中午二；晚上一", "无法安全拆分"], "legacy source text remains available")

        let upgraded = MarkdownParser.replaceWeekly(legacyDated, with: migrated)
        check(upgraded.contains("| 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |"), "save upgrades to structured week table")
        check(upgraded.contains("| 8 月 14 日 |  |  |  | 无法安全拆分 | [x] |"), "unassigned text and completion round trip")
        check(upgraded.hasPrefix("# 下周计划\n\n前置内容保持不变"), "content before managed boundary is unchanged")
        check(upgraded.hasSuffix("## 外部说明\n边界外必须逐字保留"), "content after managed boundary is unchanged")
        let reparsed = MarkdownParser.weekly(upgraded, referenceDate: today)
        check(reparsed.cells == migrated.cells, "structured cells round trip")
        check(reparsed.unassignedByDay == migrated.unassignedByDay, "unassigned rows round trip")
        check(reparsed.dayCompletion == migrated.dayCompletion, "day completion round trip")

        let completedMorning = try MarkdownParser.replacePeriodCompletion(
            in: upgraded,
            dayID: "2026-08-13",
            periodID: "morning",
            text: migrated.cells[0][0],
            isCompleted: true
        )
        let completedPlan = MarkdownParser.weekly(completedMorning, referenceDate: today)
        check(completedPlan.periodCompletion[0][0], "period completion round trips through the managed status block")
        var changedPlan = completedPlan
        changedPlan.cells[0][0] = "正文已变化"
        let changedSource = MarkdownParser.replaceWeekly(completedMorning, with: changedPlan)
        let changedParsed = MarkdownParser.weekly(changedSource, referenceDate: today)
        check(!changedParsed.periodCompletion[0][0], "editing a period body resets its completion state")
        check(!changedSource.contains("| 2026-08-13 | morning |"), "stale completion hashes are pruned on save")

        let linkedDeliveryText = "8 月 13 日：完成第 3 章网课并跟学例题"
        let linkedPeriodText = "第 3 章：继续网课并跟学例题"
        let linkSource = """
        <!-- studyrocket:weekly:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        |------|------|------|------|----------|------|
        | 8 月 13 日 | \(linkedPeriodText) |  |  |  | [ ] |
        <!-- studyrocket:weekly:end -->

        ## 交付物清单
        - [ ] \(linkedDeliveryText)

        ## 缓冲
        - 原缓冲
        """
        let manualLinkSource = try MarkdownParser.replacePeriodCompletion(
            in: linkSource,
            dayID: "2026-08-13",
            periodID: "morning",
            text: linkedPeriodText,
            isCompleted: true
        )
        var linkedPlan = MarkdownParser.weekly(manualLinkSource, referenceDate: today)
        let linkedDelivery = linkedPlan.deliveries[0]
        linkedPlan.deliveries[0].isCompleted = true
        let linkedSource = try MarkdownParser.replaceDeliveryCompletion(
            in: manualLinkSource,
            with: linkedPlan,
            delivery: linkedDelivery,
            isCompleted: true
        )
        let linkedSourceKey = DeliveryPeriodMatcher.sourceKey(for: linkedDeliveryText)
        check(linkedSource.contains(linkedSourceKey), "desktop delivery completion writes a delivery source")
        check(linkedSource.contains("| 2026-08-13 | morning | \(PeriodCompletion.textHash(for: linkedPeriodText)) | [x] |  |"), "desktop delivery link preserves an existing manual source")
        var unlinkedPlan = MarkdownParser.weekly(linkedSource, referenceDate: today)
        let completedLinkedDelivery = unlinkedPlan.deliveries[0]
        unlinkedPlan.deliveries[0].isCompleted = false
        let unlinkedSource = try MarkdownParser.replaceDeliveryCompletion(
            in: linkedSource,
            with: unlinkedPlan,
            delivery: completedLinkedDelivery,
            isCompleted: false
        )
        check(!unlinkedSource.contains(linkedSourceKey), "desktop delivery cancellation removes only its source")
        check(MarkdownParser.weekly(unlinkedSource, referenceDate: today).periodCompletion[0][0], "manual period completion survives delivery cancellation")

        var renamedPlan = MarkdownParser.weekly(linkedSource, referenceDate: today)
        let renamedDeliveryText = "8 月 13 日：完成第 3 章网课并跟学例题，整理一页总结"
        renamedPlan.deliveries[0].text = renamedDeliveryText
        let renamedSource = MarkdownParser.replaceWeekly(
            linkedSource,
            with: renamedPlan,
            deliverySourceMigrations: [linkedSourceKey: DeliveryPeriodMatcher.sourceKey(for: renamedDeliveryText)]
        )
        check(!renamedSource.contains(linkedSourceKey), "desktop delivery rename removes the previous source key")
        check(renamedSource.contains(DeliveryPeriodMatcher.sourceKey(for: renamedDeliveryText)), "desktop delivery rename migrates its source key")

        let historicalText = "历史任务"
        let futureText = "未来任务"
        let archivedSource = """
        <!-- studyrocket:weekly:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        |------|------|------|------|----------|------|
        | 8 月 13 日 | 当前任务 |  |  |  | [ ] |
        <!-- studyrocket:weekly:history:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        |------|------|------|------|----------|------|
        | 8 月 12 日 | \(historicalText) |  |  |  | [ ] |
        <!-- studyrocket:weekly:history:end -->
        <!-- studyrocket:weekly:future:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        |------|------|------|------|----------|------|
        | 8 月 21 日 | \(futureText) |  |  |  | [ ] |
        <!-- studyrocket:weekly:future:end -->
        <!-- studyrocket:weekly:end -->
        <!-- studyrocket:period-completion:start -->
        | 日期 | 时段 | 正文 SHA-256 | 完成 |
        |------|------|-------------|------|
        | 2026-08-12 | morning | \(PeriodCompletion.textHash(for: historicalText)) | [x] |
        | 2026-08-21 | morning | \(PeriodCompletion.textHash(for: futureText)) | [x] |
        <!-- studyrocket:period-completion:end -->
        """
        let archivedPlan = MarkdownParser.weekly(archivedSource, referenceDate: today)
        let archivedRoundTrip = MarkdownParser.replaceWeekly(archivedSource, with: archivedPlan)
        check(archivedRoundTrip.contains("| 2026-08-12 | morning | \(PeriodCompletion.textHash(for: historicalText)) | [x] |"), "desktop save preserves historical period completion")
        check(archivedRoundTrip.contains("| 2026-08-21 | morning | \(PeriodCompletion.textHash(for: futureText)) | [x] |"), "desktop save preserves future period completion")

        let legacyBuffer = """
        ## 缓冲
        - 每天保留 90 分钟弹性
        - 若课程撞车，只保课堂与当日唯一交付物
        - 若全崩，只保最重要的一件事

        ## 外部说明
        不参与缓冲迁移
        """
        var bufferPlan = MarkdownParser.weekly(legacyBuffer, referenceDate: today)
        check(bufferPlan.bufferRules.map(\.category) == [.daily, .collision, .minimum], "flat buffer rules are classified in memory")
        bufferPlan.bufferRules[0].text = "每天保留 90 分钟弹性\n不占用固定课程"
        let structuredBuffer = MarkdownParser.replaceWeekly(legacyBuffer, with: bufferPlan)
        check(structuredBuffer.contains("<!-- studyrocket:buffer:start -->") && structuredBuffer.contains("### 日常缓冲") && structuredBuffer.contains("### 撞车降级") && structuredBuffer.contains("### 最低底线"), "buffer gets managed category boundaries on save")
        check(structuredBuffer.contains("- 每天保留 90 分钟弹性\n  不占用固定课程"), "multiline buffer rule round trips")
        check(structuredBuffer.contains("## 外部说明\n不参与缓冲迁移"), "buffer migration preserves later unmanaged content")
        let reparsedBuffer = MarkdownParser.weekly(structuredBuffer, referenceDate: today)
        check(reparsedBuffer.bufferRules.count == 3 && reparsedBuffer.bufferRules[0].text.contains("不占用固定课程"), "structured buffer rules reparse")

        let legacyGrid = """
        <!-- studyrocket:weekly:start -->
        | 时段 | 周一 | 周二 | 周三 | 周四 | 周五 | 周六 | 周日 |
        |------|------|------|------|------|------|------|------|
        | 上午 | A | | | | | | |
        | 下午 | B | | | | | | |
        | 晚上 | C | | | | | | |
        <!-- studyrocket:weekly:end -->
        """
        let legacyGridPlan = MarkdownParser.weekly(legacyGrid, referenceDate: today)
        check(WeeklyPlan.periods == ["上午", "中午", "晚上"], "period labels use morning noon evening")
        check(legacyGridPlan.historicalRows.first?.slots[1] == "B", "legacy afternoon remains preserved in historical rows")

        let visible = migrated.deliveriesExcluding(today, calendar: calendar)
        check(visible.map(\.text) == ["8 月 14 日：明日任务", "无日期任务"], "dashboard deliveries exclude only explicitly dated today items")
        check(visible.filter(\.isCompleted).count == 1, "filtered completion count uses visible deliveries")

        let datedPresentation = WeeklyDeliveryPresentation(text: "8 月 13 日：完成微分代表题", reference: today)
        check(datedPresentation.dateLabel != nil && datedPresentation.body == "完成微分代表题", "dated delivery display keeps a date label and hides only its visual prefix")
        let plainPresentation = WeeklyDeliveryPresentation(text: "整理错题本", reference: today)
        check(plainPresentation.dateLabel == nil && plainPresentation.body == "整理错题本", "undated delivery display preserves its text")
        let crossYearReference = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31))!
        let crossYearPresentation = WeeklyDeliveryPresentation(text: "1 月 1 日：建立新年学习清单", reference: crossYearReference)
        check(crossYearPresentation.dateLabel != nil && crossYearPresentation.body == "建立新年学习清单", "cross-year delivery date display is resolved safely")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StudyRocketWeeklyModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("工作台"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(upgraded.utf8).write(to: root.appendingPathComponent("工作台/下周计划.md"), options: .atomic)
        let dashboard = DashboardModel()
        dashboard.load(from: root, referenceDate: today)
        let todayCells = dashboard.todayCells(on: today)
        check(todayCells.count == 3 && todayCells.map(\.period) == ["上午", "中午", "晚上"], "dashboard always exposes three periods")
        check(todayCells.map(\.task) == ["上午一；上午二", "中午一；中午二", "晚上一"], "dashboard resolves the selected day slots")
        check(dashboard.firstOpenTask == nil || !dashboard.firstOpenTask!.contains("明日任务"), "first task never falls back to weekly deliveries")

        let multiTaskText = "20:00 邮件系统英方培训\n问李训灏：专业考勤系统选用问题"
        let multiTaskSource = """
        <!-- studyrocket:weekly:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        |------|------|------|------|----------|------|
        | 8 月 13 日 |  |  | \(multiTaskText.replacingOccurrences(of: "\n", with: "<br>")) |  | [ ] |
        <!-- studyrocket:weekly:end -->

        ## 交付物清单
        - [ ] 8 月 13 日：邮件系统英方培训
        """
        let multiPlan = MarkdownParser.weekly(multiTaskSource, referenceDate: today)
        let eveningTasks = PeriodTaskParser.tasks(from: multiPlan.cells[2][0])
        check(eveningTasks.count == 2, "a period with two lines is split into two independent tasks")

        let promotedSource = """
        <!-- studyrocket:weekly:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        |------|------|------|------|----------|------|
        | 8 月 13 日 | 08:30 见面会 | 12:00 大扫除 |  | - [ ] 14:00 领取 Bar Code<br>- [ ] 16:00 领取银行卡<br>地点待确认 | [ ] |
        <!-- studyrocket:weekly:end -->
        """
        let promotedPlan = MarkdownParser.weekly(promotedSource, referenceDate: today)
        check(
            PeriodTaskParser.tasks(from: promotedPlan.cells[1][0]).map(\.text)
                == ["12:00 大扫除", "14:00 领取 Bar Code", "16:00 领取银行卡"],
            "desktop parser promotes timed unassigned items into independent noon tasks"
        )
        check(promotedPlan.unassignedByDay[0] == "地点待确认", "desktop parser keeps only unresolved text unassigned")

        let legacyCompletedMulti = try MarkdownParser.replacePeriodCompletion(
            in: multiTaskSource,
            dayID: "2026-08-13",
            periodID: "evening",
            text: multiPlan.cells[2][0],
            isCompleted: true
        )
        check(MarkdownParser.weekly(legacyCompletedMulti, referenceDate: today).periodCompletion[2][0], "legacy whole-period records complete every child task")

        let independentlyUpdated = try MarkdownParser.replacePeriodTaskCompletion(
            in: legacyCompletedMulti,
            dayID: "2026-08-13",
            periodID: "evening",
            periodText: multiPlan.cells[2][0],
            taskID: eveningTasks[0].id,
            isCompleted: false
        )
        let multiRoot = FileManager.default.temporaryDirectory.appendingPathComponent("StudyRocketWeeklyTasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: multiRoot.appendingPathComponent("工作台"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: multiRoot) }
        try Data(independentlyUpdated.utf8).write(to: multiRoot.appendingPathComponent("工作台/下周计划.md"), options: .atomic)
        let taskDashboard = DashboardModel()
        taskDashboard.load(from: multiRoot, referenceDate: today)
        let eveningCells = taskDashboard.todayCells(on: today).filter { $0.periodID == "evening" }
        check(eveningCells.count == 2, "desktop today panel renders one row for each child task")
        check(!eveningCells[0].isCompleted && eveningCells[1].isCompleted, "desktop task completion is independent after legacy migration")

        var deliveryMultiPlan = MarkdownParser.weekly(multiTaskSource, referenceDate: today)
        let delivery = deliveryMultiPlan.deliveries[0]
        deliveryMultiPlan.deliveries[0].isCompleted = true
        let deliveryUpdated = try MarkdownParser.replaceDeliveryCompletion(
            in: multiTaskSource,
            with: deliveryMultiPlan,
            delivery: delivery,
            isCompleted: true
        )
        try Data(deliveryUpdated.utf8).write(to: multiRoot.appendingPathComponent("工作台/下周计划.md"), options: .atomic)
        taskDashboard.load(from: multiRoot, referenceDate: today)
        let deliveryCells = taskDashboard.todayCells(on: today).filter { $0.periodID == "evening" }
        check(deliveryCells[0].isCompleted && !deliveryCells[1].isCompleted, "delivery completion only links its matching child task")

        let rolling = """
        <!-- studyrocket:weekly:start -->
        | 日期 | 计划 |
        |------|------|
        | 8 月 12 日 | [ ] 过去任务 |
        | 8 月 14 日 | [ ] 周四任务 |
        | 8 月 18 日 | [x] 周一任务 |
        <!-- studyrocket:weekly:end -->
        """
        let rollingPlan = MarkdownParser.weekly(rolling, referenceDate: today)
        check(rollingPlan.dayDateLabels == ["8 月 13 日", "8 月 14 日", "8 月 15 日", "8 月 16 日", "8 月 17 日", "8 月 18 日", "8 月 19 日"], "rolling window starts today")
        check(rollingPlan.unassignedByDay[1].contains("周四任务") && rollingPlan.unassignedByDay[5].contains("周一任务"), "rows map by calendar date")
        check(rollingPlan.historicalRows.first?.dateLabel == "8 月 12 日", "past rows are retained separately")
        let rollingUpdated = MarkdownParser.replaceWeekly(rolling, with: rollingPlan)
        check(rollingUpdated.contains("studyrocket:weekly:history:start") && rollingUpdated.contains("过去任务"), "past rows are written to managed history")
        check(rollingUpdated.contains("8 月 14 日") && rollingUpdated.contains("8 月 18 日"), "visible future rows remain in the main table")
        print("WeeklyPlanModelChecks: passed")
    }
}
#endif

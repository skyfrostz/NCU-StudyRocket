#if STUDYROCKET_MODEL_TESTS
import Foundation

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

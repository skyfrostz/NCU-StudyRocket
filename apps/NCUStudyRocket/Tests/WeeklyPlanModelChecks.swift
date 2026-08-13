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
        let migrated = MarkdownParser.weekly(legacyDated)
        check(migrated.format == .timeGrid, "legacy dated rows present as a time grid")
        check(migrated.isMigratedPreview, "migration preview is exposed")
        check(migrated.migrationNotice != nil, "migration notice is exposed")
        check(migrated.dayDateLabels.count == 7 && migrated.cells.allSatisfy { $0.count == 7 }, "week is always seven days by three periods")
        check(migrated.cells[0][3] == "上午一；上午二", "legacy text is evenly split into morning")
        check(migrated.cells[1][3] == "中午一；中午二", "legacy text is evenly split into noon")
        check(migrated.cells[2][3] == "晚上一", "legacy text is evenly split into evening")
        check(migrated.unassignedByDay[4] == "无法安全拆分", "unsafe legacy text remains unassigned")
        check(migrated.dayCompletion[4], "legacy completion state is retained")
        check(migrated.datedRows.map(\.text) == ["上午一；上午二；中午一；中午二；晚上一", "无法安全拆分"], "legacy source text remains available")

        let upgraded = MarkdownParser.replaceWeekly(legacyDated, with: migrated)
        check(upgraded.contains("| 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |"), "save upgrades to structured week table")
        check(upgraded.contains("| 8 月 14 日 |  |  |  | 无法安全拆分 | [x] |"), "unassigned text and completion round trip")
        check(upgraded.hasPrefix("# 下周计划\n\n前置内容保持不变"), "content before managed boundary is unchanged")
        check(upgraded.hasSuffix("## 外部说明\n边界外必须逐字保留"), "content after managed boundary is unchanged")
        let reparsed = MarkdownParser.weekly(upgraded)
        check(reparsed.cells == migrated.cells, "structured cells round trip")
        check(reparsed.unassignedByDay == migrated.unassignedByDay, "unassigned rows round trip")
        check(reparsed.dayCompletion == migrated.dayCompletion, "day completion round trip")

        let legacyBuffer = """
        ## 缓冲
        - 每天保留 90 分钟弹性
        - 若课程撞车，只保课堂与当日唯一交付物
        - 若全崩，只保最重要的一件事

        ## 外部说明
        不参与缓冲迁移
        """
        var bufferPlan = MarkdownParser.weekly(legacyBuffer)
        check(bufferPlan.bufferRules.map(\.category) == [.daily, .collision, .minimum], "flat buffer rules are classified in memory")
        bufferPlan.bufferRules[0].text = "每天保留 90 分钟弹性\n不占用固定课程"
        let structuredBuffer = MarkdownParser.replaceWeekly(legacyBuffer, with: bufferPlan)
        check(structuredBuffer.contains("<!-- studyrocket:buffer:start -->") && structuredBuffer.contains("### 日常缓冲") && structuredBuffer.contains("### 撞车降级") && structuredBuffer.contains("### 最低底线"), "buffer gets managed category boundaries on save")
        check(structuredBuffer.contains("- 每天保留 90 分钟弹性\n  不占用固定课程"), "multiline buffer rule round trips")
        check(structuredBuffer.contains("## 外部说明\n不参与缓冲迁移"), "buffer migration preserves later unmanaged content")
        let reparsedBuffer = MarkdownParser.weekly(structuredBuffer)
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
        let legacyGridPlan = MarkdownParser.weekly(legacyGrid)
        check(WeeklyPlan.periods == ["上午", "中午", "晚上"], "period labels use morning noon evening")
        check(legacyGridPlan.cells[1][0] == "B", "legacy afternoon maps to noon")

        var calendar = MarkdownParser.studyCalendar
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13))!
        let visible = migrated.deliveriesExcluding(today, calendar: calendar)
        check(visible.map(\.text) == ["8 月 14 日：明日任务", "无日期任务"], "dashboard deliveries exclude only explicitly dated today items")
        check(visible.filter(\.isCompleted).count == 1, "filtered completion count uses visible deliveries")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StudyRocketWeeklyModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("工作台"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(upgraded.utf8).write(to: root.appendingPathComponent("工作台/下周计划.md"), options: .atomic)
        let dashboard = DashboardModel()
        dashboard.load(from: root)
        let todayCells = dashboard.todayCells(on: today)
        check(todayCells.count == 3 && todayCells.map(\.period) == ["上午", "中午", "晚上"], "dashboard always exposes three periods")
        check(todayCells.map(\.task) == ["上午一；上午二", "中午一；中午二", "晚上一"], "dashboard resolves the selected day slots")
        check(dashboard.firstOpenTask == nil || !dashboard.firstOpenTask!.contains("明日任务"), "first task never falls back to weekly deliveries")
        print("WeeklyPlanModelChecks: passed")
    }
}
#endif

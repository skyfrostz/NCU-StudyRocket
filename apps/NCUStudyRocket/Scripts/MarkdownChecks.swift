import Foundation

@main
struct MarkdownChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() {
        let source = "# 计划\n\n| 时段 | 周一 | 周二 | 周三 | 周四 | 周五 | 周六 | 周日 |\n|------|------|------|------|------|------|------|------|\n| 上午 | 数学 | | | | | | 复盘+重排 |\n| 下午 | | | | | | | |\n| 晚上 | | | | | | | |\n\n## 交付物清单\n- [ ] 读完第一章\n\n## 缓冲\n- 每天留白"
        var plan = MarkdownParser.weekly(source)
        check(plan.cells[0][0] == "数学", "weekly parser")
        plan.cells[1][1] = "Python"; plan.deliveries = [WeeklyDelivery(text: "完成小测", isCompleted: true)]
        let updated = MarkdownParser.replaceWeekly(source, with: plan)
        check(updated.hasPrefix("# 计划"), "weekly header preserved")
        check(updated.contains("每天留白"), "weekly buffer")
        check(updated.contains("Python"), "weekly cell")
        check(updated.contains("- [x] 完成小测"), "weekly delivery completion preserved")
        let dated = "# 计划\n\n<!-- studyrocket:weekly:start -->\n\n| 日期 | 计划 |\n|------|------|\n| 8 月 13 日 | [ ] 第一行<br>第二行 \\| 细节 |\n| 8 月 14 日 | [x] 已完成 |\n<!-- studyrocket:weekly:end -->\n\n## 交付物清单\n- [ ] 主任务\n  补充说明\n- [x] 第二任务\n\n## 缓冲\n- 每天留白\n\n## 外部说明\n原样保留"
        let datedPlan = MarkdownParser.weekly(dated)
        check(datedPlan.format == .timeGrid && datedPlan.isMigratedPreview && datedPlan.datedRows.count == 2, "dated rows migration parser")
        check(datedPlan.datedRows[0].text == "第一行\n第二行 | 细节" && datedPlan.datedRows[1].isCompleted, "dated row completion and escaping")
        check(datedPlan.deliveries.count == 2 && datedPlan.deliveries[0].text == "主任务\n补充说明", "multiline delivery parser")
        let datedUpdated = MarkdownParser.replaceWeekly(dated, with: datedPlan)
        check(datedUpdated.contains("第二行<br>第二行") == false, "dated rows do not duplicate")
        check(datedUpdated.contains("| 日期 | 上午 | 中午 | 晚上 |"), "dated rows migrate to structured table")
        check(datedUpdated.contains("第一行") && datedUpdated.contains("第二行 \\| 细节"), "dated row text survives migration")
        check(datedUpdated.contains("studyrocket:weekly:start") && datedUpdated.contains("studyrocket:weekly:end"), "weekly boundaries preserved")
        check(datedUpdated.contains("- [ ] 主任务\n  补充说明") && datedUpdated.contains("## 外部说明\n原样保留"), "multiline delivery round trip and outside content")
        let structured = "# 计划\n\n<!-- studyrocket:weekly:start -->\n| 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |\n|------|------|------|------|------|------|\n| 2026-08-10 | 数学 | 英语 | 复盘 | | [ ] |\n| 2026-08-11 | | Python | | | [x] |\n<!-- studyrocket:weekly:end -->\n\n## 外部说明\n保持原样"
        let structuredPlan = MarkdownParser.weekly(structured)
        check(structuredPlan.cells[0][0] == "数学" && structuredPlan.cells[1][0] == "英语", "structured weekly parser")
        check(structuredPlan.dayCompletion[1], "structured completion parser")
        let structuredUpdated = MarkdownParser.replaceWeekly(structured, with: structuredPlan)
        check(structuredUpdated.contains("## 外部说明\n保持原样"), "structured outside content preserved")
        let filterPlan = WeeklyPlan(deliveries: [
            WeeklyDelivery(text: "8 月 13 日：今天任务", isCompleted: false),
            WeeklyDelivery(text: "8 月 14 日：明天任务", isCompleted: true),
            WeeklyDelivery(text: "无日期成果", isCompleted: false)
        ])
        let filterDate = MarkdownParser.studyCalendar.date(from: DateComponents(year: 2026, month: 8, day: 13))!
        check(filterPlan.deliveriesExcluding(filterDate).count == 2, "dashboard excludes only today's dated deliveries")
        let daily = "# 每日\n\n### 2026-08-12\n- [ ] 今日完成的具体交付物：旧交付物\n- 净学习时长：1h\n- 入睡/起床：23:00 / 07:00\n- 运动：散步\n- 明日第一任务：旧任务\n\n### 2026-08-13\n- [ ] 今日完成的具体交付物："
        var entry = MarkdownParser.daily(daily, date: "2026-08-12"); entry.deliverables = "新交付物"
        let dailyUpdated = MarkdownParser.replaceDaily(daily, entry: entry)
        check(dailyUpdated.components(separatedBy: "### 2026-08-12").count - 1 == 1, "daily does not duplicate")
        check(dailyUpdated.contains("新交付物") && dailyUpdated.contains("### 2026-08-13"), "daily update preserves later records")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StudyRocketChecks-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? Data("# 课程\n内容 A".utf8).write(to: root.appendingPathComponent("课程.md"))
        try? Data("# 科研\n内容 B".utf8).write(to: root.appendingPathComponent("科研.md"))
        let document = MarkdownDocumentModel(root: root)
        document.load("课程.md")
        check(document.relative == "课程.md" && document.text.contains("内容 A"), "first document loads")
        document.text = "# 课程\n未保存草稿"
        check(document.isDirty, "document dirty state")
        document.discardAndLoad("科研.md")
        check(document.relative == "科研.md" && document.text.contains("内容 B") && !document.isDirty, "switching loads selected file")
        check(document.mode == .preview, "documents default to preview")
        let repository = MarkdownRepository(root: root)
        let first = try! repository.read("科研.md")
        try! repository.save("# 科研\n已保存", relative: "科研.md", loadedHash: repository.hash(first))
        check((try! repository.read("科研.md")).contains("已保存"), "repository saves current version")
        let staleHash = repository.hash("# 科研\n已保存")
        try! Data("# 科研\n外部修改".utf8).write(to: root.appendingPathComponent("科研.md"))
        do { try repository.save("# 科研\n覆盖", relative: "科研.md", loadedHash: staleHash); check(false, "conflict must reject overwrite") }
        catch MarkdownError.conflict { }
        catch { check(false, "conflict reports correct error") }
        let habitEntry = DailyEntry(id: "2026-08-13", date: "2026-08-13", deliverables: "完成小测", studyTime: "2h", sleep: "23:00 / 07:00", exercise: "散步", firstTask: "预习")
        try! HabitProfileUpdater.update(after: habitEntry, in: root)
        try! HabitProfileUpdater.update(after: habitEntry, in: root)
        let habits = try! repository.read("工作台/助理偏好与习惯.md")
        check(habits.components(separatedBy: "- 2026-08-13｜").count - 1 == 1, "habit update is idempotent")
        print("Markdown checks passed")
    }
}

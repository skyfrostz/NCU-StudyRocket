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
        plan.cells[1][1] = "Python"; plan.deliveries = ["完成小测"]
        let updated = MarkdownParser.replaceWeekly(source, with: plan)
        check(updated.hasPrefix("# 计划"), "weekly header preserved")
        check(updated.contains("每天留白"), "weekly buffer")
        check(updated.contains("Python"), "weekly cell")
        check(updated.contains("完成小测"), "weekly delivery")
        let daily = "# 每日\n\n### 2026-08-12\n- [ ] 今日完成的具体交付物：旧交付物\n- 净学习时长：1h\n- 入睡/起床：23:00 / 07:00\n- 运动：散步\n- 明日第一任务：旧任务\n\n### 2026-08-13\n- [ ] 今日完成的具体交付物："
        var entry = MarkdownParser.daily(daily, date: "2026-08-12"); entry.deliverables = "新交付物"
        let dailyUpdated = MarkdownParser.replaceDaily(daily, entry: entry)
        check(dailyUpdated.components(separatedBy: "### 2026-08-12").count - 1 == 1, "daily does not duplicate")
        check(dailyUpdated.contains("新交付物") && dailyUpdated.contains("### 2026-08-13"), "daily update preserves later records")
        print("Markdown checks passed")
    }
}

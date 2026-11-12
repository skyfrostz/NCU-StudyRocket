import Foundation
import StudyRocketShared

func runPlanningProposalSafetyChecks() throws {
    let path = "工作台/下周计划.md"
    let date = PlanningDate.key(.now)
    let row = "| \(date) | 合成学习任务 |  |  |  | [ ] |"
    let week = "<!-- studyrocket:weekly:start -->\n| 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |\n|---|---|---|---|---|---|\n\(row)\n<!-- studyrocket:weekly:end -->"
    let buffer = "<!-- studyrocket:buffer:start -->\n保留缓冲内容\n<!-- studyrocket:buffer:end -->"
    let deliveries = "<!-- studyrocket:deliveries:start -->\n- [ ] 旧交付物\n<!-- studyrocket:deliveries:end -->"
    let original = week + "\n\n" + deliveries + "\n\n" + buffer
    func rejects(_ proposed: String, source: String = original, file: String = path) {
        do {
            _ = try PlanningProposalValidation.prepare(path: file, original: source, proposed: proposed)
            preconditionFailure("A broken or missing managed boundary was accepted")
        } catch is PlanningProposalValidation.BoundaryError { }
        catch { preconditionFailure("Unexpected boundary error: \(error)") }
    }
    for block in [week, deliveries, buffer] { rejects(original.replacingOccurrences(of: block, with: "")) }
    rejects(original + "\n" + buffer)
    rejects(buffer + "\n" + week + "\n" + deliveries)
    rejects(original.replacingOccurrences(of: "<!-- studyrocket:buffer:end -->", with: ""))
    rejects(original.replacingOccurrences(of: "<!-- studyrocket:buffer:start -->", with: "<!-- studyrocket:buffer:start ->"))
    rejects(original.replacingOccurrences(of: "<!-- studyrocket:buffer:end -->", with: "<!-- studyrocket:deliveries:end -->"))
    let timetable = "<!-- studyrocket:timetable:start -->\n合成导入内容\n<!-- studyrocket:timetable:end -->\n<!-- studyrocket:events:start -->\n<!-- studyrocket:events:end -->"
    rejects("<!-- studyrocket:events:start -->\n<!-- studyrocket:events:end -->", source: timetable, file: StudyRocketTimetableParser.sourceFile)
    // Content changes are allowed; preserving boundaries is not a prose edit ban.
    let authorized = original.replacingOccurrences(of: "旧交付物", with: "用户授权的新交付物").replacingOccurrences(of: "保留缓冲内容", with: "用户调整后的缓冲")
    let authorizedResult = try PlanningProposalValidation.prepare(path: path, original: original, proposed: authorized)
    precondition(authorizedResult == authorized)
    try PlanningProposalValidation.validateManagedBoundaries(path: path, original: original,
        proposed: original + "\n<!-- studyrocket:future-data:start -->\n新内容\n<!-- studyrocket:future-data:end -->")

    let outside = "前文 e\u{301}\r\n第二行\r第三行\u{0085}第四行\u{2028}第五行\u{2029}"
    for ending in ["\n", "\r\n", "\r", "\u{0085}", "\u{2028}", "\u{2029}"] {
        let source = outside + original.replacingOccurrences(of: "\n", with: ending) + ending + "尾文无换行😀"
        let same = WeeklyPlanTaskNormalizer.normalizedMarkdown(source)
        precondition(Data(same.utf8) == Data(source.utf8), "No-op normalization changed source bytes")
        let routed = try PlanningChangeRouter.route(week: source, original: source, timetable: "合成课表\r\n")
        precondition(Data(routed.week.utf8) == Data(source.utf8) && routed.timetable == nil)
        let candidate = source.replacingOccurrences(of: "合成学习任务", with: "- [ ] 合成学习任务<br>- [ ] 第二项")
        let expected = source.replacingOccurrences(of: "合成学习任务", with: "合成学习任务<br>第二项")
        let prepared = try PlanningProposalValidation.prepare(path: path, original: source, proposed: candidate)
        precondition(Data(prepared.utf8) == Data(expected.utf8), "Normalization changed bytes outside the edited row")
    }
    let eventSource = outside + original.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n末尾原文"
    let eventCandidate = eventSource.replacingOccurrences(of: "合成学习任务", with: "19:00 羽毛球训练<br>合成学习任务")
    let routed = try PlanningChangeRouter.route(week: eventCandidate, original: eventSource, timetable: outside + timetable + "\r\n尾部")
    precondition(Data(routed.week.utf8) == Data(eventSource.utf8), "Event routing changed unrelated line bytes")
    precondition(routed.timetable?.hasPrefix(outside) == true && routed.timetable?.hasSuffix("\r\n尾部") == true)
    print("Planning proposal safety checks passed: managed boundary integrity, allowed content edits, exact mixed-newline preservation and event routing")
}

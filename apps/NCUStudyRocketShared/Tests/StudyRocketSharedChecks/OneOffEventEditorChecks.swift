import Foundation
import StudyRocketShared

func runOneOffEventEditorChecks() throws {
    let original = """
    # Original timetable

    Keep this explanation unchanged.
    <!-- studyrocket:timetable:start -->
    | 字段 | 内容 |
    | --- | --- |
    | 班级 | 261 一班 |
    | 学期 | 2026-2027 秋季学期 |
    | 起始日期 | 2026-09-14 |
    | 结束日期 | 2027-01-03 |
    | 自定义字段 | untouched |

    | 日期 | 周次 | 类型 | 开始 | 结束 | 节次 | 名称 | 地点 | 教师 | 备注 |
    | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
    | 2026-11-12 | 9 | 课程 | 08:00 | 09:30 | 1-2 | 课程示例 | 2-402 |  |  |
    | 2026-11-14 | 9 | 活动 | 19:00 | 20:00 |  | 考试示例 |  |  | 原始备注 |
    | 2026-11-14 | 9 | 活动 | 19:00 | 22:00 |  | 训练示例 |  |  | 原始备注 |
    <!-- studyrocket:timetable:end -->

    Keep this ending unchanged.
    """
    let document = try OneOffEventEditorDocument(source: original)
    precondition(document.timetableActivities.count == 2 && document.events.isEmpty)
    precondition(!document.hasChanges([]))
    let unchanged = try document.preview([])
    precondition(Data(unchanged.utf8) == Data(original.utf8), "Opening or reverting edits must preserve exact source bytes")
    precondition(!unchanged.contains(OneOffSchedule.startMarker), "Opening must not insert an empty activity block")

    let added = OneOffEvent(id: "new", date: "2026-11-15", start: "14:00", end: "15:00", title: "新增会议")
    let candidate = try document.preview([added])
    precondition(document.hasChanges([added]))
    precondition(candidate.hasPrefix(original), "Adding an event must preserve the entire original timetable, metadata and notes")
    let addedDocument = try OneOffEventEditorDocument(source: candidate)
    precondition(addedDocument.events == [added] && addedDocument.timetableActivities == document.timetableActivities)
    let deleted = try addedDocument.preview([])
    precondition(deleted.hasPrefix(original), "Deleting a separately added activity must not delete timetable activities")
    let deletedDocument = try OneOffEventEditorDocument(source: deleted)
    precondition(deletedDocument.timetableActivities == document.timetableActivities)

    let second = OneOffEvent(id: "another", date: "2026-11-16", start: "16:00", title: "第二项活动")
    let multipleSource = try document.preview([added, second])
    let multiple = try OneOffEventEditorDocument(source: multipleSource)
    precondition(!multiple.hasChanges([second, added]), "Presentation sorting is not a user edit")
    let reordered = try multiple.preview([second, added])
    precondition(reordered == multipleSource)
    let eventsOnly = try OneOffSchedule.write([added], in: "# 活动课表\n")
    let eventsOnlyDocument = try OneOffEventEditorDocument(source: eventsOnly)
    precondition(eventsOnlyDocument.events == [added])

    for invalid in ["", " \n", "# Unloaded timetable", original.replacingOccurrences(of: "2027-01-03", with: "invalid"),
                    original.replacingOccurrences(of: "<!-- studyrocket:timetable:end -->", with: ""),
                    candidate.replacingOccurrences(of: OneOffSchedule.endMarker, with: ""),
                    candidate.replacingOccurrences(of: OneOffSchedule.startMarker, with: " " + OneOffSchedule.startMarker),
                    original + "\n<!-- studyrocket:timetable:start -->"] {
        do {
            _ = try OneOffEventEditorDocument(source: invalid)
            preconditionFailure("Missing, malformed or ambiguous source must not create an editable empty list")
        } catch { /* Expected: fail closed before presenting an editable draft. */ }
    }

    // Optional read-only runtime fixture: no writes or personal data are copied
    // into the repository. Check before/after bytes, including original markers.
    if let path = ProcessInfo.processInfo.environment["STUDYROCKET_EVENT_READONLY_FIXTURE"] {
        let url = URL(fileURLWithPath: path)
        let before = try Data(contentsOf: url)
        let source = String(decoding: before, as: UTF8.self)
        let live = try OneOffEventEditorDocument(source: source)
        let noChange = try live.preview(live.events)
        precondition(Data(noChange.utf8) == before)
        let proposed = try live.preview(live.events + [added])
        let start = source.range(of: "<!-- studyrocket:timetable:start -->")!
        let end = source.range(of: "<!-- studyrocket:timetable:end -->")!
        precondition(proposed.contains(String(source[start.lowerBound..<end.upperBound])))
        let after = try Data(contentsOf: url)
        precondition(before == after, "Read-only fixture must not touch the real timetable")
        print("Read-only event fixture passed: \(live.timetableActivities.count) timetable activities, \(live.events.count) separate activities; original bytes unchanged")
    }
    print("One-off event editor checks passed")
}

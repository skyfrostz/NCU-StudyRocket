import Foundation
import StudyRocketShared
import StudyRocketTimetableImport

let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("studyrocket-timetable-import-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

let csvURL = temporaryDirectory.appendingPathComponent("课程.csv")
let csv = """
日期,周次,类型,开始,结束,节次,名称,地点,教师,备注
2026-09-14,1,课程,08:00,09:30,1-2,高等数学（上）,2-310,孙老师,
2026-09-15,1,假期,,,,校庆假期,,,
"""
try csv.write(to: csvURL, atomically: true, encoding: .utf8)
let csvPreview = try StudyRocketTimetableImport.preview(fileURL: csvURL)
precondition(csvPreview.format == .csv)
precondition(csvPreview.document.entries.count == 2)
precondition(csvPreview.document.firstImportedDate == "2026-09-14")
precondition(StudyRocketTimetableParser.snapshot(from: csvPreview.managedMarkdown, teachingWeek: 1).days.count == 7)

let bilingualCSVURL = temporaryDirectory.appendingPathComponent("英方课程.csv")
let bilingualCSV = """
日期,周次,类型,开始,结束,节次,名称,地点,教师,备注
2026-09-14,1,答疑,08:00,09:00,1,Academic and Skills Support -1A,,,
2026-09-14,1,officeHour,09:15,10:15,3,Office Hour,,,
2026-09-15,1,答疑,08:00,09:00,1,Academic and Skills Support -1B,,,
2026-09-15,1,课程,09:15,10:15,3,Medical Cell Biology / 基础医学遗传学和细胞生物学,,,
2026-09-15,1,课程,10:30,11:30,4,Practice for Basic Medical Genetics and Cell Biology,,,
2026-09-15,1,break,11:30,11:40,5,课间休息,,,
2026-09-16,1,假期,,,,Mid-Autumn Festival,,,
2026-10-01,3,假期,,,,National Day,,,
2027-01-01,16,假期,,,,New Year's Day,,,
"""
try bilingualCSV.write(to: bilingualCSVURL, atomically: true, encoding: .utf8)
let bilingualPreview = try StudyRocketTimetableImport.preview(fileURL: bilingualCSVURL)
precondition(bilingualPreview.document.entries.first { $0.entry.title.hasPrefix("Academic and Skills Support") }?.entry.kind == .course)
precondition(bilingualPreview.document.entries.first { $0.entry.title.contains("Skills Support - 1B") }?.entry.title == "Academic and Skills Support - 1B / 学术与技能支持（1B）")
precondition(bilingualPreview.document.entries.first { $0.entry.title.hasPrefix("Office Hour") }?.entry.kind == .course)
precondition(bilingualPreview.document.entries.first { $0.entry.title.hasPrefix("Medical Cell Biology") }?.entry.title == "Medical Cell Biology / 医学细胞生物学")
precondition(bilingualPreview.document.entries.first { $0.entry.title.hasPrefix("Practice for Basic Medical") }?.entry.title == "Practice for Basic Medical Genetics and Cell Biology / 基础医学遗传学和细胞生物学实验")
precondition(!bilingualPreview.document.entries.contains { $0.entry.title == "课间休息" })
for holiday in ["Mid-Autumn Festival", "National Day", "New Year's Day"] {
    precondition(bilingualPreview.document.entries.first { $0.entry.title == holiday }?.entry.kind == .holiday)
}
precondition(bilingualPreview.managedMarkdown.contains("| 2026-09-14 | 1 | 课程 | 08:00 | 09:00 | 1 | Academic and Skills Support - 1A / 学术与技能支持（1A）"))

let markdownURL = temporaryDirectory.appendingPathComponent("课程.md")
try csvPreview.managedMarkdown.write(to: markdownURL, atomically: true, encoding: .utf8)
let markdownPreview = try StudyRocketTimetableImport.preview(fileURL: markdownURL)
precondition(markdownPreview.format == .markdown)
precondition(markdownPreview.document == csvPreview.document)

if CommandLine.arguments.count == 2 {
    let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let preview = try StudyRocketTimetableImport.preview(fileURL: inputURL)
    precondition(!preview.document.entries.isEmpty)
    precondition(StudyRocketTimetableParser.teachingWeekRange(from: preview.managedMarkdown)?.upperBound == 16)
    print("TimetableImportChecks: \(preview.format.title) import passed for \(preview.document.entries.count) entries")
} else {
    print("TimetableImportChecks: CSV and Markdown import checks passed")
}

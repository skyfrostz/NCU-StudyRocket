import StudyRocketShared
import XCTest

@testable import StudyRocketMobile

final class MobileTodayFocusTests: XCTestCase {
  private let periods = [
    PeriodSnapshot(id: "morning", title: "上午", text: "完成导数例题"),
    PeriodSnapshot(id: "noon", title: "中午", text: "整理错题"),
    PeriodSnapshot(id: "evening", title: "晚上", text: ""),
  ]

  func testFocusAdvancesAndRestoresWithOptimisticCompletion() {
    XCTAssertEqual(
      MobileTodayFocus.resolve(periods: periods) { $0.id == "morning" },
      .task("整理错题", completed: 1, total: 2)
    )
    XCTAssertEqual(
      MobileTodayFocus.resolve(periods: periods) { _ in false },
      .task("完成导数例题", completed: 0, total: 2)
    )
  }

  func testFocusDistinguishesCompletedAndUnplannedDays() {
    XCTAssertEqual(
      MobileTodayFocus.resolve(periods: periods) { !$0.text.isEmpty },
      .completed(total: 2)
    )
    XCTAssertEqual(
      MobileTodayFocus.resolve(
        periods: periods.map { PeriodSnapshot(id: $0.id, title: $0.title, text: "") }
      ) { _ in false },
      .unplanned
    )
  }

  func testFocusCountsChildTasksInsideOnePeriodIndependently() {
    let periods = [
      PeriodSnapshot(id: "evening", title: "晚上", text: "19:00 邮件系统英方培训\n20:00 问李训灏：专业考勤系统选用问题")
    ]
    let first = periods[0].tasks[0]
    let second = periods[0].tasks[1]

    XCTAssertEqual(
      MobileTodayFocus.resolve(periods: periods) { _, task in task.id == first.id },
      .task(second.text, completed: 1, total: 2)
    )
    XCTAssertEqual(
      MobileTodayFocus.orderedTasks(periods: periods, timetable: nil) { _, task in task.id == first.id },
      [second.text]
    )
  }

  func testFocusMergesTodayPlanAndTimetableInChronologicalOrder() {
    let periods = [
      PeriodSnapshot(id: "evening", title: "晚上", text: "20:00 复习单词"),
      PeriodSnapshot(id: "noon", title: "中午", text: "12:30 整理错题"),
      PeriodSnapshot(id: "morning", title: "上午", text: "08:30 预习高数"),
    ]
    let timetable = TimetableSnapshot(
      status: .available,
      classLabel: "261 班",
      termLabel: "2026 秋季",
      referenceDate: "2026-09-14",
      days: [
        TimetableDaySnapshot(
          id: "2026-09-14",
          dateLabel: "9月14日 · 周一",
          week: 1,
          weekday: 2,
          weekdayLabel: "周一",
          entries: [
            TimetableEntrySnapshot(
              id: "english", kind: .course, title: "学术英语", startTime: "14:00", endTime: "15:00"),
            TimetableEntrySnapshot(
              id: "tennis", kind: .course, title: "网球（1）", startTime: "08:00", endTime: "09:30",
              note: "07:50 到场"),
            TimetableEntrySnapshot(
              id: "math", kind: .course, title: "高等数学", startTime: "10:00", endTime: "11:30"),
            TimetableEntrySnapshot(
              id: "holiday", kind: .holiday, title: "不应显示", startTime: "06:00"),
            TimetableEntrySnapshot(id: "untimed", kind: .event, title: "时间待定活动"),
          ]
        )
      ]
    )

    let ordered = MobileTodayFocus.orderedTasks(
      periods: periods,
      timetable: timetable,
      now: date(hour: 6)
    ) { _ in false }

    XCTAssertEqual(
      ordered,
      [
        "07:50 · 网球（1）",
        "08:30 预习高数",
        "10:00 · 高等数学",
        "12:30 整理错题",
        "14:00 · 学术英语",
        "20:00 复习单词",
      ])
    XCTAssertEqual(
      MobileTodayFocus.resolve(periods: periods, timetable: timetable, now: date(hour: 6)) { _ in
        false
      },
      .task("07:50 · 网球（1）", completed: 0, total: 3)
    )
  }

  func testFocusSkipsEndedTimetableEntriesButKeepsUpcomingClass() {
    let timetable = TimetableSnapshot(
      status: .available,
      classLabel: "261 班",
      termLabel: "2026 秋季",
      referenceDate: "2026-09-14",
      days: [
        TimetableDaySnapshot(
          id: "2026-09-14",
          dateLabel: "9月14日 · 周一",
          week: 1,
          weekday: 2,
          weekdayLabel: "周一",
          entries: [
            TimetableEntrySnapshot(
              id: "finished", kind: .course, title: "已结束课程", startTime: "08:00", endTime: "09:30"),
            TimetableEntrySnapshot(
              id: "upcoming", kind: .course, title: "下午课程", startTime: "14:00", endTime: "15:30"),
          ]
        )
      ]
    )

    XCTAssertEqual(
      MobileTodayFocus.resolve(periods: [], timetable: timetable, now: date(hour: 10)) { _ in false
      },
      .task("14:00 · 下午课程", completed: 0, total: 0)
    )
    XCTAssertEqual(
      MobileTodayFocus.resolve(periods: [], timetable: timetable, now: date(hour: 9, minute: 30)) {
        _ in false
      },
      .task("14:00 · 下午课程", completed: 0, total: 0)
    )
  }

  func testFocusIgnoresStaleTimetableAndUsesStableCourseTieBreak() {
    let timetable = TimetableSnapshot(
      status: .available,
      classLabel: "261 班",
      termLabel: "2026 秋季",
      referenceDate: "2026-09-14",
      days: [
        TimetableDaySnapshot(
          id: "2026-09-14",
          dateLabel: "9月14日 · 周一",
          week: 1,
          weekday: 2,
          weekdayLabel: "周一",
          entries: [
            TimetableEntrySnapshot(
              id: "", kind: .course, title: "同刻课程甲", startTime: "08：30", endTime: "09：30"),
            TimetableEntrySnapshot(
              id: "", kind: .course, title: "同刻课程乙", startTime: "08：30", endTime: "09：30"),
          ]
        )
      ]
    )
    let periods = [PeriodSnapshot(id: "morning", title: "上午", text: "08：30 今日计划")]

    XCTAssertEqual(
      MobileTodayFocus.orderedTasks(periods: periods, timetable: timetable, now: date(hour: 8)) {
        _ in false
      },
      ["08:30 · 同刻课程甲", "08:30 · 同刻课程乙", "08：30 今日计划"]
    )
    XCTAssertEqual(
      MobileTodayFocus.resolve(periods: [], timetable: timetable, now: date(day: 15, hour: 8)) {
        _ in false
      },
      .unplanned
    )
  }

  private func date(day: Int = 14, hour: Int, minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar.date(
      from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
  }
}

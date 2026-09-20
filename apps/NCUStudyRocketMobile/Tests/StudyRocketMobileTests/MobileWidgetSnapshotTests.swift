import Foundation
import XCTest
@testable import StudyRocketMobile
@testable import StudyRocketWidgetSupport
import StudyRocketShared

final class MobileWidgetSnapshotTests: XCTestCase {
    func testWidgetConfigurationUsesSelfCheckValuesFromItsBundle() {
        let info: [String: Any] = [
            "StudyRocketAppGroupIdentifier": "group.com.skyfrost.ncustudyrocket.selfcheck",
            "StudyRocketURLScheme": "ncustudyrocket-selfcheck"
        ]

        XCTAssertEqual(
            StudyRocketWidgetConfiguration.appGroupIdentifier(in: info),
            "group.com.skyfrost.ncustudyrocket.selfcheck"
        )
        XCTAssertEqual(
            StudyRocketWidgetConfiguration.urlScheme(in: info),
            "ncustudyrocket-selfcheck"
        )
    }

    func testProjectionKeepsOnlyAssignedTodayTasksAndOpenDelivery() {
        let fetchedAt = Date(timeIntervalSince1970: 1_789_281_000)
        let source = SnapshotResponse(
            revision: "widget-r1",
            fetchedAt: fetchedAt,
            home: HomeSnapshot(
                dateLabel: "9月13日 · 周日",
                periods: [
                    PeriodSnapshot(id: "morning", title: "上午", text: "完成高数例题", isCompleted: true),
                    PeriodSnapshot(id: "noon", title: "中午", text: "复习英语词汇"),
                    PeriodSnapshot(id: "evening", title: "晚上", text: "")
                ],
                firstOpenTask: "复习英语词汇",
                visibleDeliveries: [],
                completedDeliveries: 1,
                totalDeliveries: 3
            ),
            week: WeeklyPlanSnapshot(
                days: [],
                bufferRules: [],
                deliveries: [
                    DeliverySnapshot(id: "done", text: "已完成交付物", isCompleted: true),
                    DeliverySnapshot(id: "open", text: "完成本周课程笔记", isCompleted: false)
                ]
            ),
            daily: DailySnapshot(date: "2026-09-13"),
            summaries: []
        )

        let widget = MobileWidgetSnapshotBuilder.make(from: source)

        XCTAssertEqual(widget.referenceDay, StudyRocketWidgetSnapshot.dayKey(for: fetchedAt))
        XCTAssertEqual(widget.dateLabel, "9月13日 · 周日")
        XCTAssertEqual(widget.todayPeriods.map(\.title), ["上午", "中午"])
        XCTAssertEqual(widget.completedToday, 1)
        XCTAssertEqual(widget.totalToday, 2)
        XCTAssertEqual(widget.nextTaskPeriodTitle, "中午")
        XCTAssertEqual(widget.nextTask, "复习英语词汇")
        XCTAssertEqual(widget.completedDeliveries, 1)
        XCTAssertEqual(widget.totalDeliveries, 2)
        XCTAssertEqual(widget.firstOpenDelivery, "完成本周课程笔记")
    }

    func testProjectionFallsBackToHostFocusWhenTodayHasNoOpenPeriod() {
        let source = SnapshotResponse(
            revision: "widget-r2",
            home: HomeSnapshot(
                dateLabel: "9月13日 · 周日",
                periods: [PeriodSnapshot(id: "morning", title: "上午", text: "完成高数例题", isCompleted: true)],
                firstOpenTask: "整理错题",
                visibleDeliveries: [],
                completedDeliveries: 0,
                totalDeliveries: 0
            ),
            week: WeeklyPlanSnapshot(days: [], bufferRules: [], deliveries: []),
            daily: DailySnapshot(date: "2026-09-13"),
            summaries: []
        )

        let widget = MobileWidgetSnapshotBuilder.make(from: source)

        XCTAssertEqual(widget.nextTask, "整理错题")
        XCTAssertNil(widget.nextTaskPeriodTitle)
        XCTAssertEqual(widget.completedToday, 1)
        XCTAssertEqual(widget.totalToday, 1)
    }

    func testProjectionFlattensMultipleTasksInOnePeriod() {
        let tasks = PeriodTaskParser.tasks(from: "19:00 邮件系统英方培训\n20:00 问李训灏：专业考勤系统选用问题")
        let source = SnapshotResponse(
            revision: "widget-multi",
            home: HomeSnapshot(
                dateLabel: "9月13日 · 周日",
                periods: [PeriodSnapshot(
                    id: "evening",
                    title: "晚上",
                    text: "19:00 邮件系统英方培训\n20:00 问李训灏：专业考勤系统选用问题",
                    tasks: [
                        PeriodTaskSnapshot(id: tasks[0].id, text: tasks[0].text, isCompleted: true),
                        PeriodTaskSnapshot(id: tasks[1].id, text: tasks[1].text, isCompleted: false)
                    ]
                )],
                firstOpenTask: tasks[1].text,
                visibleDeliveries: [],
                completedDeliveries: 0,
                totalDeliveries: 0
            ),
            week: WeeklyPlanSnapshot(days: [], bufferRules: [], deliveries: []),
            daily: DailySnapshot(date: "2026-09-13"),
            summaries: []
        )

        let widget = MobileWidgetSnapshotBuilder.make(from: source)

        XCTAssertEqual(widget.todayPeriods.map(\.text), tasks.map(\.text))
        XCTAssertEqual(widget.completedToday, 1)
        XCTAssertEqual(widget.totalToday, 2)
        XCTAssertEqual(widget.nextTask, tasks[1].text)
        XCTAssertEqual(widget.nextTaskPeriodTitle, "晚上")
    }

    func testProjectionAddsTodayTimetableLessons() {
        let fetchedAt = Date(timeIntervalSince1970: 1_789_281_000)
        let referenceDay = StudyRocketWidgetSnapshot.dayKey(for: fetchedAt)
        let today = TimetableDaySnapshot(
            id: referenceDay,
            dateLabel: "9月13日 · 周日",
            week: 2,
            weekday: 1,
            weekdayLabel: "周日",
            entries: [
                TimetableEntrySnapshot(id: "math", kind: .course, title: "高等数学", startTime: "08:00", endTime: "09:40", location: "主教楼 302"),
                TimetableEntrySnapshot(id: "python", kind: .course, title: "Python 程序设计", startTime: "10:00", endTime: "11:40", location: "实验楼 204"),
                TimetableEntrySnapshot(id: "english", kind: .course, title: "学术英语", startTime: "14:00", endTime: "15:40", location: "综合楼 106"),
                TimetableEntrySnapshot(id: "lab", kind: .support, title: "学习答疑", periodLabel: "第 7-8 节", location: "实验楼 101"),
                TimetableEntrySnapshot(id: "overflow", kind: .event, title: "不应显示", startTime: "19:00")
            ]
        )
        let source = SnapshotResponse(
            revision: "widget-timetable",
            fetchedAt: fetchedAt,
            home: HomeSnapshot(
                dateLabel: "9月13日 · 周日",
                periods: [],
                firstOpenTask: nil,
                visibleDeliveries: [],
                completedDeliveries: 0,
                totalDeliveries: 0,
                timetable: TimetableSnapshot(
                    status: .available,
                    classLabel: "261 班",
                    termLabel: "2026 秋季",
                    referenceDate: referenceDay,
                    days: [today]
                )
            ),
            week: WeeklyPlanSnapshot(days: [], bufferRules: [], deliveries: []),
            daily: DailySnapshot(date: referenceDay),
            summaries: []
        )

        let widget = MobileWidgetSnapshotBuilder.make(from: source)

        XCTAssertEqual(widget.timetableStatus, .available)
        XCTAssertTrue(widget.hasTodayTimetableDay)
        XCTAssertEqual(widget.totalTodayLessons, 5)
        XCTAssertEqual(widget.todayLessons.map(\.id), ["math", "python", "english", "lab"])
        XCTAssertEqual(widget.todayLessons.first?.timeLabel, "08:00\n09:40")
        XCTAssertEqual(widget.todayLessons[3].timeLabel, "第 7-8 节")
        XCTAssertEqual(widget.todayLessons.first?.location, "主教楼 302")
    }

    func testProjectionKeepsAvailableNoClassDayDistinctFromUnavailableTimetable() {
        let fetchedAt = Date(timeIntervalSince1970: 1_789_281_000)
        let referenceDay = StudyRocketWidgetSnapshot.dayKey(for: fetchedAt)
        let emptyDay = TimetableDaySnapshot(
            id: referenceDay,
            dateLabel: "9月13日 · 周日",
            week: 2,
            weekday: 1,
            weekdayLabel: "周日",
            entries: []
        )

        let available = makeWidgetSource(
            fetchedAt: fetchedAt,
            timetable: TimetableSnapshot(
                status: .available,
                classLabel: "261 班",
                termLabel: "2026 秋季",
                referenceDate: referenceDay,
                days: [emptyDay]
            )
        )
        let availableWidget = MobileWidgetSnapshotBuilder.make(from: available)
        XCTAssertEqual(availableWidget.timetableStatus, .available)
        XCTAssertTrue(availableWidget.hasTodayTimetableDay)
        XCTAssertTrue(availableWidget.todayLessons.isEmpty)

        for status in [TimetableStatus.notImported, .invalid, .beforeTerm, .afterTerm] {
            let unavailable = makeWidgetSource(
                fetchedAt: fetchedAt,
                timetable: TimetableSnapshot(
                    status: status,
                    classLabel: "261 班",
                    termLabel: "2026 秋季",
                    referenceDate: referenceDay,
                    days: [TimetableDaySnapshot(
                        id: referenceDay,
                        dateLabel: "9月13日 · 周日",
                        week: 2,
                        weekday: 1,
                        weekdayLabel: "周日",
                        entries: [TimetableEntrySnapshot(id: "hidden", kind: .course, title: "不应显示")]
                    )]
                )
            )
            let widget = MobileWidgetSnapshotBuilder.make(from: unavailable)
            XCTAssertEqual(widget.timetableStatus.rawValue, status.rawValue)
            XCTAssertFalse(widget.hasTodayTimetableDay)
            XCTAssertTrue(widget.todayLessons.isEmpty)
        }
    }

    func testProjectionKeepsMissingTodayTimetableDayAsRefreshState() {
        let fetchedAt = Date(timeIntervalSince1970: 1_789_281_000)
        let referenceDay = StudyRocketWidgetSnapshot.dayKey(for: fetchedAt)
        let source = makeWidgetSource(
            fetchedAt: fetchedAt,
            timetable: TimetableSnapshot(
                status: .available,
                classLabel: "261 班",
                termLabel: "2026 秋季",
                referenceDate: referenceDay,
                days: [TimetableDaySnapshot(
                    id: "2026-09-14",
                    dateLabel: "9月14日 · 周一",
                    week: 2,
                    weekday: 2,
                    weekdayLabel: "周一",
                    entries: []
                )]
            )
        )

        let widget = MobileWidgetSnapshotBuilder.make(from: source)

        XCTAssertEqual(widget.timetableStatus, .available)
        XCTAssertFalse(widget.hasTodayTimetableDay)
        XCTAssertTrue(widget.todayLessons.isEmpty)
    }

    func testProjectionTreatsMissingTimetableAsUnavailable() {
        let fetchedAt = Date(timeIntervalSince1970: 1_789_281_000)
        let widget = MobileWidgetSnapshotBuilder.make(from: makeWidgetSource(fetchedAt: fetchedAt, timetable: nil))

        XCTAssertEqual(widget.timetableStatus, .unavailable)
        XCTAssertFalse(widget.hasTodayTimetableDay)
        XCTAssertTrue(widget.todayLessons.isEmpty)
    }

    func testLegacyAppGroupPayloadDecodesWithEmptyTimetableColumn() throws {
        let legacy = LegacyWidgetSnapshot(
            version: StudyRocketWidgetSnapshot.currentVersion,
            referenceDay: "2026-09-13",
            updatedAt: Date(timeIntervalSince1970: 1_789_281_000),
            dateLabel: "9月13日 · 周日",
            nextTask: "完成高数例题",
            nextTaskPeriodTitle: "上午",
            todayPeriods: [],
            completedToday: 0,
            totalToday: 1,
            completedDeliveries: 0,
            totalDeliveries: 0,
            firstOpenDelivery: nil
        )

        let decoded = try JSONDecoder().decode(StudyRocketWidgetSnapshot.self, from: JSONEncoder().encode(legacy))

        XCTAssertEqual(decoded.timetableStatus, .unavailable)
        XCTAssertFalse(decoded.hasTodayTimetableDay)
        XCTAssertEqual(decoded.totalTodayLessons, 0)
        XCTAssertTrue(decoded.todayLessons.isEmpty)
    }

    func testWidgetSnapshotRoundTripRetainsTimetableColumn() throws {
        let snapshot = StudyRocketWidgetSnapshot(
            referenceDay: "2026-09-13",
            updatedAt: Date(timeIntervalSince1970: 1_789_281_000),
            dateLabel: "9月13日 · 周日",
            nextTask: "完成高数例题",
            nextTaskPeriodTitle: "上午",
            todayPeriods: [StudyRocketWidgetPeriod(id: "morning", title: "上午", text: "完成高数例题", isCompleted: false)],
            completedToday: 0,
            totalToday: 1,
            completedDeliveries: 0,
            totalDeliveries: 0,
            firstOpenDelivery: nil,
            timetableStatus: .available,
            hasTodayTimetableDay: true,
            totalTodayLessons: 2,
            todayLessons: [StudyRocketWidgetLesson(id: "math", timeLabel: "08:00\n09:40", title: "高等数学", location: "主教楼 302")]
        )

        let decoded = try JSONDecoder().decode(StudyRocketWidgetSnapshot.self, from: JSONEncoder().encode(snapshot))

        XCTAssertEqual(decoded, snapshot)
    }

    func testTimelineBoundaryUsesShanghaiMidnight() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let current = try! XCTUnwrap(formatter.date(from: "2026-09-13T15:30:00Z"))

        let boundary = StudyRocketWidgetSnapshot.nextDayBoundary(after: current)

        XCTAssertEqual(StudyRocketWidgetSnapshot.dayKey(for: boundary), "2026-09-14")
        XCTAssertEqual(boundary.timeIntervalSince1970, 1_789_315_200, accuracy: 0.1)
    }

    func testWidgetDestinationAcceptsOnlyKnownRoutes() {
        XCTAssertEqual(MobileWidgetDestination.parse(URL(string: "ncustudyrocket://home")!), .home)
        XCTAssertEqual(MobileWidgetDestination.parse(URL(string: "ncustudyrocket://timetable")!), .timetable)
        XCTAssertEqual(MobileWidgetDestination.parse(URL(string: "ncustudyrocket://plan")!), .plan)
        XCTAssertNil(MobileWidgetDestination.parse(URL(string: "ncustudyrocket://chat")!))
        XCTAssertNil(MobileWidgetDestination.parse(URL(string: "https://example.com/home")!))
    }

    private func makeWidgetSource(fetchedAt: Date, timetable: TimetableSnapshot?) -> SnapshotResponse {
        SnapshotResponse(
            revision: "widget-status",
            fetchedAt: fetchedAt,
            home: HomeSnapshot(
                dateLabel: "9月13日 · 周日",
                periods: [],
                firstOpenTask: nil,
                visibleDeliveries: [],
                completedDeliveries: 0,
                totalDeliveries: 0,
                timetable: timetable
            ),
            week: WeeklyPlanSnapshot(days: [], bufferRules: [], deliveries: []),
            daily: DailySnapshot(date: StudyRocketWidgetSnapshot.dayKey(for: fetchedAt)),
            summaries: []
        )
    }
}

private struct LegacyWidgetSnapshot: Codable {
    let version: Int
    let referenceDay: String
    let updatedAt: Date
    let dateLabel: String
    let nextTask: String?
    let nextTaskPeriodTitle: String?
    let todayPeriods: [StudyRocketWidgetPeriod]
    let completedToday: Int
    let totalToday: Int
    let completedDeliveries: Int
    let totalDeliveries: Int
    let firstOpenDelivery: String?
}

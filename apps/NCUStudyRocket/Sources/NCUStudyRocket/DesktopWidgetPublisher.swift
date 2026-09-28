import Foundation
import StudyRocketDesktopWidgetSupport
import WidgetKit

@MainActor
enum DesktopWidgetPublisher {
    static func publish(from root: URL) {
        let dashboard = DashboardModel()
        dashboard.load(from: root)
        guard dashboard.errorMessage == nil else {
            DesktopWidgetSnapshotStore.remove()
            WidgetCenter.shared.reloadTimelines(ofKind: "NCUStudyRocketDesktopWidget")
            return
        }

        let now = Date()
        let day = DesktopWidgetSnapshot.dayKey(now)
        let tasks = dashboard.todayCells.compactMap { task -> DesktopWidgetSnapshot.TaskItem? in
            let title = task.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return .init(id: task.id, period: task.period, title: title, completed: task.isCompleted)
        }
        let focus = tasks.first(where: { !$0.completed })
        let timetable = dashboard.timetable
        let today = timetable.days.first(where: { $0.id == day })
        let lessons = today?.entries.map { entry in
            DesktopWidgetSnapshot.Lesson(
                id: entry.id,
                time: entry.startTime ?? entry.periodLabel ?? "时间待定",
                title: entry.title,
                location: entry.location
            )
        } ?? []
        let previous = DesktopWidgetSnapshotStore.load()
        if let previous,
           previous.day == day,
           previous.focus == focus?.title,
           previous.focusPeriod == focus?.period,
           previous.tasks == tasks,
           previous.timetableStatus == timetable.status.rawValue,
           previous.hasToday == (today != nil),
           previous.lessons == lessons { return }

        let snapshot = DesktopWidgetSnapshot(
            day: day,
            updatedAt: now,
            focus: focus?.title,
            focusPeriod: focus?.period,
            tasks: tasks,
            timetableStatus: timetable.status.rawValue,
            hasToday: today != nil,
            lessons: lessons
        )
        if DesktopWidgetSnapshotStore.save(snapshot) {
            WidgetCenter.shared.reloadTimelines(ofKind: "NCUStudyRocketDesktopWidget")
        }
    }
}

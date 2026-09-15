import Foundation
import StudyRocketShared
import StudyRocketWidgetSupport

/// Keeps Home Screen content limited to the small, read-only set of fields
/// that remains useful away from the app. The full Host snapshot stays in the
/// app's private cache.
enum MobileWidgetSnapshotBuilder {
    static func make(from snapshot: SnapshotResponse) -> StudyRocketWidgetSnapshot {
        let referenceDay = StudyRocketWidgetSnapshot.dayKey(for: snapshot.fetchedAt)
        let periods = snapshot.home.periods.flatMap { period in
            period.tasks.compactMap { task -> StudyRocketWidgetPeriod? in
                let text = task.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return StudyRocketWidgetPeriod(
                    id: "\(period.id):\(task.id)",
                    title: period.title,
                    text: text,
                    isCompleted: task.isCompleted
                )
            }
        }
        let nextPeriod = periods.first(where: { !$0.isCompleted })
        let fallbackTask = snapshot.home.firstOpenTask?.trimmingCharacters(in: .whitespacesAndNewlines)
        let deliveries = snapshot.week.deliveries
        let timetable = snapshot.home.timetable
        let timetableStatus = timetable.flatMap { StudyRocketWidgetTimetableStatus(rawValue: $0.status.rawValue) } ?? .unavailable
        let todayDay = timetableStatus == .available
            ? timetable?.days.first(where: { $0.id == referenceDay })
            : nil
        let projectedLessons: [StudyRocketWidgetLesson]
        if let todayDay {
            projectedLessons = todayDay.entries.compactMap { entry in
                let title = normalizedText(entry.title)
                guard let title else { return nil }
                return StudyRocketWidgetLesson(
                    id: entry.id,
                    timeLabel: lessonTimeLabel(start: entry.startTime, end: entry.endTime, period: entry.periodLabel),
                    title: title,
                    location: normalizedText(entry.location)
                )
            }
        } else {
            projectedLessons = []
        }
        let todayLessons = Array(projectedLessons.prefix(4))

        return StudyRocketWidgetSnapshot(
            referenceDay: referenceDay,
            updatedAt: snapshot.fetchedAt,
            dateLabel: snapshot.home.dateLabel,
            nextTask: nextPeriod?.text ?? (fallbackTask?.isEmpty == false ? fallbackTask : nil),
            nextTaskPeriodTitle: nextPeriod?.title,
            todayPeriods: Array(periods.prefix(3)),
            completedToday: periods.filter(\.isCompleted).count,
            totalToday: periods.count,
            completedDeliveries: deliveries.filter(\.isCompleted).count,
            totalDeliveries: deliveries.count,
            firstOpenDelivery: deliveries.first(where: { !$0.isCompleted })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
            timetableStatus: timetableStatus,
            hasTodayTimetableDay: todayDay != nil,
            totalTodayLessons: projectedLessons.count,
            todayLessons: todayLessons
        )
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func lessonTimeLabel(start: String?, end: String?, period: String?) -> String {
        switch (normalizedText(start), normalizedText(end)) {
        case let (start?, end?):
            return "\(start)\n\(end)"
        case let (start?, nil):
            return start
        case let (nil, end?):
            return end
        case (nil, nil):
            return normalizedText(period) ?? "时间待定"
        }
    }
}

enum MobileWidgetDestination: Equatable {
    case home
    case timetable
    case plan

    var tabIndex: Int {
        switch self {
        case .home: 0
        case .timetable: 2
        case .plan: 3
        }
    }

    static func parse(_ url: URL) -> Self? {
        guard url.scheme?.lowercased() == "ncustudyrocket" else { return nil }

        switch url.host?.lowercased() {
        case "home": return .home
        case "timetable": return .timetable
        case "plan": return .plan
        default: return nil
        }
    }
}

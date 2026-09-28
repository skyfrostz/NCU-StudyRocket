import Foundation

/// Only the fields rendered by the widget cross the App Group boundary.
public struct DesktopWidgetSnapshot: Codable, Equatable {
    public static let version = 1
    public let version: Int
    public let day: String
    public let updatedAt: Date
    public let focus: String?
    public let focusPeriod: String?
    public let tasks: [TaskItem]
    public let timetableStatus: String
    public let hasToday: Bool
    public let lessons: [Lesson]

    public struct TaskItem: Codable, Equatable, Identifiable {
        public let id: String
        public let period: String
        public let title: String
        public let completed: Bool

        public init(id: String, period: String, title: String, completed: Bool) {
            self.id = id
            self.period = period
            self.title = title
            self.completed = completed
        }
    }

    public struct Lesson: Codable, Equatable, Identifiable {
        public let id: String
        public let time: String
        public let title: String
        public let location: String?

        public init(id: String, time: String, title: String, location: String?) {
            self.id = id
            self.time = time
            self.title = title
            self.location = location
        }
    }

    public init(day: String, updatedAt: Date, focus: String?, focusPeriod: String?, tasks: [TaskItem], timetableStatus: String, hasToday: Bool, lessons: [Lesson]) {
        self.version = Self.version
        self.day = day
        self.updatedAt = updatedAt
        self.focus = focus
        self.focusPeriod = focusPeriod
        self.tasks = tasks
        self.timetableStatus = timetableStatus
        self.hasToday = hasToday
        self.lessons = lessons
    }

    public static func dayKey(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    public static func nextMidnight(after date: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date.addingTimeInterval(86_400)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }
}

public enum DesktopWidgetSnapshotStore {
    private static let group = "QNRY5H3QJ9.com.skyfrost.ncustudyrocket.widget"
    private static let key = "studyrocket.desktop.widget.snapshot.v1"

    public static func load() -> DesktopWidgetSnapshot? {
        guard let data = UserDefaults(suiteName: group)?.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(DesktopWidgetSnapshot.self, from: data),
              snapshot.version == DesktopWidgetSnapshot.version else { return nil }
        return snapshot
    }

    @discardableResult
    public static func save(_ snapshot: DesktopWidgetSnapshot) -> Bool {
        guard let defaults = UserDefaults(suiteName: group),
              let data = try? JSONEncoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    public static func remove() {
        UserDefaults(suiteName: group)?.removeObject(forKey: key)
    }
}

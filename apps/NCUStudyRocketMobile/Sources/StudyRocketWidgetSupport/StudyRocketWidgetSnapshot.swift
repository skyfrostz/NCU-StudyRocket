import Foundation

/// The Home Screen widget receives only this reduced, read-only projection of
/// a Host snapshot. Markdown, pairing credentials, drafts, and chat history
/// never leave the main app's private container.
public enum StudyRocketWidgetConfiguration {
    public static let kind = "NCUStudyRocketWidget"
    public static let appGroupIdentifier = appGroupIdentifier(in: Bundle.main.infoDictionary ?? [:])
    public static let urlScheme = urlScheme(in: Bundle.main.infoDictionary ?? [:])
    fileprivate static let snapshotKey = "studyrocket.widget.snapshot.v1"

    static func appGroupIdentifier(in infoDictionary: [String: Any]) -> String {
        configuredValue(
            in: infoDictionary,
            key: "StudyRocketAppGroupIdentifier",
            fallback: "group.com.skyfrost.ncustudyrocket"
        )
    }

    static func urlScheme(in infoDictionary: [String: Any]) -> String {
        configuredValue(
            in: infoDictionary,
            key: "StudyRocketURLScheme",
            fallback: "ncustudyrocket"
        )
    }

    private static func configuredValue(in infoDictionary: [String: Any], key: String, fallback: String) -> String {
        guard let rawValue = infoDictionary[key] as? String else { return fallback }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("$(") else { return fallback }
        return value
    }
}

public struct StudyRocketWidgetPeriod: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let text: String
    public let isCompleted: Bool

    public init(id: String, title: String, text: String, isCompleted: Bool) {
        self.id = id
        self.title = title
        self.text = text
        self.isCompleted = isCompleted
    }
}

/// The Widget owns its presentation model so the extension never needs the
/// broader shared timetable protocol or a connection to the Host.
public enum StudyRocketWidgetTimetableStatus: String, Codable, Equatable, Sendable {
    case unavailable
    case available
    case notImported
    case invalid
    case beforeTerm
    case afterTerm
}

public struct StudyRocketWidgetLesson: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    /// Start and end time are intentionally split across two compact lines.
    public let timeLabel: String
    public let title: String
    public let location: String?

    public init(id: String, timeLabel: String, title: String, location: String?) {
        self.id = id
        self.timeLabel = timeLabel
        self.title = title
        self.location = location
    }
}

/// A compact projection shared through the iOS App Group. The date key guards
/// against presenting yesterday's plan as if it were today's after midnight.
public struct StudyRocketWidgetSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let referenceDay: String
    public let updatedAt: Date
    public let dateLabel: String
    public let nextTask: String?
    public let nextTaskPeriodTitle: String?
    public let todayPeriods: [StudyRocketWidgetPeriod]
    public let completedToday: Int
    public let totalToday: Int
    public let completedDeliveries: Int
    public let totalDeliveries: Int
    public let firstOpenDelivery: String?
    public let timetableStatus: StudyRocketWidgetTimetableStatus
    public let hasTodayTimetableDay: Bool
    public let totalTodayLessons: Int
    public let todayLessons: [StudyRocketWidgetLesson]

    public init(
        referenceDay: String,
        updatedAt: Date,
        dateLabel: String,
        nextTask: String?,
        nextTaskPeriodTitle: String?,
        todayPeriods: [StudyRocketWidgetPeriod],
        completedToday: Int,
        totalToday: Int,
        completedDeliveries: Int,
        totalDeliveries: Int,
        firstOpenDelivery: String?,
        timetableStatus: StudyRocketWidgetTimetableStatus = .unavailable,
        hasTodayTimetableDay: Bool = false,
        totalTodayLessons: Int = 0,
        todayLessons: [StudyRocketWidgetLesson] = []
    ) {
        version = Self.currentVersion
        self.referenceDay = referenceDay
        self.updatedAt = updatedAt
        self.dateLabel = dateLabel
        self.nextTask = nextTask
        self.nextTaskPeriodTitle = nextTaskPeriodTitle
        self.todayPeriods = todayPeriods
        self.completedToday = completedToday
        self.totalToday = totalToday
        self.completedDeliveries = completedDeliveries
        self.totalDeliveries = totalDeliveries
        self.firstOpenDelivery = firstOpenDelivery
        self.timetableStatus = timetableStatus
        self.hasTodayTimetableDay = hasTodayTimetableDay
        self.totalTodayLessons = totalTodayLessons
        self.todayLessons = todayLessons
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case referenceDay
        case updatedAt
        case dateLabel
        case nextTask
        case nextTaskPeriodTitle
        case todayPeriods
        case completedToday
        case totalToday
        case completedDeliveries
        case totalDeliveries
        case firstOpenDelivery
        case timetableStatus
        case hasTodayTimetableDay
        case totalTodayLessons
        case todayLessons
    }

    /// Version 1 snapshots were already stored in the App Group before the
    /// timetable column was added. Keeping their key/version readable avoids
    /// replacing a useful existing widget with an empty state during upgrade.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        referenceDay = try values.decode(String.self, forKey: .referenceDay)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        dateLabel = try values.decode(String.self, forKey: .dateLabel)
        nextTask = try values.decodeIfPresent(String.self, forKey: .nextTask)
        nextTaskPeriodTitle = try values.decodeIfPresent(String.self, forKey: .nextTaskPeriodTitle)
        todayPeriods = try values.decode([StudyRocketWidgetPeriod].self, forKey: .todayPeriods)
        completedToday = try values.decode(Int.self, forKey: .completedToday)
        totalToday = try values.decode(Int.self, forKey: .totalToday)
        completedDeliveries = try values.decode(Int.self, forKey: .completedDeliveries)
        totalDeliveries = try values.decode(Int.self, forKey: .totalDeliveries)
        firstOpenDelivery = try values.decodeIfPresent(String.self, forKey: .firstOpenDelivery)
        timetableStatus = try values.decodeIfPresent(StudyRocketWidgetTimetableStatus.self, forKey: .timetableStatus) ?? .unavailable
        hasTodayTimetableDay = try values.decodeIfPresent(Bool.self, forKey: .hasTodayTimetableDay) ?? false
        totalTodayLessons = try values.decodeIfPresent(Int.self, forKey: .totalTodayLessons) ?? 0
        todayLessons = try values.decodeIfPresent([StudyRocketWidgetLesson].self, forKey: .todayLessons) ?? []
    }

    public static func dayKey(for date: Date) -> String {
        let calendar = shanghaiCalendar
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    /// Adds a timeline entry at the next local day boundary so a stale
    /// snapshot cannot remain visible while WidgetKit waits to reload it.
    public static func nextDayBoundary(after date: Date) -> Date {
        let start = shanghaiCalendar.startOfDay(for: date)
        return shanghaiCalendar.date(byAdding: .day, value: 1, to: start)
            ?? date.addingTimeInterval(86_400)
    }

    private static var shanghaiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }
}

/// Access is deliberately centralized so both the app and WidgetKit extension
/// use the same versioned payload and App Group boundary.
public enum StudyRocketWidgetSnapshotStore {
    public static func load() -> StudyRocketWidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: StudyRocketWidgetConfiguration.appGroupIdentifier),
              let data = defaults.data(forKey: StudyRocketWidgetConfiguration.snapshotKey),
              let snapshot = try? JSONDecoder().decode(StudyRocketWidgetSnapshot.self, from: data),
              snapshot.version == StudyRocketWidgetSnapshot.currentVersion else {
            return nil
        }
        return snapshot
    }

    public static func save(_ snapshot: StudyRocketWidgetSnapshot) {
        guard let defaults = UserDefaults(suiteName: StudyRocketWidgetConfiguration.appGroupIdentifier),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: StudyRocketWidgetConfiguration.snapshotKey)
    }

    public static func remove() {
        UserDefaults(suiteName: StudyRocketWidgetConfiguration.appGroupIdentifier)?
            .removeObject(forKey: StudyRocketWidgetConfiguration.snapshotKey)
    }
}

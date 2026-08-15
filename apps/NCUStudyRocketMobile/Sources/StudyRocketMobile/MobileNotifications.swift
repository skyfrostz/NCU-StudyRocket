#if os(iOS)
import Foundation
import UserNotifications

public enum MobileReminderRoute: String, Codable, Sendable, Equatable {
    case daily
    case weekly
    case monthly

    var prompt: String {
        switch self {
        case .daily: "今天复盘：请先回答五项行为事实。"
        case .weekly: "本周总结：请基于已完成交付物和事实记录生成复盘。"
        case .monthly: "月度复盘：请汇总本月可证行为并决定下月重点。"
        }
    }
}

@MainActor
public final class MobileReminderScheduler: NSObject, UNUserNotificationCenterDelegate, ObservableObject {
    public static let shared = MobileReminderScheduler()
    @Published public private(set) var pendingRoute: MobileReminderRoute?
    @Published public private(set) var enabled: Bool

    private let center = UNUserNotificationCenter.current()

    private override init() {
        enabled = UserDefaults.standard.object(forKey: "studyrocket.mobileRemindersEnabled") as? Bool ?? true
        super.init()
        center.delegate = self
    }

    public func configure() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        guard enabled else {
            center.removeAllPendingNotificationRequests()
            return
        }
        await scheduleDaily()
        await scheduleWeekly()
        await scheduleNextMonthEnd()
    }

    public func scheduleDaily() async {
        await remove("studyrocket.daily")
        var components = DateComponents()
        components.timeZone = TimeZone(identifier: "Asia/Shanghai")
        components.hour = 21
        components.minute = 30
        await add(identifier: "studyrocket.daily", title: "StudyRocket 今日复盘", route: .daily, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true))
    }

    public func scheduleWeekly() async {
        await remove("studyrocket.weekly")
        var components = DateComponents()
        components.timeZone = TimeZone(identifier: "Asia/Shanghai")
        components.weekday = 1
        components.hour = 19
        components.minute = 30
        await add(identifier: "studyrocket.weekly", title: "StudyRocket 本周复盘", route: .weekly, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true))
    }

    public func scheduleNextMonthEnd(now: Date = .now) async {
        await remove("studyrocket.monthly")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let current = calendar.startOfDay(for: now)
        let currentEnd = calendar.dateInterval(of: .month, for: current).flatMap { calendar.date(byAdding: .day, value: -1, to: $0.end) }
        let candidate = currentEnd.flatMap { calendar.date(bySettingHour: 19, minute: 30, second: 0, of: $0) }
        let target: Date
        if let candidate, candidate > now {
            target = candidate
        } else {
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: current),
                  let monthInterval = calendar.dateInterval(of: .month, for: nextMonth),
                  let nextEnd = calendar.date(byAdding: .day, value: -1, to: monthInterval.end),
                  let nextTarget = calendar.date(bySettingHour: 19, minute: 30, second: 0, of: nextEnd) else { return }
            target = nextTarget
        }
        var components = calendar.dateComponents([.year, .month, .day], from: target)
        components.timeZone = calendar.timeZone
        components.hour = 19
        components.minute = 30
        await add(identifier: "studyrocket.monthly", title: "StudyRocket 月度复盘", route: .monthly, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo["route"] as? String
        await MainActor.run {
            self.pendingRoute = raw.flatMap(MobileReminderRoute.init(rawValue:))
        }
    }

    public func takePendingRoute() -> MobileReminderRoute? {
        defer { pendingRoute = nil }
        return pendingRoute
    }

    public func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: "studyrocket.mobileRemindersEnabled")
        Task { await configure() }
    }

    private func add(identifier: String, title: String, route: MobileReminderRoute, trigger: UNNotificationTrigger) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = route.prompt
        content.sound = .default
        content.userInfo = ["route": route.rawValue]
        await withCheckedContinuation { continuation in
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)) { _ in continuation.resume() }
        }
    }

    private func remove(_ identifier: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
#endif

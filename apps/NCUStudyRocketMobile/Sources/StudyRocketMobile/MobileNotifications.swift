#if os(iOS)
import Foundation
import UserNotifications
import StudyRocketShared
import UIKit

public enum MobileReminderRoute: String, Codable, Sendable, Equatable {
    case daily
    case weekly
    case monthly

    var prompt: String {
        switch self {
        case .daily: "今天有一件事想记下来吗？"
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

    @Published public private(set) var dailyEnabled = UserDefaults.standard.object(forKey: "studyrocket.factReminder") as? Bool ?? true
    @Published public private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published public private(set) var nextDaily: Date?
    private var recordedDays = Set<String>()
    private var configuring = false
    private var needsUpdate = false
    private let center = UNUserNotificationCenter.current()

    private override init() {
        enabled = UserDefaults.standard.object(forKey: "studyrocket.mobileRemindersEnabled") as? Bool ?? false
        super.init()
        center.delegate = self
    }

    public func updateRecords(_ days: Set<String>) async {
        recordedDays = days
        await configure()
    }

    public func requestPermission() async {
        if authorization == .denied, let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            await UIApplication.shared.open(url); return
        }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await configure()
    }

    public func setDailyEnabled(_ value: Bool) {
        dailyEnabled = value
        UserDefaults.standard.set(value, forKey: "studyrocket.factReminder")
        Task { if value && authorization == .notDetermined { await requestPermission() } else { await configure() } }
    }

    public func configure() async {
        needsUpdate = true
        guard !configuring else { return }
        configuring = true
        defer { configuring = false }
        while needsUpdate {
            needsUpdate = false
            authorization = await center.notificationSettings().authorizationStatus
            let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("studyrocket.daily") }
            center.removePendingNotificationRequests(withIdentifiers: ids)
            if authorization == .authorized || authorization == .provisional || authorization == .ephemeral {
                if dailyEnabled { await scheduleDaily() }
                if enabled { await scheduleWeekly(); await scheduleNextMonthEnd() }
            }
            if !enabled { center.removePendingNotificationRequests(withIdentifiers: ["studyrocket.weekly", "studyrocket.monthly"]) }
            nextDaily = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("studyrocket.daily") }
                .compactMap { ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() }.min()

        }
    }

    private func scheduleDaily() async {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = Date(), today = QuickFact.day(now)
        var time = DateComponents()
        time.timeZone = cal.timeZone; time.hour = 21; time.minute = 30
        if !recordedDays.contains(today) || (cal.date(bySettingHour: 21, minute: 30, second: 0, of: now) ?? now) <= now {
            await add(identifier: "studyrocket.daily", title: "记一件事", route: .daily, trigger: UNCalendarNotificationTrigger(dateMatching: time, repeats: true))
            return
        }
        // Skip only today's notification. Other weekdays repeat indefinitely. For today's
        // weekday queue the next year individually; the next foreground reconciles again.
        let weekday = cal.component(.weekday, from: now)
        for day in 1...7 where day != weekday {
            var match = time; match.weekday = day
            await add(identifier: "studyrocket.daily.w\(day)", title: "记一件事", route: .daily, trigger: UNCalendarNotificationTrigger(dateMatching: match, repeats: true))
        }
        for week in 1...52 {
            guard let day = cal.date(byAdding: .day, value: week * 7, to: now) else { continue }
            var match = cal.dateComponents([.year, .month, .day], from: day)
            match.timeZone = cal.timeZone; match.hour = 21; match.minute = 30
            await add(identifier: "studyrocket.daily.\(QuickFact.day(day))", title: "记一件事", route: .daily, trigger: UNCalendarNotificationTrigger(dateMatching: match, repeats: false))
        }
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
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
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
        if notification.request.content.userInfo["route"] as? String == "daily",
           await MainActor.run(body: { recordedDays.contains(QuickFact.day()) }) { return [] }
        return [.banner, .sound]
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
        Task { if value && authorization == .notDetermined { await requestPermission() } else { await configure() } }
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

import Foundation
import UserNotifications

enum ReminderRoute: String, CaseIterable, Identifiable {
    case daily, weekly, monthly
    var id: String { rawValue }
    var title: String {
        switch self { case .daily: "每日行为账"; case .weekly: "每周复盘与排期"; case .monthly: "月度复盘" }
    }
    var prompt: String {
        switch self {
        case .daily: return "今天复盘：先自然回应我今天的感受和处境；如果我想多谈一谈，先倾听并最多问一个开放问题，不要立刻把对话压成清单。等我愿意转入复盘后，再询问今日完成的具体交付物、净学习时长、入睡/起床、运动和明日第一任务。只记录我确认提供的事实，不记录情绪。"
        case .weekly: return "本周总结并排下周：先具体回应本周完成或受阻的部分；如果我更需要说说感受，先陪我梳理，确认我想转入行动后，再询问本周完成交付物、净学习时长、未完成原因和下周硬节点；最后给出保什么、砍什么和可勾选计划。"
        case .monthly: return "月度复盘：先自然回应本月的进展、偏差或困扰；若我想多谈一谈，先倾听并最多问一个开放问题，确认后再转入本月可证交付物、净学习时长、课程/英语/科研/保研变化和下月硬节点，随后再更新相关 Markdown。"
        }
    }
    var identifier: String { "studyrocket.reminder.\(rawValue)" }
}

@MainActor
final class ReminderScheduler: NSObject, ObservableObject {
    @Published var authorization = "未请求"
    @Published var enabled: [ReminderRoute: Bool] = [.daily: false, .weekly: false, .monthly: false]
    @Published var nextDates: [ReminderRoute: Date?] = [:]
    @Published private(set) var pendingRoute: ReminderRoute?
    private var permissionRequestInFlight = false
    private let disabled: Bool
    private let center = UNUserNotificationCenter.current()
    private var observers: [NSObjectProtocol] = []
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    init(disabled: Bool = false) {
        self.disabled = disabled
        super.init()
        guard !disabled else {
            authorization = "隔离自检已禁用"
            return
        }
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "studyrocket.chat", actions: [
                UNNotificationAction(identifier: "OPEN_CHAT", title: "打开学业对话", options: [.foreground])
            ], intentIdentifiers: [], options: [])
        ])
        for route in ReminderRoute.allCases {
            if let stored = UserDefaults.standard.object(forKey: "reminder.\(route.rawValue)") as? Bool {
                enabled[route] = stored
            } else {
                enabled[route] = false
                center.removePendingNotificationRequests(withIdentifiers: [route.identifier, "\(route.identifier).monthly"])
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.refreshAuthorization() } })
        observers.append(NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.refreshAuthorization() } })
        Task { await refreshAuthorization() }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func requestPermissionAndSchedule() {
        guard !disabled else { return }
        guard !permissionRequestInFlight else { return }
        permissionRequestInFlight = true
        Task {
            defer { permissionRequestInFlight = false }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                authorization = granted ? "已允许" : "已拒绝"
                if granted { await scheduleAll() }
            } catch { authorization = "请求失败" }
        }
    }

    func toggle(_ route: ReminderRoute, isOn: Bool) {
        guard !disabled else { return }
        enabled[route] = isOn; UserDefaults.standard.set(isOn, forKey: "reminder.\(route.rawValue)")
        Task { await reschedule(route) }
    }

    func sendTest(_ route: ReminderRoute) {
        guard !disabled else { return }
        let content = UNMutableNotificationContent(); content.title = "StudyRocket · \(route.title)"; content.body = "打开学业对话，开始今天的事实报告。"; content.sound = .default; content.categoryIdentifier = "studyrocket.chat"
        let request = UNNotificationRequest(identifier: "studyrocket.test.\(route.rawValue).\(UUID().uuidString)", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        center.add(request)
    }

    func refreshAuthorization() async {
        guard !disabled else { return }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus { case .authorized, .provisional: authorization = "已允许"; case .denied: authorization = "已拒绝"; case .notDetermined: authorization = "未请求"; @unknown default: authorization = "未知" }
        await scheduleAll()
    }

    func nextTriggerDate(_ route: ReminderRoute) -> Date? { nextDates[route] ?? nil }

    func takePendingRoute() -> ReminderRoute? {
        let route = pendingRoute
        pendingRoute = nil
        return route
    }

    private func scheduleAll() async {
        center.removePendingNotificationRequests(withIdentifiers: ReminderRoute.allCases.flatMap { [$0.identifier, "\($0.identifier).monthly"] })
        for route in ReminderRoute.allCases { nextDates[route] = nil }
        for route in ReminderRoute.allCases where enabled[route] == true { await schedule(route) }
    }

    private func reschedule(_ route: ReminderRoute) async {
        center.removePendingNotificationRequests(withIdentifiers: [route.identifier, "\(route.identifier).monthly"])
        nextDates[route] = nil
        if enabled[route] == true { await schedule(route) }
    }

    private func schedule(_ route: ReminderRoute) async {
        let content = UNMutableNotificationContent(); content.title = "StudyRocket · \(route.title)"; content.body = "点击进入学业对话，完成事实报告。"; content.sound = .default; content.categoryIdentifier = "studyrocket.chat"; content.userInfo = ["studyrocketRoute": route.rawValue]
        if route == .monthly {
            guard let next = nextMonthEnd() else { return }
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)
            components.timeZone = calendar.timeZone
            let request = UNNotificationRequest(identifier: "\(route.identifier).monthly", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            await add(request, route: route, date: next); return
        }
        var components = DateComponents(); components.timeZone = calendar.timeZone; components.hour = route == .daily ? 21 : 19; components.minute = 30
        if route == .weekly { components.weekday = 1 }
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: route.identifier, content: content, trigger: trigger)
        await add(request, route: route, date: trigger.nextTriggerDate())
    }

    private func add(_ request: UNNotificationRequest, route: ReminderRoute, date: Date?) async {
        do { try await center.add(request); nextDates[route] = date } catch { nextDates[route] = nil }
    }

    private func nextMonthEnd() -> Date? {
        let now = Date(); guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: now), let interval = calendar.dateInterval(of: .month, for: nextMonth) else { return nil }
        return calendar.date(bySettingHour: 19, minute: 30, second: 0, of: interval.end.addingTimeInterval(-1))
    }
}

extension ReminderScheduler: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo["studyrocketRoute"] as? String
        let route = raw.flatMap(ReminderRoute.init(rawValue:)) ?? .daily
        await MainActor.run {
            self.pendingRoute = route
            NotificationCenter.default.post(name: .studyRocketReminderRoute, object: route)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

extension Notification.Name { static let studyRocketReminderRoute = Notification.Name("studyRocketReminderRoute") }

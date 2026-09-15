import Foundation
import SwiftUI
import CryptoKit
import StudyRocketShared

struct WeeklyCell: Identifiable, Hashable {
    let id = UUID()
    var text: String
}

struct WeeklyDelivery: Identifiable, Hashable {
    let id = UUID()
    var text: String
    var isCompleted: Bool
}

struct WeeklyDeliveryPresentation: Equatable {
    let dateLabel: String?
    let body: String

    init(text: String, reference: Date = .now) {
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        guard let date = MarkdownParser.leadingDate(in: firstLine, relativeTo: reference) else {
            dateLabel = nil
            body = text
            return
        }
        let calendar = MarkdownParser.studyCalendar
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日 · EEE"
        dateLabel = formatter.string(from: date)
        let stripped = text.replacingOccurrences(
            of: #"^\s*(?:\d{4}-)?\d{1,2}\s*月\s*\d{1,2}\s*日?\s*[：:]\s*"#,
            with: "",
            options: .regularExpression
        )
        body = stripped.isEmpty ? text : stripped
    }
}

enum BufferRuleCategory: String, CaseIterable, Identifiable, Hashable {
    case daily
    case collision
    case minimum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: "日常缓冲"
        case .collision: "撞车降级"
        case .minimum: "最低底线"
        }
    }
}

struct BufferRule: Identifiable, Hashable {
    let id = UUID()
    var category: BufferRuleCategory
    var text: String
}

enum WeeklyPlanFormat: Equatable {
    case timeGrid
    case datedRows
}

struct WeeklyDatedRow: Identifiable, Hashable {
    let id = UUID()
    var dateLabel: String
    var text: String
    var isCompleted: Bool
}

struct WeeklyScheduledRow: Hashable {
    var dateLabel: String
    var slots: [String]
    var unassigned: String
    var isCompleted: Bool
}

struct WeeklyPlan {
    static let days = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    static let periods = ["上午", "中午", "晚上"]
    static let periodIDs = ["morning", "noon", "evening"]
    var format: WeeklyPlanFormat = .timeGrid
    var cells: [[String]] = Array(repeating: Array(repeating: "", count: 7), count: 3)
    var datedRows: [WeeklyDatedRow] = []
    var dayDateLabels: [String] = Array(repeating: "", count: 7)
    var unassignedByDay: [String] = Array(repeating: "", count: 7)
    var dayCompletion: [Bool] = Array(repeating: false, count: 7)
    var periodCompletion: [[Bool]] = Array(repeating: Array(repeating: false, count: 7), count: 3)
    var periodTaskCompletion: [String: Bool] = [:]
    var historicalRows: [WeeklyScheduledRow] = []
    var futureRows: [WeeklyScheduledRow] = []
    var migrationNotice: String?
    var isMigratedPreview = false
    var deliveries: [WeeklyDelivery] = []
    var buffer: String = "每天 17:00-18:30 弹性\n若全崩：只保最重要的一件事"
    var bufferRules: [BufferRule] = []

    func deliveriesExcluding(_ date: Date, calendar: Calendar = MarkdownParser.studyCalendar) -> [WeeklyDelivery] {
        deliveries.filter { delivery in
            guard let deliveryDate = MarkdownParser.leadingDate(in: delivery.text, relativeTo: date, calendar: calendar) else {
                return true
            }
            return !calendar.isDate(deliveryDate, inSameDayAs: date)
        }
    }

    func isToday(column: Int, date: Date = .now) -> Bool {
        guard dayDateLabels.indices.contains(column),
              let day = MarkdownParser.leadingDate(in: dayDateLabels[column], relativeTo: date) else { return false }
        return MarkdownParser.studyCalendar.isDate(day, inSameDayAs: date)
    }
}

struct TodayPeriodTask: Identifiable, Equatable {
    let id: String
    let dayID: String?
    let periodID: String
    let taskID: String?
    let period: String
    let task: String
    let isCompleted: Bool
}

struct DailyEntry: Identifiable {
    let id: String
    var date: String
    var deliverables: String
    var studyTime: String
    var sleep: String
    var exercise: String
    var firstTask: String
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published private(set) var plan = WeeklyPlan()
    @Published private(set) var timetable = StudyRocketTimetableParser.snapshot(from: nil)
    @Published private(set) var original = ""
    @Published private(set) var loadedHash = ""
    @Published private(set) var errorMessage: String?

    private let file = "工作台/下周计划.md"
    private var root: URL?

    var weekdayIndex: Int {
        let weekday = MarkdownParser.studyCalendar.component(.weekday, from: .now)
        return (weekday + 5) % 7
    }

    var todayCells: [TodayPeriodTask] { todayCells(on: .now) }

    func todayCells(on date: Date) -> [TodayPeriodTask] {
        let index = dayIndex(for: date)
        let dayID = index.flatMap { day in
            plan.dayDateLabels.indices.contains(day)
                ? Self.isoDate(from: plan.dayDateLabels[day], relativeTo: date)
                : nil
        }
        return WeeklyPlan.periods.enumerated().flatMap { periodIndex, period in
            let text = index.flatMap { day in
                plan.cells.indices.contains(periodIndex) && plan.cells[periodIndex].indices.contains(day)
                    ? plan.cells[periodIndex][day]
                    : nil
            } ?? ""
            let fallbackCompletion = index.map { day in
                plan.periodCompletion.indices.contains(periodIndex)
                    && plan.periodCompletion[periodIndex].indices.contains(day)
                    && plan.periodCompletion[periodIndex][day]
            } ?? false
            let periodID = WeeklyPlan.periodIDs[periodIndex]
            let tasks = PeriodTaskParser.tasks(from: text)
            guard !tasks.isEmpty else {
                return [TodayPeriodTask(
                    id: "\(dayID ?? "unplanned")|\(periodID)|empty",
                    dayID: dayID,
                    periodID: periodID,
                    taskID: nil,
                    period: period,
                    task: "",
                    isCompleted: false
                )]
            }
            return tasks.map { task in
                let taskKey = dayID.map { Self.periodTaskKey(dayID: $0, periodID: periodID, taskID: task.id) }
                return TodayPeriodTask(
                    id: taskKey ?? "\(periodID)|\(task.id)",
                    dayID: dayID,
                    periodID: periodID,
                    taskID: task.id,
                    period: period,
                    task: task.text,
                    isCompleted: taskKey.flatMap { plan.periodTaskCompletion[$0] } ?? fallbackCompletion
                )
            }
        }
    }

    var todayUnassigned: String {
        guard let index = dayIndex(for: .now) else { return "" }
        return plan.unassignedByDay.indices.contains(index) ? plan.unassignedByDay[index] : ""
    }

    var filteredDeliveries: [WeeklyDelivery] { plan.deliveries }
    var visibleDeliveries: [WeeklyDelivery] {
        filteredDeliveries.filter { !$0.isCompleted }.sorted { left, right in
            let lhs = deliverySortKey(left)
            let rhs = deliverySortKey(right)
            if lhs.group != rhs.group { return lhs.group < rhs.group }
            return lhs.date < rhs.date
        }
    }
    var completedDeliveries: Int { filteredDeliveries.filter(\.isCompleted).count }
    var visibleDeliveryCount: Int { filteredDeliveries.count }
    var firstOpenTask: String? {
        todayCells.first(where: { !$0.isCompleted && !$0.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.task
    }

    private static func weekdayIndex(for date: Date) -> Int {
        let weekday = MarkdownParser.studyCalendar.component(.weekday, from: date)
        return (weekday + 5) % 7
    }

    private func dayIndex(for date: Date) -> Int? {
        let dated = plan.dayDateLabels.enumerated().compactMap { index, label -> (Int, Date)? in
            guard let value = MarkdownParser.leadingDate(in: label, relativeTo: date) else { return nil }
            return (index, value)
        }
        if let match = dated.first(where: { MarkdownParser.studyCalendar.isDate($0.1, inSameDayAs: date) }) {
            return match.0
        }
        return dated.isEmpty ? Self.weekdayIndex(for: date) : nil
    }

    func load(from root: URL, referenceDate: Date = .now) {
        self.root = root
        let repository = MarkdownRepository(root: root)
        timetable = StudyRocketTimetableParser.snapshot(
            from: try? repository.read(StudyRocketTimetableParser.sourceFile),
            now: referenceDate
        )
        do {
            let text = try repository.read(file)
            original = text
            loadedHash = repository.hash(text)
            plan = MarkdownParser.weekly(text, referenceDate: referenceDate)
            errorMessage = nil
        } catch { errorMessage = "无法读取周计划：\(error.localizedDescription)" }
    }

    @discardableResult
    func toggleDelivery(_ id: UUID, workspace: WorkspaceStore) -> Bool {
        guard let index = plan.deliveries.firstIndex(where: { $0.id == id }) else { return false }
        let delivery = plan.deliveries[index]
        plan.deliveries[index].isCompleted.toggle()
        guard let root else {
            plan.deliveries[index].isCompleted.toggle()
            errorMessage = "周计划尚未加载，请稍后重试。"
            return false
        }
        let repository = MarkdownRepository(root: root)
        do {
            let replacement = try MarkdownParser.replaceDeliveryCompletion(
                in: original,
                with: plan,
                delivery: delivery,
                isCompleted: plan.deliveries[index].isCompleted
            )
            try repository.save(replacement, relative: file, loadedHash: loadedHash)
            original = replacement
            loadedHash = repository.hash(replacement)
            plan = MarkdownParser.weekly(replacement)
            errorMessage = nil
            workspace.refreshGitStatus()
            return true
        } catch {
            plan.deliveries[index].isCompleted.toggle()
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setPeriodTaskCompletion(
        _ task: TodayPeriodTask,
        isCompleted: Bool,
        on date: Date = .now,
        workspace: WorkspaceStore
    ) {
        guard let dayID = task.dayID,
              let taskID = task.taskID,
              let day = dayIndex(for: date),
              let period = WeeklyPlan.periodIDs.firstIndex(of: task.periodID),
              plan.cells.indices.contains(period), plan.cells[period].indices.contains(day) else { return }
        let text = plan.cells[period][day]
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              PeriodTaskParser.tasks(from: text).contains(where: { $0.id == taskID }) else { return }
        guard let root else {
            errorMessage = "周计划尚未加载，请稍后重试。"
            return
        }
        let repository = MarkdownRepository(root: root)
        do {
            let replacement = try MarkdownParser.replacePeriodTaskCompletion(
                in: original,
                dayID: dayID,
                periodID: task.periodID,
                periodText: text,
                taskID: taskID,
                isCompleted: isCompleted
            )
            try repository.save(replacement, relative: file, loadedHash: loadedHash)
            original = replacement
            loadedHash = repository.hash(replacement)
            plan = MarkdownParser.weekly(replacement)
            errorMessage = nil
            workspace.refreshGitStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func periodTaskKey(dayID: String, periodID: String, taskID: String) -> String {
        "\(dayID)|\(periodID)|\(taskID)"
    }

    private func deliverySortKey(_ delivery: WeeklyDelivery) -> (group: Int, date: Date) {
        guard let date = MarkdownParser.leadingDate(in: delivery.text, relativeTo: .now) else {
            return (delivery.isCompleted ? 3 : 2, .distantFuture)
        }
        if delivery.isCompleted { return (3, date) }
        return (date < MarkdownParser.studyCalendar.startOfDay(for: .now) ? 0 : 1, date)
    }

    private static func isoDate(from label: String, relativeTo reference: Date) -> String? {
        guard let date = MarkdownParser.leadingDate(in: label, relativeTo: reference) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = MarkdownParser.studyCalendar
        formatter.timeZone = MarkdownParser.studyCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

enum HabitProfileUpdater {
    private static let file = "工作台/助理偏好与习惯.md"

    static func update(after entry: DailyEntry, in root: URL) throws {
        let repository = MarkdownRepository(root: root)
        let existing = (try? repository.read(file)) ?? "# 助理偏好与习惯\n\n> 仅记录可证据的学习规律与用户明确表达的规划偏好；不记录情绪、页面点击、账号或隐私信息。\n\n## 已确认偏好\n\n- [待补]\n\n## 近 14 日行为摘要\n\n<!-- studyrocket:habits:start -->\n<!-- studyrocket:habits:end -->\n\n## 计划阻力规律\n\n<!-- studyrocket:friction:start -->\n- 证据不足：尚未有 3 次以上同类可证记录，不调整默认计划规则。\n<!-- studyrocket:friction:end -->\n\n## 候选习惯\n\n- 证据不足：连续至少 3 次可证记录后，才可在周复盘中建议调整工作流程。\n\n## 最后更新\n\n- 待补\n"
        let observation = "- \(entry.date)｜交付物：\(clean(entry.deliverables))｜净学习：\(clean(entry.studyTime))｜睡眠：\(clean(entry.sleep))｜运动：\(clean(entry.exercise))｜明日第一任务：\(clean(entry.firstTask))"
        let updated = replaceObservation(in: existing, date: entry.date, with: observation)
        let hash = repository.hash(existing)
        if FileManager.default.fileExists(atPath: repository.url(file).path) {
            try repository.save(updated, relative: file, loadedHash: hash)
        } else {
            let target = repository.url(file)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(updated.utf8).write(to: target, options: .atomic)
        }
    }

    private static func clean(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "待补" : trimmed.replacingOccurrences(of: "\n", with: " ")
    }

    private static func replaceObservation(in source: String, date: String, with observation: String) -> String {
        let start = "<!-- studyrocket:habits:start -->"
        let end = "<!-- studyrocket:habits:end -->"
        guard let startRange = source.range(of: start), let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else { return source }
        var observations = source[startRange.upperBound..<endRange.lowerBound].split(separator: "\n").map(String.init)
        observations.removeAll { $0.hasPrefix("- \(date)｜") }
        observations.append(observation)
        observations = Array(observations.suffix(14))
        var result = source
        result.replaceSubrange(startRange.upperBound..<endRange.lowerBound, with: "\n" + observations.joined(separator: "\n") + "\n")
        if let updatedRange = result.range(of: "## 最后更新"), let nextLine = result[updatedRange.upperBound...].range(of: "\n- ") {
            let lineEnd = result[nextLine.upperBound...].firstIndex(of: "\n") ?? result.endIndex
            result.replaceSubrange(nextLine.upperBound..<lineEnd, with: "\(date)（每日行为账保存后自动更新）")
        }
        return result
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case home, timetable, chat, week, daily, routes, baoyan, library, settings
    var id: String { rawValue }
    var title: String {
        switch self { case .home: "首页"; case .timetable: "课表"; case .chat: "学业对话"; case .week: "周计划"; case .daily: "每日复盘"; case .routes: "四条航线"; case .baoyan: "保研"; case .library: "资料库"; case .settings: "设置" }
    }
    var icon: String {
        switch self { case .home: "rectangle.grid.2x2"; case .timetable: "calendar.badge.clock"; case .chat: "bubble.left.and.bubble.right"; case .week: "calendar"; case .daily: "checkmark.circle"; case .routes: "point.3.connected.trianglepath.dotted"; case .baoyan: "arrow.up.right.circle"; case .library: "books.vertical"; case .settings: "gearshape" }
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var rootURL: URL
    @Published var gitStatus = "读取中..."
    @Published var errorMessage: String?
    @Published private(set) var markdownIndex: [String] = []
    private var timer: Timer?
    private var gitRefreshTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?

    init() {
        let saved = UserDefaults.standard.string(forKey: "workspaceRoot").map(URL.init(fileURLWithPath:))
        rootURL = saved ?? URL(fileURLWithPath: "/Users/skyfrost/Desktop/大学")
        refreshGitStatus()
        refreshMarkdownIndex()
    }

    var isValid: Bool { FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("AGENTS.md").path) && FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("PROFILE.md").path) }

    func bind(to url: URL) {
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("AGENTS.md").path), FileManager.default.fileExists(atPath: url.appendingPathComponent("PROFILE.md").path) else { errorMessage = "所选目录不是 StudyRocket 仓库：缺少 AGENTS.md 或 PROFILE.md。"; return }
        gitRefreshTask?.cancel()
        gitRefreshTask = nil
        indexTask?.cancel()
        indexTask = nil
        rootURL = url.standardizedFileURL
        UserDefaults.standard.set(rootURL.path, forKey: "workspaceRoot")
        refreshGitStatus()
        refreshMarkdownIndex()
    }

    func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshGitStatus() } }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        gitRefreshTask?.cancel()
        gitRefreshTask = nil
        indexTask?.cancel()
        indexTask = nil
    }

    func refreshGitStatus() {
        guard gitRefreshTask == nil else { return }
        let root = rootURL
        gitRefreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Self.gitStatus(at: root) }.value
            guard !Task.isCancelled, let self, self.rootURL == root else { return }
            self.gitStatus = result
            self.gitRefreshTask = nil
        }
    }

    func refreshMarkdownIndex() {
        indexTask?.cancel()
        let root = rootURL
        indexTask = Task { [weak self] in
            let index = await Task.detached(priority: .utility) { MarkdownRepository(root: root).markdownFiles() }.value
            guard !Task.isCancelled, let self, self.rootURL == root else { return }
            self.markdownIndex = index
            self.indexTask = nil
        }
    }

    private nonisolated static func gitStatus(at root: URL) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "status", "--porcelain"]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "已同步" : "存在未提交修改"
        } catch { return "无法读取 Git 状态" }
    }
}

enum MarkdownError: LocalizedError { case outsideWorkspace, nonMarkdown, conflict, invalidManagedBlock
    var errorDescription: String? { switch self { case .outsideWorkspace: "文件不在当前仓库内"; case .nonMarkdown: "只允许编辑 Markdown 文件"; case .conflict: "文件已被其他程序修改"; case .invalidManagedBlock: "时段完成状态边界已损坏，请先修复计划文件" } }
}

final class MarkdownRepository {
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL }
    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
    func read(_ relative: String) throws -> String {
        try String(contentsOf: validatedMarkdownURL(relative), encoding: .utf8)
    }
    func hash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func save(_ content: String, relative: String, loadedHash: String) throws {
        let target = try validatedMarkdownURL(relative)
        let current = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        guard hash(current) == loadedHash else { throw MarkdownError.conflict }
        let backupDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NCU StudyRocket/Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        if let old = try? Data(contentsOf: target) { let name = relative.replacingOccurrences(of: "/", with: "_") + "." + String(Int(Date().timeIntervalSince1970)); try? old.write(to: backupDir.appendingPathComponent(name)) }
        try Data(content.utf8).write(to: target, options: .atomic)
        pruneBackups(in: backupDir, prefix: relative.replacingOccurrences(of: "/", with: "_") + ".")
    }

    private func validatedMarkdownURL(_ relative: String) throws -> URL {
        let target = url(relative).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedTarget = target.resolvingSymlinksInPath()
        guard resolvedTarget.path.hasPrefix(resolvedRoot.path + "/") else { throw MarkdownError.outsideWorkspace }
        guard target.pathExtension.lowercased() == "md" else { throw MarkdownError.nonMarkdown }
        guard !Self.isSymbolicLink(target) else { throw MarkdownError.outsideWorkspace }
        return target
    }

    private func pruneBackups(in dir: URL, prefix: String) { let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]))?.filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []; for file in files.dropFirst(20) { try? FileManager.default.removeItem(at: file) } }
    func markdownFiles() -> [String] {
        let excluded = Set([".git", ".build", "PDF提取文本", "Backups"])
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        return enumerator?.compactMap { item in
            guard let url = item as? URL else { return nil }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if relative.split(separator: "/").contains(where: { excluded.contains(String($0)) }) { return nil }
            guard url.pathExtension.lowercased() == "md", !Self.isSymbolicLink(url) else { return nil }
            return relative
        }.sorted() ?? []
    }

    static func isSymbolicLink(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false }
}

struct MarkdownChangeProposal: Identifiable, Hashable {
    let id = UUID()
    let turnID: String
    let relativePath: String
    let originalContent: String
    let proposedContent: String
    let reason: String
    let baseHash: String
    var isSelected = true
}

struct SkillChangeProposal: Identifiable, Hashable {
    let id = UUID()
    let turnID: String
    let relativePath: String
    let originalContent: String
    let proposedContent: String
    let reason: String
    let baseHash: String
    var isSelected = true
}

enum MarkdownMode: String, CaseIterable, Identifiable { case preview, edit
    var id: String { rawValue }
    var title: String { self == .preview ? "查看" : "编辑" }
}

@MainActor
final class MarkdownDocumentModel: ObservableObject {
    @Published private(set) var relative: String?
    @Published var text = ""
    @Published private(set) var original = ""
    @Published private(set) var loadedHash = ""
    @Published var mode: MarkdownMode = .preview
    @Published var errorMessage: String?

    private var root: URL
    init(root: URL) { self.root = root }
    var isDirty: Bool { text != original }

    func updateRoot(_ root: URL) {
        guard self.root.standardizedFileURL != root.standardizedFileURL else { return }
        self.root = root; relative = nil; text = ""; original = ""; loadedHash = ""; mode = .preview
    }
    func load(_ relative: String) {
        let repo = MarkdownRepository(root: root)
        do { let contents = try repo.read(relative); self.relative = relative; original = contents; text = contents; loadedHash = repo.hash(contents); mode = .preview; errorMessage = nil }
        catch { errorMessage = "无法读取 \(relative)：\(error.localizedDescription)" }
    }
    func discardAndLoad(_ relative: String) { load(relative) }
    func save() -> Bool {
        guard let relative else { return true }
        do { let repo = MarkdownRepository(root: root); try repo.save(text, relative: relative, loadedHash: loadedHash); original = text; loadedHash = repo.hash(text); errorMessage = nil; return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
}

private struct PeriodCompletionKey: Hashable {
    let dayID: String
    let periodID: String
    let textHash: String
}

private struct PeriodCompletionEntry: Hashable {
    let dayID: String
    let periodID: String
    let textHash: String
    let source: String?

    var key: PeriodCompletionKey {
        PeriodCompletionKey(dayID: dayID, periodID: periodID, textHash: textHash)
    }
}

enum MarkdownParser {
    static var studyCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        calendar.firstWeekday = 2
        return calendar
    }

    static func weekly(_ text: String, referenceDate: Date = .now) -> WeeklyPlan {
        var plan = WeeklyPlan()
        let lines = text.components(separatedBy: .newlines)
        let weeklyRange = managedWeeklyRange(in: lines) ?? lines.indices
        if let start = weeklyRange.first(where: { isStructuredWeekHeader(lines[$0]) }) {
            parseStructuredWeek(lines: lines, headerIndex: start, range: weeklyRange, referenceDate: referenceDate, into: &plan)
        } else if let start = weeklyRange.first(where: { isLegacyDatedHeader(lines[$0]) }) {
            parseLegacyDatedWeek(lines: lines, headerIndex: start, range: weeklyRange, referenceDate: referenceDate, into: &plan)
        } else if let start = weeklyRange.first(where: { isTimeGridHeader(lines[$0]) }) {
            parseLegacyTimeGrid(lines: lines, headerIndex: start, range: weeklyRange, referenceDate: referenceDate, into: &plan)
        }
        if let start = lines.firstIndex(where: { $0.contains("## 交付物") }) {
            let range = managedSectionContent(lines, headingIndex: start).content
            var current: (text: String, completed: Bool)?
            for line in lines[range] {
                if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") || line.hasPrefix("- [ ] ") {
                    if let current { plan.deliveries.append(WeeklyDelivery(text: current.text, isCompleted: current.completed)) }
                    let completed = line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ")
                    current = (String(line.dropFirst(6)), completed)
                } else if line.hasPrefix("  "), current != nil {
                    current!.text += "\n" + line.drop(while: { $0 == " " })
                }
            }
            if let current { plan.deliveries.append(WeeklyDelivery(text: current.text, isCompleted: current.completed)) }
        }
        if let start = lines.firstIndex(where: { $0.contains("## 缓冲") }) {
            plan.bufferRules = parseBufferRules(lines, headingIndex: start)
            if !plan.bufferRules.isEmpty {
                plan.buffer = plan.bufferRules.map(\.text).joined(separator: "\n")
            }
        }
        applyPeriodCompletions(in: lines, referenceDate: referenceDate, to: &plan)
        return plan
    }

    static func replaceWeekly(
        _ old: String,
        with plan: WeeklyPlan,
        deliverySourceMigrations: [String: String] = [:]
    ) -> String {
        var lines = old.components(separatedBy: .newlines)
        let table = structuredWeekTable(for: plan)
            + hiddenRowsTable(plan.historicalRows, markers: ("studyrocket:weekly:history:start", "studyrocket:weekly:history:end"))
            + hiddenRowsTable(plan.futureRows, markers: ("studyrocket:weekly:future:start", "studyrocket:weekly:future:end"))
        if let managed = managedWeeklyRange(in: lines) {
            lines.replaceSubrange(managed, with: table)
        } else if let header = lines.indices.first(where: {
            isStructuredWeekHeader(lines[$0]) || isLegacyDatedHeader(lines[$0]) || isTimeGridHeader(lines[$0])
        }) {
            var end = header
            while end < lines.count, lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("|") { end += 1 }
            lines.replaceSubrange(header..<end, with: table.filter { !$0.isEmpty })
        }
        if let start = lines.firstIndex(where: { $0.contains("## 交付物") }) {
            let section = managedSectionContent(lines, headingIndex: start, markers: ("studyrocket:deliveries:start", "studyrocket:deliveries:end"))
            let deliveryLines = plan.deliveries.isEmpty ? ["- [ ] 待生成"] : plan.deliveries.flatMap { delivery -> [String] in
                let pieces = delivery.text.components(separatedBy: .newlines)
                guard let first = pieces.first else { return ["- [\(delivery.isCompleted ? "x" : " ")] "] }
                return ["- [\(delivery.isCompleted ? "x" : " ")] \(first)"] + pieces.dropFirst().map { "  \($0)" }
            }
            if section.hasMarkers {
                lines.replaceSubrange(section.content, with: deliveryLines)
            } else {
                lines.replaceSubrange(section.content, with: ["<!-- studyrocket:deliveries:start -->"] + deliveryLines + ["<!-- studyrocket:deliveries:end -->"])
            }
        }
        if let start = lines.firstIndex(where: { $0.contains("## 缓冲") }) {
            let section = managedSectionContent(lines, headingIndex: start, markers: ("studyrocket:buffer:start", "studyrocket:buffer:end"))
            let rules = plan.bufferRules.isEmpty
                ? legacyBufferRules(from: plan.buffer)
                : plan.bufferRules
            let bufferLines = structuredBufferLines(for: rules)
            if section.hasMarkers {
                lines.replaceSubrange(section.content, with: bufferLines)
            } else {
                lines.replaceSubrange(section.content, with: ["<!-- studyrocket:buffer:start -->"] + bufferLines + ["<!-- studyrocket:buffer:end -->"])
            }
        }
        return reconcilePeriodCompletions(
            in: lines.joined(separator: "\n"),
            with: plan,
            deliverySourceMigrations: deliverySourceMigrations
        )
    }

    static func replaceDeliveryCompletion(
        in source: String,
        with plan: WeeklyPlan,
        delivery: WeeklyDelivery,
        isCompleted: Bool
    ) throws -> String {
        let updated = replaceWeekly(source, with: plan)
        var records = Set(try periodCompletionRecords(in: updated))
        let deliverySource = DeliveryPeriodMatcher.sourceKey(for: delivery.text)
        if isCompleted, let dayID = deliveryDayID(delivery.text) {
            for period in periods(on: dayID, in: plan)
                where !period.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                for task in PeriodTaskParser.tasks(from: period.text)
                    where DeliveryPeriodMatcher.matches(deliveryText: delivery.text, periodText: task.text) {
                    records.insert(PeriodCompletionEntry(
                        dayID: dayID,
                        periodID: period.id,
                        textHash: task.id,
                        source: deliverySource
                    ))
                }
            }
        } else if !isCompleted {
            records = Set(records.filter { $0.source != deliverySource })
        }
        return try replacingPeriodCompletionBlock(in: updated, records: Array(records))
    }

    static func replacePeriodCompletion(
        in source: String,
        dayID: String,
        periodID: String,
        text: String,
        isCompleted: Bool
    ) throws -> String {
        guard WeeklyPlan.periodIDs.contains(periodID), isoDate(dayID) != nil else { throw MarkdownError.invalidManagedBlock }
        var records = try periodCompletionRecords(in: source)
        records.removeAll { $0.dayID == dayID && $0.periodID == periodID }
        if isCompleted {
            records.append(PeriodCompletionEntry(dayID: dayID, periodID: periodID, textHash: periodTextHash(text), source: nil))
        }
        return try replacingPeriodCompletionBlock(in: source, records: records)
    }

    static func replacePeriodTaskCompletion(
        in source: String,
        dayID: String,
        periodID: String,
        periodText: String,
        taskID: String,
        isCompleted: Bool
    ) throws -> String {
        guard WeeklyPlan.periodIDs.contains(periodID),
              isoDate(dayID) != nil,
              PeriodCompletion.isTaskKey(taskID) else { throw MarkdownError.invalidManagedBlock }
        let tasks = PeriodTaskParser.tasks(from: periodText)
        guard tasks.contains(where: { $0.id == taskID }) else { throw MarkdownError.invalidManagedBlock }

        var records = try periodCompletionRecords(in: source)
        let legacyHash = periodTextHash(periodText)
        let legacyRecords = records.filter {
            $0.dayID == dayID && $0.periodID == periodID && $0.textHash == legacyHash
        }
        records.removeAll {
            $0.dayID == dayID && $0.periodID == periodID && $0.textHash == legacyHash
        }
        for legacy in legacyRecords {
            for task in tasks {
                records.append(PeriodCompletionEntry(
                    dayID: dayID,
                    periodID: periodID,
                    textHash: task.id,
                    source: legacy.source
                ))
            }
        }
        records.removeAll {
            $0.dayID == dayID && $0.periodID == periodID && $0.textHash == taskID
        }
        if isCompleted {
            records.append(PeriodCompletionEntry(dayID: dayID, periodID: periodID, textHash: taskID, source: nil))
        }
        return try replacingPeriodCompletionBlock(in: source, records: records)
    }

    private static func applyPeriodCompletions(in lines: [String], referenceDate: Date, to plan: inout WeeklyPlan) {
        guard let records = try? periodCompletionRecords(in: lines.joined(separator: "\n")) else { return }
        let completedKeys = Set(records.map(\.key))
        for day in 0..<min(plan.dayDateLabels.count, 7) {
            guard let date = leadingDate(in: plan.dayDateLabels[day], relativeTo: referenceDate) else { continue }
            let dayID = isoDateString(date)
            for period in 0..<min(plan.cells.count, WeeklyPlan.periodIDs.count) where plan.cells[period].indices.contains(day) {
                let text = plan.cells[period][day]
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let periodID = WeeklyPlan.periodIDs[period]
                let legacy = PeriodCompletionEntry(
                    dayID: dayID,
                    periodID: periodID,
                    textHash: periodTextHash(text),
                    source: nil
                )
                let legacyCompleted = completedKeys.contains(legacy.key)
                let tasks = PeriodTaskParser.tasks(from: text)
                let taskStates = tasks.map { task -> Bool in
                    let completed = legacyCompleted || completedKeys.contains(PeriodCompletionEntry(
                        dayID: dayID,
                        periodID: periodID,
                        textHash: task.id,
                        source: nil
                    ).key)
                    plan.periodTaskCompletion[periodTaskKey(dayID: dayID, periodID: periodID, taskID: task.id)] = completed
                    return completed
                }
                plan.periodCompletion[period][day] = !taskStates.isEmpty && taskStates.allSatisfy { $0 }
            }
        }
    }

    private static func reconcilePeriodCompletions(
        in source: String,
        with plan: WeeklyPlan,
        deliverySourceMigrations: [String: String]
    ) -> String {
        guard source.contains("studyrocket:period-completion:start"),
              let records = try? periodCompletionRecords(in: source) else { return source }
        let migrated = records.map { record -> PeriodCompletionEntry in
            guard let oldSource = record.source, let newSource = deliverySourceMigrations[oldSource] else { return record }
            return PeriodCompletionEntry(dayID: record.dayID, periodID: record.periodID, textHash: record.textHash, source: newSource)
        }
        let valid = periodCompletionKeys(in: plan)
        return (try? replacingPeriodCompletionBlock(in: source, records: migrated.filter { valid.contains($0.key) })) ?? source
    }

    private static func periodCompletionRecords(in source: String) throws -> [PeriodCompletionEntry] {
        let lines = source.components(separatedBy: .newlines)
        let starts = lines.indices.filter { lines[$0].contains("studyrocket:period-completion:start") }
        let ends = lines.indices.filter { lines[$0].contains("studyrocket:period-completion:end") }
        guard starts.count <= 1, ends.count <= 1, starts.count == ends.count else { throw MarkdownError.invalidManagedBlock }
        guard let start = starts.first, let end = ends.first else { return [] }
        guard start < end else { throw MarkdownError.invalidManagedBlock }
        return lines[(start + 1)..<end].compactMap { line in
            guard let cells = splitTableRow(line), cells.count >= 4,
                  isoDate(cells[0]) != nil,
                  WeeklyPlan.periodIDs.contains(cells[1]),
                  PeriodCompletion.isValidRecordKey(cells[2]),
                  parseBoolean(cells[3]) else { return nil }
            let source = cells.indices.contains(4) ? cells[4].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            guard source.isEmpty || source.range(of: #"^delivery:[0-9a-f]{64}$"#, options: .regularExpression) != nil else { return nil }
            return PeriodCompletionEntry(
                dayID: cells[0],
                periodID: cells[1],
                textHash: cells[2].lowercased(),
                source: source.isEmpty ? nil : source
            )
        }
    }

    private static func replacingPeriodCompletionBlock(in source: String, records: [PeriodCompletionEntry]) throws -> String {
        var lines = source.components(separatedBy: .newlines)
        let starts = lines.indices.filter { lines[$0].contains("studyrocket:period-completion:start") }
        let ends = lines.indices.filter { lines[$0].contains("studyrocket:period-completion:end") }
        guard starts.count <= 1, ends.count <= 1, starts.count == ends.count else { throw MarkdownError.invalidManagedBlock }
        if let start = starts.first, let end = ends.first {
            guard start < end else { throw MarkdownError.invalidManagedBlock }
            lines.removeSubrange(start...end)
        }
        guard let weeklyEnd = lines.firstIndex(where: { $0.contains("studyrocket:weekly:end") }) else { throw MarkdownError.invalidManagedBlock }
        let order = ["morning": 0, "noon": 1, "evening": 2]
        let unique = Array(Set(records)).sorted {
            ($0.dayID, order[$0.periodID] ?? .max, $0.textHash, $0.source ?? "")
                < ($1.dayID, order[$1.periodID] ?? .max, $1.textHash, $1.source ?? "")
        }
        let block = [
            "<!-- studyrocket:period-completion:start -->",
            "| 日期 | 时段 | 任务标识 | 完成 | 来源 |",
            "|------|------|----------|------|------|"
        ] + unique.map { "| \($0.dayID) | \($0.periodID) | \($0.textHash) | [x] | \($0.source ?? "") |" }
            + ["<!-- studyrocket:period-completion:end -->"]
        lines.insert(contentsOf: block, at: weeklyEnd + 1)
        return lines.joined(separator: "\n")
    }

    private static func periodCompletionKeys(in plan: WeeklyPlan) -> Set<PeriodCompletionKey> {
        var keys = Set<PeriodCompletionKey>()
        for day in 0..<min(plan.dayDateLabels.count, 7) {
            guard let date = leadingDate(in: plan.dayDateLabels[day], relativeTo: .now) else { continue }
            let dayID = isoDateString(date)
            for period in 0..<min(plan.cells.count, WeeklyPlan.periodIDs.count) where plan.cells[period].indices.contains(day) {
                let text = plan.cells[period][day]
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let periodID = WeeklyPlan.periodIDs[period]
                keys.insert(PeriodCompletionKey(dayID: dayID, periodID: periodID, textHash: periodTextHash(text)))
                for task in PeriodTaskParser.tasks(from: text) {
                    keys.insert(PeriodCompletionKey(dayID: dayID, periodID: periodID, textHash: task.id))
                }
            }
        }
        for row in plan.historicalRows + plan.futureRows {
            guard let date = leadingDate(in: row.dateLabel, relativeTo: .now) else { continue }
            let dayID = isoDateString(date)
            for (index, text) in row.slots.prefix(WeeklyPlan.periodIDs.count).enumerated()
                where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let periodID = WeeklyPlan.periodIDs[index]
                keys.insert(PeriodCompletionKey(dayID: dayID, periodID: periodID, textHash: periodTextHash(text)))
                for task in PeriodTaskParser.tasks(from: text) {
                    keys.insert(PeriodCompletionKey(dayID: dayID, periodID: periodID, textHash: task.id))
                }
            }
        }
        return keys
    }

    private static func deliveryDayID(_ text: String) -> String? {
        leadingDate(in: text, relativeTo: .now).map(isoDateString)
    }

    private static func periods(on dayID: String, in plan: WeeklyPlan) -> [(id: String, text: String)] {
        for day in 0..<min(plan.dayDateLabels.count, 7) {
            guard let date = leadingDate(in: plan.dayDateLabels[day], relativeTo: .now), isoDateString(date) == dayID else { continue }
            return WeeklyPlan.periodIDs.enumerated().map { index, id in
                let text = plan.cells.indices.contains(index) && plan.cells[index].indices.contains(day)
                    ? plan.cells[index][day]
                    : ""
                return (id, text)
            }
        }
        if let row = (plan.historicalRows + plan.futureRows).first(where: {
            guard let date = leadingDate(in: $0.dateLabel, relativeTo: .now) else { return false }
            return isoDateString(date) == dayID
        }) {
            return WeeklyPlan.periodIDs.enumerated().map { index, id in
                (id, row.slots.indices.contains(index) ? row.slots[index] : "")
            }
        }
        return []
    }

    private static func periodTaskKey(dayID: String, periodID: String, taskID: String) -> String {
        "\(dayID)|\(periodID)|\(taskID)"
    }

    private static func isoDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = studyCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = studyCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    private static func isoDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = studyCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = studyCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func periodTextHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func leadingDate(in text: String, relativeTo reference: Date, calendar: Calendar = studyCalendar) -> Date? {
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        let normalized = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = normalized.components(separatedBy: CharacterSet(charactersIn: "：:")).first ?? normalized
        let isoPattern = #"^\s*(\d{4})-(\d{1,2})-(\d{1,2})(?:\s|$)"#
        if let values = captureGroups(isoPattern, in: prefix), values.count == 3,
           let year = Int(values[0]), let month = Int(values[1]), let day = Int(values[2]) {
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        }
        let chinesePattern = #"^\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日?(?:\s|$)"#
        guard let values = captureGroups(chinesePattern, in: prefix), values.count == 2,
              let month = Int(values[0]), let day = Int(values[1]) else { return nil }
        let referenceYear = calendar.component(.year, from: reference)
        return (referenceYear - 1...referenceYear + 1).compactMap { year in
            calendar.date(from: DateComponents(year: year, month: month, day: day))
        }.min { abs($0.timeIntervalSince(reference)) < abs($1.timeIntervalSince(reference)) }
    }

    private static func parseStructuredWeek(lines: [String], headerIndex: Int, range: Range<Int>, referenceDate: Date, into plan: inout WeeklyPlan) {
        plan.format = .timeGrid
        var rows: [(label: String, slots: [String], unassigned: String, completed: Bool)] = []
        var index = headerIndex + 2
        while index < range.upperBound {
            if lines[index].contains("studyrocket:weekly:history:start") || lines[index].contains("studyrocket:weekly:future:start") {
                let marker = lines[index].contains("history") ? "studyrocket:weekly:history:end" : "studyrocket:weekly:future:end"
                while index < range.upperBound && !lines[index].contains(marker) { index += 1 }
                index += 1
                continue
            }
            guard let parts = splitTableRow(lines[index]), parts.count >= 4 else { index += 1; continue }
            if parts.first?.contains("---") == true { index += 1; continue }
            let slots = (1...3).map { parts.indices.contains($0) ? decodeTableText(parts[$0]) : "" }
            let unassigned = parts.indices.contains(4) ? decodeTableText(parts[4]) : ""
            let completed = parts.indices.contains(5) ? parseBoolean(parts[5]) : false
            rows.append((decodeTableText(parts[0]), slots, unassigned, completed))
            index += 1
        }
        rows += scheduledRows(in: lines, markers: ("studyrocket:weekly:history:start", "studyrocket:weekly:history:end"))
        rows += scheduledRows(in: lines, markers: ("studyrocket:weekly:future:start", "studyrocket:weekly:future:end"))
        populateWeek(rows: rows, relativeTo: referenceDate, into: &plan)
    }

    private static func parseLegacyDatedWeek(lines: [String], headerIndex: Int, range: Range<Int>, referenceDate: Date, into plan: inout WeeklyPlan) {
        plan.format = .timeGrid
        plan.isMigratedPreview = true
        var rows: [(label: String, slots: [String], unassigned: String, completed: Bool)] = []
        var index = headerIndex + 2
        while index < range.upperBound, let parts = splitTableRow(lines[index]), parts.count >= 2 {
            let parsed = parseCompletion(parts[1])
            let row = WeeklyDatedRow(dateLabel: decodeTableText(parts[0]), text: parsed.text, isCompleted: parsed.completed)
            plan.datedRows.append(row)
            let split = splitLegacyDayText(row.text)
            rows.append((row.dateLabel, split.slots, split.unassigned, row.isCompleted))
            index += 1
        }
        populateWeek(rows: rows, relativeTo: referenceDate, into: &plan)
        let unresolved = plan.unassignedByDay.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        plan.migrationNotice = unresolved == 0
            ? "已将旧版按日期计划拆分为上午、中午、晚上预览；保存前请核对时段。"
            : "已生成三时段预览；其中 \(unresolved) 天无法安全拆分，原文保留在待分配区域。"
    }

    private static func parseLegacyTimeGrid(lines: [String], headerIndex: Int, range: Range<Int>, referenceDate: Date, into plan: inout WeeklyPlan) {
        plan.format = .timeGrid
        var source = Array(repeating: Array(repeating: "", count: 7), count: 3)
        var index = headerIndex + 2
        while index < range.upperBound, let parts = splitTableRow(lines[index]), parts.count >= 8 {
            let label = parts[0].replacingOccurrences(of: " ", with: "")
            let row: Int?
            switch label {
            case "上午": row = 0
            case "中午", "下午": row = 1
            case "晚上": row = 2
            default: row = nil
            }
            if let row { source[row] = Array(parts.dropFirst().prefix(7)).map(decodeTableText) }
            index += 1
        }
        let calendar = studyCalendar
        let today = calendar.startOfDay(for: referenceDate)
        let weekday = calendar.component(.weekday, from: today)
        let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today) ?? today
        let rows = (0..<7).map { column -> (label: String, slots: [String], unassigned: String, completed: Bool) in
            let date = calendar.date(byAdding: .day, value: column, to: monday) ?? monday
            return (dateLabel(for: date), source.map { $0[column] }, "", false)
        }
        populateWeek(rows: rows, relativeTo: referenceDate, into: &plan)
    }

    private static func splitLegacyDayText(_ text: String) -> (slots: [String], unassigned: String) {
        let normalized = text.replacingOccurrences(of: "；", with: ";")
        let parts = normalized.components(separatedBy: CharacterSet(charactersIn: ";\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else {
            return (Array(repeating: "", count: 3), text)
        }
        let base = parts.count / 3
        let remainder = parts.count % 3
        var offset = 0
        var slots: [String] = []
        for slot in 0..<3 {
            let count = base + (slot < remainder ? 1 : 0)
            if count > 0 {
                slots.append(parts[offset..<(offset + count)].joined(separator: "；"))
                offset += count
            } else {
                slots.append("")
            }
        }
        return (slots, "")
    }

    private static func populateWeek(
        rows: [(label: String, slots: [String], unassigned: String, completed: Bool)],
        relativeTo reference: Date,
        into plan: inout WeeklyPlan
    ) {
        fillDateLabels(relativeTo: reference, into: &plan)
        let calendar = studyCalendar
        let start = calendar.startOfDay(for: reference)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        plan.historicalRows.removeAll()
        plan.futureRows.removeAll()
        for sourceRow in rows {
            let row = normalizedScheduledRow(sourceRow)
            guard let date = leadingDate(in: row.label, relativeTo: reference) else {
                plan.futureRows.append(WeeklyScheduledRow(dateLabel: row.label, slots: row.slots, unassigned: row.unassigned, isCompleted: row.completed))
                continue
            }
            if date < start {
                plan.historicalRows.append(WeeklyScheduledRow(dateLabel: row.label, slots: row.slots, unassigned: row.unassigned, isCompleted: row.completed))
                continue
            }
            if date >= end {
                plan.futureRows.append(WeeklyScheduledRow(dateLabel: row.label, slots: row.slots, unassigned: row.unassigned, isCompleted: row.completed))
                continue
            }
            let offset = calendar.dateComponents([.day], from: start, to: date).day ?? 0
            guard (0..<7).contains(offset) else { continue }
            plan.dayDateLabels[offset] = row.label
            for period in 0..<3 where row.slots.indices.contains(period) { plan.cells[period][offset] = row.slots[period] }
            plan.unassignedByDay[offset] = row.unassigned
            plan.dayCompletion[offset] = row.completed
        }
        plan.historicalRows.sort { leadingDate(in: $0.dateLabel, relativeTo: reference) ?? .distantPast < leadingDate(in: $1.dateLabel, relativeTo: reference) ?? .distantPast }
        plan.futureRows.sort { leadingDate(in: $0.dateLabel, relativeTo: reference) ?? .distantFuture < leadingDate(in: $1.dateLabel, relativeTo: reference) ?? .distantFuture }
    }

    private static func normalizedScheduledRow(
        _ row: (label: String, slots: [String], unassigned: String, completed: Bool)
    ) -> (label: String, slots: [String], unassigned: String, completed: Bool) {
        let ids = ["morning", "noon", "evening"]
        let titles = WeeklyPlan.periods
        let periods = ids.enumerated().map { index, id in
            PeriodSnapshot(
                id: id,
                title: titles[index],
                text: row.slots.indices.contains(index) ? row.slots[index] : ""
            )
        }
        let layout = WeeklyPlanTaskNormalizer.normalized(periods: periods, unassigned: row.unassigned)
        return (row.label, layout.periods.map(\.text), layout.unassigned, row.completed)
    }

    private static func fillDateLabels(relativeTo date: Date, into plan: inout WeeklyPlan) {
        let calendar = studyCalendar
        let start = calendar.startOfDay(for: date)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M 月 d 日"
        plan.dayDateLabels = (0..<7).map { offset in
            formatter.string(from: calendar.date(byAdding: .day, value: offset, to: start) ?? start)
        }
    }

    private static func dateLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = studyCalendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = studyCalendar.timeZone
        formatter.dateFormat = "M 月 d 日"
        return formatter.string(from: date)
    }

    private static func structuredWeekTable(for plan: WeeklyPlan) -> [String] {
        var result = [
            "",
            "| 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |",
            "|------|------|------|------|----------|------|"
        ]
        for day in 0..<7 {
            let label = plan.dayDateLabels.indices.contains(day) && !plan.dayDateLabels[day].isEmpty
                ? plan.dayDateLabels[day]
                : WeeklyPlan.days[day]
            let values = (0..<3).map { period in
                plan.cells.indices.contains(period) && plan.cells[period].indices.contains(day) ? plan.cells[period][day] : ""
            }
            let unassigned = plan.unassignedByDay.indices.contains(day) ? plan.unassignedByDay[day] : ""
            let completed = plan.dayCompletion.indices.contains(day) && plan.dayCompletion[day] ? "[x]" : "[ ]"
            result.append("| " + ([label] + values + [unassigned, completed]).map(encodeTableText).joined(separator: " | ") + " |")
        }
        result.append("")
        return result
    }

    private static func hiddenRowsTable(_ rows: [WeeklyScheduledRow], markers: (start: String, end: String)) -> [String] {
        guard !rows.isEmpty else { return [] }
        var result = ["<!-- \(markers.start) -->", "", "| 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |", "|------|------|------|------|----------|------|"]
        for row in rows {
            let values = [row.dateLabel] + Array(row.slots.prefix(3)) + [row.unassigned, row.isCompleted ? "[x]" : "[ ]"]
            result.append("| " + values.map(encodeTableText).joined(separator: " | ") + " |")
        }
        result += ["<!-- \(markers.end) -->", ""]
        return result
    }

    private static func scheduledRows(in lines: [String], markers: (start: String, end: String)) -> [(label: String, slots: [String], unassigned: String, completed: Bool)] {
        guard let start = lines.firstIndex(where: { $0.contains(markers.start) }),
              let end = lines[(start + 1)..<lines.count].firstIndex(where: { $0.contains(markers.end) }) else { return [] }
        return lines[(start + 1)..<end].compactMap { line in
            guard let parts = splitTableRow(line), parts.count >= 4, parts.first?.contains("---") != true else { return nil }
            let slots = (1...3).map { parts.indices.contains($0) ? decodeTableText(parts[$0]) : "" }
            return (decodeTableText(parts[0]), slots, parts.indices.contains(4) ? decodeTableText(parts[4]) : "", parts.indices.contains(5) && parseBoolean(parts[5]))
        }
    }

    private static func managedWeeklyRange(in lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { $0.contains("studyrocket:weekly:start") }),
              let end = lines[(start + 1)...].firstIndex(where: { $0.contains("studyrocket:weekly:end") }) else { return nil }
        return (start + 1)..<end
    }

    private static func isStructuredWeekHeader(_ line: String) -> Bool {
        guard let parts = splitTableRow(line) else { return false }
        let normalized = parts.map { $0.replacingOccurrences(of: " ", with: "") }
        return normalized.count >= 4 && normalized[0] == "日期" && normalized.contains("上午") && normalized.contains("中午") && normalized.contains("晚上")
    }

    private static func isLegacyDatedHeader(_ line: String) -> Bool {
        guard let parts = splitTableRow(line) else { return false }
        return parts.count >= 2 && parts[0].replacingOccurrences(of: " ", with: "") == "日期" && parts[1].replacingOccurrences(of: " ", with: "") == "计划"
    }

    private static func isTimeGridHeader(_ line: String) -> Bool {
        guard let parts = splitTableRow(line) else { return false }
        return parts.count >= 8 && parts[0].replacingOccurrences(of: " ", with: "") == "时段"
    }

    private static func weekdayIndex(for date: Date) -> Int {
        (studyCalendar.component(.weekday, from: date) + 5) % 7
    }

    private static func parseBoolean(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "[x]" || value == "x" || value == "是" || value == "true"
    }

    private static func captureGroups(_ pattern: String, in value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
    }

    private static func managedSectionContent(
        _ lines: [String],
        headingIndex: Int,
        markers: (start: String, end: String) = ("studyrocket:deliveries:start", "studyrocket:deliveries:end")
    ) -> (content: Range<Int>, hasMarkers: Bool) {
        let sectionStart = headingIndex + 1
        var sectionEnd = sectionStart
        while sectionEnd < lines.count && !lines[sectionEnd].hasPrefix("## ") { sectionEnd += 1 }
        guard let startMarker = lines[sectionStart..<sectionEnd].firstIndex(where: { $0.contains(markers.start) }),
              let endMarker = lines[(startMarker + 1)..<sectionEnd].firstIndex(where: { $0.contains(markers.end) }) else {
            return (sectionStart..<sectionEnd, false)
        }
        return ((startMarker + 1)..<endMarker, true)
    }

    private static func parseBufferRules(_ lines: [String], headingIndex: Int) -> [BufferRule] {
        let section = managedSectionContent(lines, headingIndex: headingIndex, markers: ("studyrocket:buffer:start", "studyrocket:buffer:end"))
        let content = Array(lines[section.content])
        var category: BufferRuleCategory?
        var parsed: [(category: BufferRuleCategory, text: String)] = []
        var current: (category: BufferRuleCategory, text: String)?
        var sawStructuredHeading = false

        func commit() {
            guard let current, !current.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            parsed.append(current)
        }

        for line in content {
            if let heading = bufferCategory(forHeading: line) {
                commit()
                current = nil
                category = heading
                sawStructuredHeading = true
            } else if line.hasPrefix("- ") || line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                commit()
                current = (category ?? .daily, bufferBulletText(line))
            } else if line.hasPrefix("  "), var value = current {
                value.text += "\n" + line.drop(while: { $0 == " " })
                current = value
            }
        }
        commit()
        if sawStructuredHeading { return parsed.map { BufferRule(category: $0.category, text: $0.text) } }
        return legacyBufferRules(from: parsed.map(\.text).joined(separator: "\n"))
    }

    private static func bufferCategory(forHeading line: String) -> BufferRuleCategory? {
        let label = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return switch label {
        case "### 日常缓冲": .daily
        case "### 撞车降级": .collision
        case "### 最低底线": .minimum
        default: nil
        }
    }

    private static func bufferBulletText(_ line: String) -> String {
        if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") { return String(line.dropFirst(6)) }
        return line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
    }

    private static func legacyBufferRules(from text: String) -> [BufferRule] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { BufferRule(category: bufferCategory(forLegacyText: $0), text: $0) }
    }

    private static func bufferCategory(forLegacyText text: String) -> BufferRuleCategory {
        if ["若全崩", "只保最重要", "最低"].contains(where: text.contains) { return .minimum }
        if ["若", "撞车", "受阻", "只剩"].contains(where: text.contains) { return .collision }
        return .daily
    }

    private static func structuredBufferLines(for rules: [BufferRule]) -> [String] {
        BufferRuleCategory.allCases.flatMap { category -> [String] in
            let categoryRules = rules.filter { $0.category == category }
            let items = categoryRules.flatMap { rule -> [String] in
                let pieces = rule.text.components(separatedBy: .newlines)
                guard let first = pieces.first else { return ["- "] }
                return ["- \(first)"] + pieces.dropFirst().map { "  \($0)" }
            }
            return ["### \(category.title)"] + items + [""]
        }
    }

    private static func splitTableRow(_ line: String) -> [String]? {
        guard line.trimmingCharacters(in: .whitespaces).hasPrefix("|") else { return nil }
        var fields: [String] = [], current = "", escaped = false
        for character in line {
            if character == "|" && !escaped { fields.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(character) }
            if character == "\\" { escaped.toggle() } else { escaped = false }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        if fields.first?.isEmpty == true { fields.removeFirst() }
        if fields.last?.isEmpty == true { fields.removeLast() }
        return fields
    }

    private static func parseCompletion(_ value: String) -> (text: String, completed: Bool) {
        let decoded = decodeTableText(value)
        if decoded.hasPrefix("[x] ") || decoded.hasPrefix("[X] ") { return (String(decoded.dropFirst(4)), true) }
        if decoded.hasPrefix("[ ] ") { return (String(decoded.dropFirst(4)), false) }
        return (decoded, false)
    }

    private static func decodeTableText(_ value: String) -> String {
        value.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "\\|", with: "|")
    }

    private static func encodeTableText(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
    }
    static func daily(_ text: String, date: String) -> DailyEntry {
        let section = text.components(separatedBy: "### ").first { $0.hasPrefix(date) } ?? "\(date)\n- [ ] 今日完成的具体交付物：\n- 净学习时长：待补\n- 入睡/起床：待补\n- 运动：待补\n- 明日第一任务："
        func value(_ label: String) -> String { section.components(separatedBy: label).dropFirst().first?.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "" }
        return DailyEntry(id: date, date: date, deliverables: value("今日完成的具体交付物：").replacingOccurrences(of: "- [ ] ", with: ""), studyTime: value("净学习时长："), sleep: value("入睡/起床："), exercise: value("运动："), firstTask: value("明日第一任务："))
    }
    static func replaceDaily(_ text: String, entry: DailyEntry) -> String {
        let block = "### \(entry.date)\n- [ ] 今日完成的具体交付物：\(entry.deliverables.isEmpty ? "" : " " + entry.deliverables)\n- 净学习时长：\(entry.studyTime)\n- 入睡/起床：\(entry.sleep)\n- 运动：\(entry.exercise)\n- 明日第一任务：\(entry.firstTask)"
        if let range = text.range(of: "### \(entry.date)"), let next = text[range.upperBound...].range(of: "\n### ") { var result = text; result.replaceSubrange(range.lowerBound..<next.lowerBound, with: block); return result }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + block + "\n"
    }
}

import Foundation
import SwiftUI
import CryptoKit

struct WeeklyCell: Identifiable, Hashable {
    let id = UUID()
    var text: String
}

struct WeeklyDelivery: Identifiable, Hashable {
    let id = UUID()
    var text: String
    var isCompleted: Bool
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

struct WeeklyPlan {
    static let days = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    static let periods = ["上午", "下午", "晚上"]
    var format: WeeklyPlanFormat = .timeGrid
    var cells: [[String]] = Array(repeating: Array(repeating: "", count: 7), count: 3)
    var datedRows: [WeeklyDatedRow] = []
    var deliveries: [WeeklyDelivery] = []
    var buffer: String = "每天 17:00-18:30 弹性\n若全崩：只保最重要的一件事"
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
    @Published private(set) var original = ""
    @Published private(set) var loadedHash = ""
    @Published private(set) var errorMessage: String?

    private let file = "工作台/下周计划.md"
    private var root: URL?

    var weekdayIndex: Int {
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: .now)
        return (weekday + 5) % 7
    }

    var todayCells: [(period: String, task: String)] {
        if plan.format == .datedRows {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M 月 d 日"
            let label = formatter.string(from: .now)
            let matching = plan.datedRows.filter { normalizedDateLabel($0.dateLabel) == normalizedDateLabel(label) }
            return matching.isEmpty ? [("今天", "")] : matching.map { ($0.dateLabel, $0.text) }
        }
        return WeeklyPlan.periods.enumerated().map { ($0.element, plan.cells[$0.offset][weekdayIndex]) }
    }

    private func normalizedDateLabel(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "日", with: "")
    }

    var completedDeliveries: Int { plan.deliveries.filter(\.isCompleted).count }
    var firstOpenTask: String? {
        todayCells.first(where: { !$0.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.task
            ?? plan.deliveries.first(where: { !$0.isCompleted && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text
    }

    func load(from root: URL) {
        self.root = root
        let repository = MarkdownRepository(root: root)
        do {
            let text = try repository.read(file)
            original = text
            loadedHash = repository.hash(text)
            plan = MarkdownParser.weekly(text)
            errorMessage = nil
        } catch { errorMessage = "无法读取周计划：\(error.localizedDescription)" }
    }

    func toggleDelivery(_ id: UUID, workspace: WorkspaceStore) {
        guard let index = plan.deliveries.firstIndex(where: { $0.id == id }) else { return }
        plan.deliveries[index].isCompleted.toggle()
        guard let root else { return }
        let repository = MarkdownRepository(root: root)
        do {
            let replacement = MarkdownParser.replaceWeekly(original, with: plan)
            try repository.save(replacement, relative: file, loadedHash: loadedHash)
            original = replacement
            loadedHash = repository.hash(replacement)
            errorMessage = nil
            workspace.refreshGitStatus()
        } catch {
            plan.deliveries[index].isCompleted.toggle()
            errorMessage = error.localizedDescription
        }
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
    case home, chat, week, daily, routes, baoyan, library, settings
    var id: String { rawValue }
    var title: String {
        switch self { case .home: "首页"; case .chat: "学业对话"; case .week: "周计划"; case .daily: "每日复盘"; case .routes: "四条航线"; case .baoyan: "保研"; case .library: "资料库"; case .settings: "设置" }
    }
    var icon: String {
        switch self { case .home: "rectangle.grid.2x2"; case .chat: "bubble.left.and.bubble.right"; case .week: "calendar"; case .daily: "checkmark.circle"; case .routes: "point.3.connected.trianglepath.dotted"; case .baoyan: "arrow.up.right.circle"; case .library: "books.vertical"; case .settings: "gearshape" }
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
        rootURL = url.standardizedFileURL
        UserDefaults.standard.set(rootURL.path, forKey: "workspaceRoot")
        refreshGitStatus()
        refreshMarkdownIndex()
    }

    func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshGitStatus() } }
    }

    func stopMonitoring() { timer?.invalidate(); timer = nil; gitRefreshTask?.cancel(); indexTask?.cancel() }

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

enum MarkdownError: LocalizedError { case outsideWorkspace, nonMarkdown, conflict
    var errorDescription: String? { switch self { case .outsideWorkspace: "文件不在当前仓库内"; case .nonMarkdown: "只允许编辑 Markdown 文件"; case .conflict: "文件已被其他程序修改" } }
}

final class MarkdownRepository {
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL }
    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
    func read(_ relative: String) throws -> String { try String(contentsOf: url(relative), encoding: .utf8) }
    func hash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func save(_ content: String, relative: String, loadedHash: String) throws {
        let target = url(relative).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedTarget = target.resolvingSymlinksInPath()
        guard resolvedTarget.path.hasPrefix(resolvedRoot.path + "/") else { throw MarkdownError.outsideWorkspace }
        guard target.pathExtension.lowercased() == "md" else { throw MarkdownError.nonMarkdown }
        guard !Self.isSymbolicLink(target) else { throw MarkdownError.outsideWorkspace }
        let current = (try? read(relative)) ?? ""
        guard hash(current) == loadedHash else { throw MarkdownError.conflict }
        let backupDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NCU StudyRocket/Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        if let old = try? Data(contentsOf: target) { let name = relative.replacingOccurrences(of: "/", with: "_") + "." + String(Int(Date().timeIntervalSince1970)); try? old.write(to: backupDir.appendingPathComponent(name)) }
        try Data(content.utf8).write(to: target, options: .atomic)
        pruneBackups(in: backupDir, prefix: relative.replacingOccurrences(of: "/", with: "_") + ".")
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

enum MarkdownParser {
    static func weekly(_ text: String) -> WeeklyPlan {
        var plan = WeeklyPlan()
        let lines = text.components(separatedBy: .newlines)
        if let start = lines.firstIndex(where: { $0.contains("| 日期 |") && $0.contains("| 计划 |") }) {
            plan.format = .datedRows
            var index = start + 2
            while index < lines.count, !lines[index].hasPrefix("## ") {
                guard let parts = splitTableRow(lines[index]), parts.count >= 2 else { index += 1; continue }
                let parsed = parseCompletion(parts[1])
                plan.datedRows.append(WeeklyDatedRow(dateLabel: parts[0], text: parsed.text, isCompleted: parsed.completed))
                index += 1
            }
        } else if let start = lines.firstIndex(where: { $0.contains("| 时段 |") }) {
            plan.format = .timeGrid
            for row in 0..<3 {
                let index = start + 2 + row
                guard index < lines.count, let parts = splitTableRow(lines[index]), parts.count >= 8 else { continue }
                plan.cells[row] = parts.dropFirst().map(decodeTableText)
            }
        }
        if let start = lines.firstIndex(where: { $0.contains("## 交付物") }) {
            let range = managedSectionContent(lines, headingIndex: start)
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
            var values: [String] = []
            for line in lines[(start + 1)..<lines.count] {
                if line.hasPrefix("## ") { break }
                values.append(line.hasPrefix("- ") ? String(line.dropFirst(2)) : line)
            }
            if !values.isEmpty { plan.buffer = values.joined(separator: "\n") }
        }
        return plan
    }

    static func replaceWeekly(_ old: String, with plan: WeeklyPlan) -> String {
        var lines = old.components(separatedBy: .newlines)
        if plan.format == .datedRows, let start = lines.firstIndex(where: { $0.contains("| 日期 |") && $0.contains("| 计划 |") }) {
            let bodyStart = start + 2
            var bodyEnd = bodyStart
            while bodyEnd < lines.count && !lines[bodyEnd].hasPrefix("## ") { bodyEnd += 1 }
            if let marker = lines[bodyStart..<bodyEnd].firstIndex(where: { $0.contains("studyrocket:weekly:end") }) {
                bodyEnd = marker
            }
            let rows = plan.datedRows.map { row in
                let marker = row.isCompleted ? "[x] " : "[ ] "
                let value = encodeTableText(marker + row.text)
                return "| \(encodeTableText(row.dateLabel)) | \(value) |"
            }
            lines.replaceSubrange(bodyStart..<bodyEnd, with: rows)
        } else if let start = lines.firstIndex(where: { $0.contains("| 时段 |") }) {
            for row in 0..<3 {
                let index = start + 2 + row
                guard index < lines.count else { continue }
                let values = plan.cells.indices.contains(row) ? plan.cells[row].map(encodeTableText) : Array(repeating: "", count: 7)
                lines[index] = "| " + ([WeeklyPlan.periods[row]] + values).joined(separator: " | ") + " |"
            }
        }
        if let start = lines.firstIndex(where: { $0.contains("## 交付物") }) {
            let section = managedSectionContent(lines, headingIndex: start)
            let deliveryLines = plan.deliveries.isEmpty ? ["- [ ] 待生成"] : plan.deliveries.flatMap { delivery -> [String] in
                let pieces = delivery.text.components(separatedBy: .newlines)
                guard let first = pieces.first else { return ["- [\(delivery.isCompleted ? "x" : " ")] "] }
                return ["- [\(delivery.isCompleted ? "x" : " ")] \(first)"] + pieces.dropFirst().map { "  \($0)" }
            }
            lines.replaceSubrange(section, with: deliveryLines)
        }
        if let start = lines.firstIndex(where: { $0.contains("## 缓冲") }) { var end = start + 1; while end < lines.count && !lines[end].hasPrefix("## ") { end += 1 }; let bufferLines = plan.buffer.split(separator: "\n", omittingEmptySubsequences: false).map { "- " + $0 }; lines.replaceSubrange((start + 1)..<end, with: bufferLines) }
        return lines.joined(separator: "\n")
    }

    private static func managedSectionContent(_ lines: [String], headingIndex: Int) -> Range<Int> {
        var start = headingIndex + 1
        var end = start
        while end < lines.count && !lines[end].hasPrefix("## ") { end += 1 }
        if start < end, lines[start].contains("studyrocket:deliveries:start") { start += 1 }
        if start < end, lines[end - 1].contains("studyrocket:deliveries:end") { end -= 1 }
        return start..<end
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

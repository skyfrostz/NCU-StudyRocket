import Foundation
import SwiftUI
import CryptoKit

struct WeeklyCell: Identifiable, Hashable {
    let id = UUID()
    var text: String
}

struct WeeklyPlan {
    static let days = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    static let periods = ["上午", "下午", "晚上"]
    var cells: [[String]] = Array(repeating: Array(repeating: "", count: 7), count: 3)
    var deliveries: [String] = []
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
    private var timer: Timer?

    init() {
        let saved = UserDefaults.standard.string(forKey: "workspaceRoot").map(URL.init(fileURLWithPath:))
        rootURL = saved ?? URL(fileURLWithPath: "/Users/skyfrost/Desktop/大学")
        refreshGitStatus()
    }

    var isValid: Bool { FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("AGENTS.md").path) && FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("PROFILE.md").path) }

    func bind(to url: URL) {
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("AGENTS.md").path), FileManager.default.fileExists(atPath: url.appendingPathComponent("PROFILE.md").path) else { errorMessage = "所选目录不是 StudyRocket 仓库：缺少 AGENTS.md 或 PROFILE.md。"; return }
        rootURL = url.standardizedFileURL
        UserDefaults.standard.set(rootURL.path, forKey: "workspaceRoot")
        refreshGitStatus()
    }

    func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshGitStatus() } }
    }

    func stopMonitoring() { timer?.invalidate(); timer = nil }

    func refreshGitStatus() {
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/git"); task.arguments = ["-C", rootURL.path, "status", "--porcelain"]
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
        do { try task.run(); task.waitUntilExit(); let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; gitStatus = output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "已同步" : "存在未提交修改" } catch { gitStatus = "无法读取 Git 状态" }
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
    func markdownFiles() -> [String] { let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]); return e?.compactMap { item in guard let url = item as? URL, url.pathExtension.lowercased() == "md", !Self.isSymbolicLink(url) else { return nil }; return url.path.replacingOccurrences(of: root.path + "/", with: "") }.sorted() ?? [] }

    static func isSymbolicLink(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false }
}

struct MarkdownChangeProposal: Identifiable, Hashable {
    let id = UUID()
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
        var plan = WeeklyPlan(); let lines = text.components(separatedBy: .newlines)
        if let start = lines.firstIndex(where: { $0.contains("| 时段 |") }) { for row in 0..<3 { let index = start + 2 + row; guard index < lines.count else { continue }; let raw: [String] = lines[index].split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }; let parts = Array(raw.dropFirst().dropLast()); if parts.count >= 8 { plan.cells[row] = Array(parts[1...7]) } } }
        if let start = lines.firstIndex(where: { $0.contains("## 交付物") }) { for line in lines[(start + 1)..<lines.count] { if line.hasPrefix("## ") { break }; if line.hasPrefix("- [") { plan.deliveries.append(String(line.dropFirst(6))) } } }
        if let start = lines.firstIndex(where: { $0.contains("## 缓冲") }) { var values: [String] = []; for line in lines[(start + 1)..<lines.count] { if line.hasPrefix("## ") { break }; values.append(line.hasPrefix("- ") ? String(line.dropFirst(2)) : line) }; if !values.isEmpty { plan.buffer = values.joined(separator: "\n") } }
        return plan
    }
    static func replaceWeekly(_ old: String, with plan: WeeklyPlan) -> String {
        var lines = old.components(separatedBy: .newlines); guard let start = lines.firstIndex(where: { $0.contains("| 时段 |") }) else { return old }
        for row in 0..<3 { let index = start + 2 + row; guard index < lines.count else { continue }; lines[index] = "| " + ([WeeklyPlan.periods[row]] + plan.cells[row]).joined(separator: " | ") + " |" }
        if let start = lines.firstIndex(where: { $0.contains("## 交付物") }) { var end = start + 1; while end < lines.count && !lines[end].hasPrefix("## ") { end += 1 }; lines.replaceSubrange((start + 1)..<end, with: plan.deliveries.isEmpty ? ["- [ ] 待生成"] : plan.deliveries.map { "- [ ] " + $0 }) }
        if let start = lines.firstIndex(where: { $0.contains("## 缓冲") }) { var end = start + 1; while end < lines.count && !lines[end].hasPrefix("## ") { end += 1 }; let bufferLines = plan.buffer.split(separator: "\n", omittingEmptySubsequences: false).map { "- " + $0 }; lines.replaceSubrange((start + 1)..<end, with: bufferLines) }
        return lines.joined(separator: "\n")
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

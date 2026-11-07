import Foundation
import Darwin

public struct QuickFact: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let date: String
    public let text: String

    public init(id: UUID = UUID(), date: String = day(), text: String) {
        self.id = id
        self.date = date
        self.text = text
    }

    public static func day(_ date: Date = .now) -> String { formatter.string(from: date) }
    private static var formatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    public func validate() throws {
        guard let parsed = Self.formatter.date(from: date), Self.day(parsed) == date,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 1000, !text.contains("<!--"),
              text.rangeOfCharacter(from: .newlines.union(.controlCharacters)) == nil else {
            throw FactError("请输入一句不超过 1000 字的事实，日期须有效。")
        }
    }
}

public struct FactError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct FactWriteRequest: Codable, Sendable {
    public let entry: QuickFact
    public let metadata: WriteMetadata
    public let repositoryID: String
    public init(entry: QuickFact, metadata: WriteMetadata, repositoryID: String) {
        self.entry = entry; self.metadata = metadata; self.repositoryID = repositoryID
    }
}

/// Stable IDs live beside their original text. A directory lock serializes Desktop and Host
/// without leaving a lock file in the repository. Legacy day sections stay byte-for-byte intact.
public enum FactJournal {
    private static func directory(_ root: URL) throws -> URL {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let dir = root.appendingPathComponent("工作台/每日记录")
        for url in [dir.deletingLastPathComponent(), dir] {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                throw FactError("记录目录不能是符号链接。")
            }
        }
        return dir
    }

    private static func safe(_ file: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) == nil
    }

    public static func entries(in source: String) -> [QuickFact] {
        source.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix("- "), line.hasSuffix(" -->"),
                  let mark = line.range(of: " <!-- fact:", options: .backwards) else { return nil }
            let fields = line[mark.upperBound...].dropLast(4).split(separator: " ")
            guard fields.count == 2, let id = UUID(uuidString: String(fields[1])) else { return nil }
            return QuickFact(id: id, date: String(fields[0]), text: String(line[line.index(line.startIndex, offsetBy: 2)..<mark.lowerBound]))
        }
    }

    private static func months(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { safe($0) && $0.lastPathComponent.range(of: #"^[0-9]{4}-[0-9]{2}\.md$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    public static func recent(root: URL, limit: Int = 60) -> [QuickFact] {
        guard let dir = try? directory(root) else { return [] }
        var result: [QuickFact] = []
        for file in months(dir) {
            if let source = try? String(contentsOf: file, encoding: .utf8) {
                result += entries(in: source).sorted { $0.date > $1.date }
            }
            if result.count >= limit { break }
        }
        return Array(result.prefix(limit))
    }

    public static func legacy(root: URL) -> String {
        guard let dir = try? directory(root) else { return "" }
        return months(dir).prefix(3).compactMap { file -> String? in
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            var keep = false
            return source.components(separatedBy: "\n").filter { line in
                if line.hasPrefix("#") { keep = line.range(of: #"^### [0-9]{4}-[0-9]{2}-[0-9]{2}"#, options: .regularExpression) != nil }
                return keep
            }.joined(separator: "\n")
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public static func coordinated<T>(root: URL, action: (URL) throws -> T) throws -> T {
        let fm = FileManager.default, dir = try directory(root)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw FactError("无法打开记录目录。") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw FactError("无法锁定记录目录。") }
        defer { flock(fd, LOCK_UN) }
        return try action(dir)
    }

    public static func append(_ fact: QuickFact, root: URL, backupDirectory: URL? = nil,
                              recordLocalHistory: Bool = false, checkRevision: () throws -> Void = {}) throws {
        try fact.validate()
        try coordinated(root: root) { dir in
            try appendLocked(fact, root: root, dir: dir, backupDirectory: backupDirectory,
                             recordLocalHistory: recordLocalHistory, checkRevision: checkRevision)
        }
    }

    private static func appendLocked(_ fact: QuickFact, root: URL, dir: URL, backupDirectory: URL?,
                                     recordLocalHistory: Bool, checkRevision: () throws -> Void) throws {
        let fm = FileManager.default
        let month = String(fact.date.prefix(7)), url = dir.appendingPathComponent(month + ".md")
        guard safe(url) else { throw FactError("记录文件不能是符号链接。") }
        for file in months(dir) {
            let source = try String(contentsOf: file, encoding: .utf8)
            if let prior = entries(in: source).first(where: { $0.id == fact.id }) {
                guard prior == fact else { throw FactError("同一记录编号已用于其他内容。") }
                return
            }
        }
        try checkRevision()
        let exists = fm.fileExists(atPath: url.path)
        let original = exists ? try String(contentsOf: url, encoding: .utf8) : "# 每日记录 · \(month)\n"
        var updated = original
        let heading = "### 记一件事 · \(fact.date)\n"
        let line = "- \(fact.text) <!-- fact:\(fact.date) \(fact.id.uuidString) -->\n"
        if let r = updated.range(of: "\n" + heading) {
            updated.insert(contentsOf: line, at: r.upperBound)
        } else {
            let first = updated.hasPrefix("# ") ? updated.firstIndex(of: "\n").map { updated.index(after: $0) } : nil
            updated.insert(contentsOf: "\n" + heading + line + "\n", at: first ?? updated.startIndex)
        }
        if exists {
            let backups = backupDirectory ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NCU StudyRocket/Backups/Facts")
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: backups.appendingPathComponent("\(month)-\(UUID().uuidString).md"))
        }
        let written = Data(updated.utf8)
        try written.write(to: url, options: .atomic)
        #if os(macOS)
        if recordLocalHistory {
            let change = LocalSaveHistory.Change(relative: "工作台/每日记录/\(month).md",
                                                 before: exists ? Data(original.utf8) : nil, after: written)
            LocalSaveHistory.shared.record([change], in: root)
        }
        #endif
    }
}

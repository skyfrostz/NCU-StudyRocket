#if os(macOS)
import Darwin
import Foundation

/// Records the bytes written by StudyRocket in a private local Git ref.
public final class LocalSaveHistory: @unchecked Sendable {
    public struct Change: Codable, Sendable {
        public let relative: String
        public let before: Data?
        public let after: Data

        public init(relative: String, before: Data?, after: Data) {
            self.relative = relative
            self.before = before
            self.after = after
        }
    }

    public static let reference = "refs/studyrocket/local-saves"
    public static let shared = LocalSaveHistory(
        stateDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NCU StudyRocket/Local Save History"),
        enabled: StudyRocketSelfCheckConfiguration.current == nil
    )

    private struct Receipt: Codable {
        let savedAt: Date
        let changes: [Change]
    }

    private let stateDirectory: URL
    private let enabled: Bool
    private let queue = DispatchQueue(label: "StudyRocket.LocalSaveHistory", qos: .utility)
    private var scheduled = Set<URL>()

    public init(stateDirectory: URL, enabled: Bool = true) {
        self.stateDirectory = stateDirectory
        self.enabled = enabled
    }

    public func record(_ changes: [Change], in root: URL) {
        guard enabled else { return }
        let changes = changes.filter { Self.isAcademicPath($0.relative) && $0.before != $0.after }
        guard !changes.isEmpty else { return }
        let receipt = Receipt(savedAt: .now, changes: changes)
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        queue.async {
            let directory = self.directory(for: root)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let file = directory.appendingPathComponent(UUID().uuidString + ".json")
                try JSONEncoder().encode(receipt).write(to: file, options: .atomic)
                self.schedule(root)
            } catch {
                self.storeStatus("文件已保存。无法登记本地记录（\(error.localizedDescription)）。", in: directory)
            }
        }
    }

    public func resume(in root: URL) {
        guard enabled else { return }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        queue.async { self.schedule(root) }
    }

    /// Drain the short batching window when the application quits normally.
    public func flush() {
        guard enabled else { return }
        queue.sync {
            for root in Array(scheduled) {
                scheduled.remove(root)
                processReceipts(for: root)
            }
        }
    }

    public func status(for root: URL) -> String {
        let file = directory(for: root.standardizedFileURL.resolvingSymlinksInPath()).appendingPathComponent("status.txt")
        return (try? String(contentsOf: file, encoding: .utf8)) ?? "保存后会在本机记录学业文件的版本。"
    }

    private static func isAcademicPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasSuffix(".md"), !path.contains("\\"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { return false }
        if parts.count == 1 { return path == "PROFILE.md" || path == "校历与重要日期.md" }
        return ["工作台", "保研", "规划", "答疑", "英语", "笔记", "专业"].contains(String(parts[0]))
    }

    private func directory(for root: URL) -> URL {
        stateDirectory.appendingPathComponent(RequestSigning.bodyHash(Data(root.path.utf8)))
    }

    private func schedule(_ root: URL) {
        guard scheduled.insert(root).inserted else { return }
        queue.asyncAfter(deadline: .now() + 3) {
            guard self.scheduled.remove(root) != nil else { return }
            self.processReceipts(for: root)
        }
    }

    private func processReceipts(for root: URL) {
        let directory = directory(for: root)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        // Desktop and Host share the same receipt directory and lock.
        let fd = open(directory.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { flock(fd, LOCK_UN) }

        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let pending = files.filter { $0.pathExtension == "json" }
        guard !pending.isEmpty else { return }
        do {
            let receipts = try pending.map { try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: $0)) }
                .sorted { $0.savedAt < $1.savedAt }
            let status = try commit(receipts.flatMap(\.changes), in: root)
            storeStatus(status, in: directory)
        } catch {
            storeStatus("文件已保存。本地 Git 记录未生成（\(error.localizedDescription)）。", in: directory)
        }
        for file in pending { try? FileManager.default.removeItem(at: file) }
    }

    private func storeStatus(_ message: String, in directory: URL) {
        try? Data(message.utf8).write(to: directory.appendingPathComponent("status.txt"), options: .atomic)
    }

    private func commit(_ changes: [Change], in root: URL) throws -> String {
        let git = LocalHistoryGit(root: root)
        let top = try git.output(["rev-parse", "--show-toplevel"])
        guard URL(fileURLWithPath: top).resolvingSymlinksInPath().path == root.path else {
            throw HistoryError("绑定目录不是 Git 仓库根目录")
        }
        let gitDirectory = URL(fileURLWithPath: try git.output(["rev-parse", "--absolute-git-dir"]))
        let operationFiles = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"]
        guard !operationFiles.contains(where: { FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent($0).path) }) else {
            throw HistoryError("仓库正在合并、变基或处理其他 Git 操作")
        }

        let head = try git.output(["rev-parse", "--verify", "HEAD"])
        let ref = try git.run(["rev-parse", "--verify", "--quiet", Self.reference])
        guard ref.status == 0 || ref.status == 1 else { throw HistoryError(ref.text) }
        let parent = ref.status == 0 ? ref.text : head

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("studyrocket-git-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let index = temporary.appendingPathComponent("index").path
        let blobFile = temporary.appendingPathComponent("saved.md")
        try git.output(["read-tree", parent], index: index)
        var recorded = 0
        var skipped: [String] = []
        for (path, saves) in Dictionary(grouping: changes, by: \.relative).sorted(by: { $0.key < $1.key }) {
            guard Self.isAcademicPath(path), let first = saves.first, let last = saves.last else { continue }
            let target = root.appendingPathComponent(path)
            let literal = ":(literal)" + path
            let staged = try git.run(["diff", "--cached", "--quiet", "--no-ext-diff", "--no-textconv", "--", literal])
            guard staged.status <= 1 else { throw HistoryError(staged.text) }
            if staged.status == 1 {
                skipped.append("\(path)（已有暂存改动）")
                continue
            }
            let entry = try git.output(["ls-tree", "--full-tree", parent, "--", literal])
            let fields = (entry.split(separator: "\t", maxSplits: 1).first ?? "").split(separator: " ")
            let mode = fields.first.map(String.init) ?? "100644"
            let priorBlob = fields.count == 3 ? String(fields[2]) : nil

            var beforeBlob: String?
            if let before = first.before {
                try before.write(to: blobFile)
                beforeBlob = try git.output(["hash-object", "--no-filters", blobFile.path])
            }
            let continuous = zip(saves, saves.dropFirst()).allSatisfy { $0.after == $1.before }
            guard continuous, beforeBlob == priorBlob else {
                skipped.append("\(path)（保存前的内容与本地版本不一致）")
                continue
            }
            guard target.resolvingSymlinksInPath().path == target.path,
                  mode == "100644" || mode == "100755" else {
                skipped.append("\(path)（路径或文件类型不适合自动记录）")
                continue
            }
            if priorBlob == nil {
                let ignored = try git.run(["check-ignore", "--quiet", "--", path])
                guard ignored.status <= 1 else { throw HistoryError(ignored.text) }
                if ignored.status == 0 {
                    skipped.append("\(path)（仓库设置为忽略此文件）")
                    continue
                }
            }
            guard first.before != last.after else { continue }
            try last.after.write(to: blobFile)
            let object = try git.output(["hash-object", "-w", "--no-filters", blobFile.path])
            try git.output(["update-index", "--add", "--cacheinfo", "\(mode),\(object),\(path)"], index: index)
            recorded += 1
        }

        if recorded > 0 {
            let tree = try git.output(["write-tree"], index: index)
            let commit = try git.output(["commit-tree", tree, "-p", parent, "-m", "StudyRocket 学业保存记录"])
            let previous = ref.status == 0 ? ref.text : String(repeating: "0", count: head.count)
            try git.output(["update-ref", "--no-deref", Self.reference, commit, previous])
        }
        let summary = recorded > 0 ? "已在本机记录 \(recorded) 个学业文件。" : "本次没有生成本地 Git 记录。"
        guard !skipped.isEmpty else { return summary }
        return summary + " 以下文件已保存，跳过本地版本记录。\n" + skipped.joined(separator: "\n")
    }
}

private struct HistoryError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message.isEmpty ? "Git 命令失败" : message }
}

private struct LocalHistoryGit {
    let root: URL

    @discardableResult
    func output(_ arguments: [String], index: String? = nil) throws -> String {
        let result = try run(arguments, index: index)
        guard result.status == 0 else { throw HistoryError(result.text) }
        return result.text
    }

    func run(_ arguments: [String], index: String? = nil) throws -> (status: Int32, text: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false"] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if let index { environment["GIT_INDEX_FILE"] = index }
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
#endif

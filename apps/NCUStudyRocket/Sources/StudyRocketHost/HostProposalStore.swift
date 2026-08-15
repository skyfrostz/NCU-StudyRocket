import Foundation
import CryptoKit
import StudyRocketShared

final class HostProposalStore: @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()
    private var values: [String: ProposalDTO] = [:]
    private var appliedReplays: [String: ProposalListResponse] = [:]
    private let skillNames = Set(["daily-checkin", "knowledge-ingest", "ncu-planner", "node-countdown", "retro-monthly", "retro-weekly", "term-roadmap", "weekly-reslot"])

    init(root: URL) { self.root = root.standardizedFileURL }

    func list() -> ProposalListResponse {
        lock.lock(); defer { lock.unlock() }
        return ProposalListResponse(proposals: Array(values.values).sorted { $0.id < $1.id })
    }

    func register(arguments: [String: Any], tool: String, turnID: String) -> [String: Any] {
        guard tool == "propose_changes" || tool == "propose_skill_update",
              let path = arguments["path"] as? String,
              let content = arguments["content"] as? String,
              let reason = arguments["reason"] as? String else { return failure("草案缺少路径、正文或理由。") }
        guard isAllowed(path: path, skill: tool == "propose_skill_update") else { return failure("草案路径不在允许范围内。") }
        let url = root.appendingPathComponent(path).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedURL = url.resolvingSymlinksInPath()
        guard resolvedURL.path.hasPrefix(resolvedRoot.path + "/"), !isSymlink(url), let original = try? String(contentsOf: url, encoding: .utf8) else { return failure("无法读取草案目标文件。") }
        if tool == "propose_skill_update" {
            let lines = content.components(separatedBy: .newlines)
            guard lines.count <= 300, lines.first == "---", lines.dropFirst().contains("---"), content.contains("name:"), content.contains("description:") else { return failure("Skill 草案的 frontmatter 或长度不符合要求。") }
        }
        let proposal = ProposalDTO(id: UUID().uuidString, turnID: turnID, relativePath: path, originalContent: original, proposedContent: content, reason: reason, baseHash: hash(original), kind: tool == "propose_skill_update" ? "skill" : "markdown")
        lock.lock()
        values = values.filter { !($0.value.turnID == turnID && $0.value.relativePath == path) }
        values[proposal.id] = proposal
        lock.unlock()
        return ["success": true, "contentItems": [["type": "inputText", "text": "已建立修改草案：\(path)。应用将展示差异，确认后才会写入。"]]]
    }

    func apply(_ request: ProposalApplyRequest) throws -> ProposalListResponse {
        guard !request.proposalIDs.isEmpty, !request.authorization.isEmpty else { throw HostWriteError(code: "authorization_required", message: "应用草案需要确认授权。") }
        guard request.metadata.apiVersion == StudyRocketAPI.version else { throw HostWriteError(code: "unsupported_version", message: "客户端版本不兼容，请更新 StudyRocket。") }
        lock.lock()
        if let cached = appliedReplays[request.metadata.idempotencyKey] { lock.unlock(); return cached }
        lock.unlock()
        lock.lock()
        let selected = request.proposalIDs.compactMap { values[$0] }
        lock.unlock()
        guard selected.count == Set(request.proposalIDs).count else { throw HostWriteError(code: "proposal_not_found", message: "部分草案已不存在，请重新加载。") }

        let fileManager = FileManager.default
        var originals: [(ProposalDTO, Data)] = []
        for proposal in selected {
            let url = root.appendingPathComponent(proposal.relativePath).standardizedFileURL
            let resolvedRoot = root.resolvingSymlinksInPath()
            let resolvedURL = url.resolvingSymlinksInPath()
            guard resolvedURL.path.hasPrefix(resolvedRoot.path + "/"), !isSymlink(url), let currentData = try? Data(contentsOf: url), let current = String(data: currentData, encoding: .utf8), hash(current) == proposal.baseHash else {
                throw HostWriteError(code: "conflict", message: "草案涉及的 \(proposal.relativePath) 已被外部修改。")
            }
            originals.append((proposal, currentData))
        }
        let backupRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NCU StudyRocket/Backups", isDirectory: true)
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        for (proposal, data) in originals {
            let backup = backupRoot.appendingPathComponent(proposal.relativePath.replacingOccurrences(of: "/", with: "_") + ".\(Int(Date().timeIntervalSince1970)).bak")
            try data.write(to: backup, options: .atomic)
        }
        pruneBackups(in: backupRoot, prefixes: selected.map { $0.relativePath.replacingOccurrences(of: "/", with: "_") + "." })
        do {
            for proposal in selected {
                let url = root.appendingPathComponent(proposal.relativePath).standardizedFileURL
                try Data(proposal.proposedContent.utf8).write(to: url, options: .atomic)
            }
        } catch {
            for (proposal, data) in originals { try? data.write(to: root.appendingPathComponent(proposal.relativePath), options: .atomic) }
            throw HostWriteError(code: "write_failed", message: "草案批量写入失败，已回滚。")
        }
        lock.lock()
        for proposal in selected { values.removeValue(forKey: proposal.id) }
        let remaining = ProposalListResponse(proposals: Array(values.values).sorted { $0.id < $1.id })
        if !request.metadata.idempotencyKey.isEmpty {
            appliedReplays[request.metadata.idempotencyKey] = remaining
            if appliedReplays.count > 128 { appliedReplays.removeValue(forKey: appliedReplays.keys.first!) }
        }
        lock.unlock()
        return remaining
    }

    private func isAllowed(path: String, skill: Bool) -> Bool {
        guard path == path.replacingOccurrences(of: "\\", with: "/"), !path.contains(".."), path.hasSuffix(".md") else { return false }
        if skill {
            let parts = path.split(separator: "/").map(String.init)
            return parts.count == 4 && parts[0] == ".agents" && parts[1] == "skills" && skillNames.contains(parts[2]) && parts[3] == "SKILL.md"
        }
        return ["PROFILE.md", "校历与重要日期.md"].contains(path) || ["工作台/", "保研/", "规划/", "答疑/", "英语/", "笔记/", "专业/"].contains { path.hasPrefix($0) }
    }

    private func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func isSymlink(_ url: URL) -> Bool { ((try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false) }
    private func failure(_ message: String) -> [String: Any] { ["success": false, "contentItems": [["type": "inputText", "text": message]]] }

    private func pruneBackups(in directory: URL, prefixes: [String]) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        for prefix in prefixes {
            let matches = files.filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            for file in matches.dropFirst(20) { try? FileManager.default.removeItem(at: file) }
        }
    }
}

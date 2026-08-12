import Foundation
import SwiftUI
import AppKit
import CryptoKit

struct ChatMessage: Identifiable, Hashable {
    enum Role: String { case user, assistant, system }
    let id: String
    let role: Role
    let text: String
    let date: Date
}

enum StudyChatError: LocalizedError {
    case unavailable(String)
    case protocolError(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .protocolError(let message): return message
        }
    }
}

@MainActor
final class CodexAppServerClient: NSObject {
    private let executable = "/Applications/ChatGPT.app/Contents/Resources/codex"
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outputBuffer = Data()
    private var requestID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var turnContinuation: CheckedContinuation<Void, Error>?
    private var currentReply = ""
    private var currentThreadID: String?
    private var rootURL: URL?

    var onReplyDelta: ((String) -> Void)?
    var onToolCall: (([String: Any]) -> [String: Any])?
    var onReplyCompleted: ((String) -> Void)?
    var onHistory: (([ChatMessage]) -> Void)?

    var isRunning: Bool { process?.isRunning == true }

    func connect(root: URL, threadID: String?) async throws -> String {
        if isRunning, currentThreadID != nil { return currentThreadID! }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw StudyChatError.unavailable("找不到 Codex 本地程序，请先打开或更新 Codex。")
        }
        rootURL = root
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        self.process = process; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }

        _ = try await request(method: "initialize", params: [
            "clientInfo": ["name": "ncu-studyrocket", "version": "1.0"],
            "capabilities": ["experimentalApi": true]
        ])
        sendNotification(method: "initialized", params: [:])

        let thread: [String: Any]
        if let threadID {
            let response = try await request(method: "thread/resume", params: [
                "threadId": threadID,
                "includeTurns": true,
                "cwd": root.path,
                "sandbox": "read-only",
                "approvalPolicy": "never",
                "runtimeWorkspaceRoots": [root.path]
            ])
            thread = try resultObject(response)
            currentThreadID = threadID
        } else {
            let response = try await request(method: "thread/start", params: [
                "cwd": root.path,
                "sandbox": "read-only",
                "approvalPolicy": "never",
                "runtimeWorkspaceRoots": [root.path],
                "developerInstructions": Self.developerInstructions,
                "dynamicTools": [Self.proposalTool]
            ])
            thread = try resultObject(response)
            guard let newID = (thread["thread"] as? [String: Any])?["id"] as? String else {
                throw StudyChatError.protocolError("Codex 没有返回学业任务 ID。")
            }
            currentThreadID = newID
            _ = try? await request(method: "thread/name/set", params: ["threadId": newID, "name": "StudyRocket 学业助理"])
        }
        onHistory?(parseHistory(thread["thread"] as? [String: Any]) ?? [])
        return currentThreadID!
    }

    func send(_ text: String) async throws {
        guard let threadID = currentThreadID, isRunning else { throw StudyChatError.unavailable("学业对话尚未连接。") }
        currentReply = ""
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            turnContinuation = continuation
            sendRequest(method: "turn/start", params: [
                "threadId": threadID,
                "input": [["type": "text", "text": text]],
                "cwd": rootURL?.path ?? FileManager.default.currentDirectoryPath,
                "sandboxPolicy": ["type": "readOnly", "networkAccess": true],
                "approvalPolicy": "never",
                "effort": "medium"
            ], awaitResponse: false)
        }
    }

    func stop() {
        process?.terminate()
        output?.readabilityHandler = nil
        process = nil; input = nil; output = nil; currentThreadID = nil
        turnContinuation?.resume(throwing: StudyChatError.unavailable("已停止本轮对话。")); turnContinuation = nil
    }

    func disconnect() { stop() }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 10) {
            let line = outputBuffer.prefix(upTo: newline); outputBuffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func handle(_ object: [String: Any]) {
        if let id = object["id"] as? Int {
            if let continuation = pending.removeValue(forKey: id) {
                if let error = object["error"] as? [String: Any] { continuation.resume(throwing: StudyChatError.protocolError(error["message"] as? String ?? "Codex 请求失败。")) }
                else { continuation.resume(returning: object["result"] as? [String: Any] ?? [:]) }
                return
            }
            if let error = object["error"] as? [String: Any] {
                turnContinuation?.resume(throwing: StudyChatError.protocolError(error["message"] as? String ?? "Codex turn 启动失败。")); turnContinuation = nil
                return
            }
        }
        guard let method = object["method"] as? String, let params = object["params"] as? [String: Any] else { return }
        switch method {
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String { currentReply += delta; onReplyDelta?(delta) }
        case "item/tool/call":
            guard let requestID = object["id"] else { return }
            let result = onToolCall?(params) ?? ["success": false, "contentItems": [["type": "inputText", "text": "应用未接收到该工具调用。"]]]
            sendRaw(["id": requestID, "result": result])
        case "turn/completed":
            onReplyCompleted?(currentReply)
            turnContinuation?.resume(); turnContinuation = nil
        case "error":
            let message = params["message"] as? String ?? "Codex 返回错误。"
            turnContinuation?.resume(throwing: StudyChatError.protocolError(message)); turnContinuation = nil
        default: break
        }
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            requestID += 1; pending[requestID] = continuation
            sendRaw(["id": requestID, "method": method, "params": params])
        }
    }

    private func sendRequest(method: String, params: [String: Any], awaitResponse: Bool) {
        requestID += 1
        sendRaw(["id": requestID, "method": method, "params": params])
    }

    private func sendNotification(method: String, params: [String: Any]) { sendRaw(["method": method, "params": params]) }

    private func sendRaw(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let input else { return }
        input.write(data); input.write(Data([10]))
    }

    private func resultObject(_ result: [String: Any]) throws -> [String: Any] {
        guard !result.isEmpty else { throw StudyChatError.protocolError("Codex 返回了空响应。") }
        return result
    }

    private func parseHistory(_ thread: [String: Any]?) -> [ChatMessage]? {
        guard let turns = thread?["turns"] as? [[String: Any]] else { return nil }
        var result: [ChatMessage] = []
        for turn in turns {
            guard let items = turn["items"] as? [[String: Any]] else { continue }
            for item in items {
                guard let type = item["type"] as? String, let id = item["id"] as? String else { continue }
                if type == "agentMessage", let text = item["text"] as? String { result.append(ChatMessage(id: id, role: .assistant, text: text, date: .now)) }
                if type == "userMessage", let content = item["content"] as? [[String: Any]], let text = content.first?["text"] as? String { result.append(ChatMessage(id: id, role: .user, text: text, date: .now)) }
            }
        }
        return result.isEmpty ? nil : result
    }

    static let proposalTool: [String: Any] = [
        "name": "studyrocket_propose_changes",
        "description": "提出对学业 Markdown 的修改草案。绝不直接写文件；应用会展示差异并等待用户确认。",
        "type": "function",
        "inputSchema": [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "仓库内 Markdown 相对路径"],
                "content": ["type": "string", "description": "完整候选文件正文"],
                "reason": ["type": "string", "description": "修改理由"]
            ],
            "required": ["path", "content", "reason"]
        ]
    ]

    static let developerInstructions = """
    你是 StudyRocket 学业助理，只处理南昌大学玛丽女王学院数据科学与大数据技术（中外合作办学）学生的课程答疑、学习规划、复盘、科研、竞赛和保研问题。先读 AGENTS.md、PROFILE.md 和相关工作台 Markdown；遵守仓库规则，未知信息标记【待核实】，不编造 GPA、排名、名额、日期或推免比例。学校政策必须基于仓库官方文件，时效信息需要联网核实并给官方来源。
    你运行在只读任务中，绝不直接编辑、创建、删除或提交文件。用户要求更新计划、交付物、复盘或档案时，读取当前内容后调用 studyrocket_propose_changes，传入完整候选正文和理由；不要把文件修改藏在普通回答里。应用会在用户确认后写入。
    课程答疑采用“解释 -> 例子 -> 自测 -> 归档”。计划必须是可勾选交付物，保留缓冲并给撞车降级方案。只记录用户明确提供的事实，不把推测写进行为账。
    """
}

@MainActor
final class StudyChatStore: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var proposals: [MarkdownChangeProposal] = []
    @Published var draft = ""
    @Published var streamingReply = ""
    @Published var status = "未连接"
    @Published var errorMessage: String?
    @Published var isBusy = false
    @Published private(set) var threadID: String?
    private let client = CodexAppServerClient()
    private var root: URL?
    private var pendingPrompt: String?

    private func threadKey(for root: URL) -> String {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "studyRocketThreadID.\(digest)"
    }

    init() {
        client.onReplyDelta = { [weak self] delta in self?.streamingReply += delta }
        client.onReplyCompleted = { [weak self] reply in
            guard let self else { return }
            if !reply.isEmpty { messages.append(ChatMessage(id: UUID().uuidString, role: .assistant, text: reply, date: .now)) }
            streamingReply = ""; isBusy = false; status = "已连接"
        }
        client.onHistory = { [weak self] history in self?.messages = history }
        client.onToolCall = { [weak self] params in self?.receiveToolCall(params) ?? ["success": false, "contentItems": []] }
    }

    func connect(to root: URL) async {
        guard self.root?.standardizedFileURL != root.standardizedFileURL || !client.isRunning else { return }
        self.root = root; messages = []; proposals = []; streamingReply = ""; status = "连接中..."
        let key = threadKey(for: root)
        let stored = UserDefaults.standard.string(forKey: key)
        do {
            let id = try await client.connect(root: root, threadID: stored)
            threadID = id; UserDefaults.standard.set(id, forKey: key); status = "已连接"
            if let pendingPrompt { draft = pendingPrompt; self.pendingPrompt = nil }
        } catch {
            guard stored != nil else { status = "连接失败"; errorMessage = error.localizedDescription; return }
            client.stop()
            do {
                let id = try await client.connect(root: root, threadID: nil)
                threadID = id; UserDefaults.standard.set(id, forKey: key); status = "已创建新任务"
                if let pendingPrompt { draft = pendingPrompt; self.pendingPrompt = nil }
            } catch { status = "连接失败"; errorMessage = error.localizedDescription }
        }
    }

    func prepare(prompt: String) { pendingPrompt = prompt; draft = prompt }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty, !isBusy else { return }
        draft = ""; messages.append(ChatMessage(id: UUID().uuidString, role: .user, text: text, date: .now)); isBusy = true; status = "思考中..."
        Task {
            do { try await client.send(text) }
            catch { isBusy = false; status = "连接失败"; errorMessage = error.localizedDescription }
        }
    }

    func stop() { client.stop(); isBusy = false; status = "已停止" }

    func disconnect() { client.disconnect(); isBusy = false; status = "未连接" }

    func applySelectedChanges(workspace: WorkspaceStore) {
        let selected = proposals.filter(\.isSelected); guard !selected.isEmpty else { return }
        do {
            let changes = selected.map { MarkdownRepository.Change(relative: $0.relativePath, content: $0.proposedContent, loadedHash: $0.baseHash) }
            try MarkdownRepository(root: workspace.rootURL).saveBatch(changes)
            proposals.removeAll { selected.contains($0) }; workspace.refreshGitStatus()
        } catch { errorMessage = error.localizedDescription }
    }

    func openInCodex() {
        guard let threadID else { return }
        var components = URLComponents(); components.scheme = "codex"; components.host = "threads"; components.path = "/\(threadID)"
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private func receiveToolCall(_ params: [String: Any]) -> [String: Any] {
        guard let tool = params["tool"] as? String, tool == "studyrocket_propose_changes", let root else {
            return ["success": false, "contentItems": [["type": "inputText", "text": "工具参数无效，未建立草案。"]]]
        }
        let args: [String: Any]
        if let object = params["arguments"] as? [String: Any] { args = object }
        else if let string = params["arguments"] as? String, let data = string.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { args = object }
        else { return ["success": false, "contentItems": [["type": "inputText", "text": "工具参数无效，未建立草案。"]]] }
        guard let path = args["path"] as? String, let content = args["content"] as? String, let reason = args["reason"] as? String else { return ["success": false, "contentItems": [["type": "inputText", "text": "草案缺少路径、正文或理由。"]]] }
        let repository = MarkdownRepository(root: root)
        do {
            guard repository.isAllowedStudyPath(path) else { throw MarkdownError.outsideWorkspace }
            let original = try repository.read(path)
            let proposal = MarkdownChangeProposal(relativePath: path, originalContent: original, proposedContent: content, reason: reason, baseHash: repository.hash(original))
            proposals.removeAll { $0.relativePath == path }; proposals.append(proposal)
            let result = "已建立修改草案：\(path)。应用将展示差异，用户确认后才会写入。"
            return ["success": true, "contentItems": [["type": "inputText", "text": result]]]
        } catch { return ["success": false, "contentItems": [["type": "inputText", "text": "无法建立草案：\(error.localizedDescription)"]] ] }
    }
}

extension MarkdownRepository {
    struct Change { let relative: String; let content: String; let loadedHash: String }

    func isAllowedStudyPath(_ relative: String) -> Bool {
        guard !relative.isEmpty, relative == relative.replacingOccurrences(of: "\\", with: "/"), !relative.contains(".."), relative.hasSuffix(".md") else { return false }
        let allowed = ["PROFILE.md", "校历与重要日期.md"] + ["工作台/", "保研/", "规划/", "答疑/", "英语/", "笔记/", "专业/"]
        guard allowed.contains(where: { relative == $0 || relative.hasPrefix($0) }) else { return false }
        let target = url(relative).standardizedFileURL
        return target.path.hasPrefix(root.path + "/") && !MarkdownRepository.isSymbolicLink(target)
    }

    func saveBatch(_ changes: [Change]) throws {
        guard !changes.isEmpty else { return }
        var originals: [(URL, Data)] = []
        for change in changes {
            guard isAllowedStudyPath(change.relative) else { throw MarkdownError.outsideWorkspace }
            let target = url(change.relative).standardizedFileURL
            guard target.pathExtension.lowercased() == "md" else { throw MarkdownError.nonMarkdown }
            let current = try Data(contentsOf: target)
            let currentText = String(data: current, encoding: .utf8) ?? ""
            guard hash(currentText) == change.loadedHash else { throw MarkdownError.conflict }
            originals.append((target, current))
        }
        do {
            for change in changes { try save(change.content, relative: change.relative, loadedHash: change.loadedHash) }
        } catch {
            for (target, data) in originals { try? data.write(to: target, options: .atomic) }
            throw error
        }
    }
}

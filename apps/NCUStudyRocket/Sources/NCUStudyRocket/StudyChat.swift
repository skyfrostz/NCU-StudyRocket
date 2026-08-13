import Foundation
import SwiftUI
import AppKit
import CryptoKit

enum ChatConnectionState: String {
    case disconnected = "未连接"
    case connecting = "连接中..."
    case connected = "已连接"
    case thinking = "思考中..."
    case reconnecting = "重连中..."
    case stopped = "已停止"
    case failed = "连接失败"
}

enum ChatMessagePhase: String, Hashable {
    case commentary
    case finalAnswer = "final_answer"
    case unknown
}

enum ChatTurnState: String, Hashable {
    case completed
    case interrupted
    case failed
    case inProgress
}

struct ChatMessage: Identifiable, Hashable {
    enum Role: String { case user, assistant, system }
    let id: String
    let role: Role
    let text: String
    let date: Date
    let turnID: String?
    let phase: ChatMessagePhase
    let turnState: ChatTurnState?

    init(id: String, role: Role, text: String, date: Date, turnID: String? = nil, phase: ChatMessagePhase = .unknown, turnState: ChatTurnState? = nil) {
        self.id = id; self.role = role; self.text = text; self.date = date
        self.turnID = turnID; self.phase = phase; self.turnState = turnState
    }
}

struct ChatTurnPresentation: Identifiable, Hashable {
    let id: String
    var userMessage: ChatMessage?
    var finalMessages: [ChatMessage]
    var processMessages: [ChatMessage]
    var status: ChatTurnState
    var startedAt: Date?
    var completedAt: Date?
    var errorMessage: String?

    init(id: String, userMessage: ChatMessage? = nil, finalMessages: [ChatMessage] = [], processMessages: [ChatMessage] = [], status: ChatTurnState = .inProgress, startedAt: Date? = nil, completedAt: Date? = nil, errorMessage: String? = nil) {
        self.id = id; self.userMessage = userMessage; self.finalMessages = finalMessages
        self.processMessages = processMessages; self.status = status
        self.startedAt = startedAt; self.completedAt = completedAt; self.errorMessage = errorMessage
    }

    var date: Date { startedAt ?? userMessage?.date ?? completedAt ?? .now }
}

struct ChatTurnResult {
    let turnID: String
    let status: ChatTurnState
    let errorMessage: String?
    let completedAt: Date?
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
    private var turnContinuation: CheckedContinuation<ChatTurnResult, Error>?
    private var currentThreadID: String?
    private var activeTurnID: String?
    private var rootURL: URL?
    private var isDisconnecting = false
    private var completedItems = Set<String>()
    private var streamItems: [String: (text: String, phase: ChatMessagePhase)] = [:]
    private var stderrTail = ""
    private var connectionGeneration = 0
    private var lastDeltaEmission = Date.distantPast
    private var bufferedDeltas: [String: (turnID: String, itemID: String, text: String, phase: ChatMessagePhase)] = [:]
    private var deltaFlushTask: Task<Void, Never>?

    var onTurnStarted: ((String, Date?) -> Void)?
    var onReplyDelta: ((String, String, String, ChatMessagePhase) -> Void)?
    var onItemCompleted: ((String, String, String, ChatMessagePhase) -> Void)?
    var onToolCall: (([String: Any]) -> [String: Any])?
    var onTurnCompleted: ((ChatTurnResult) -> Void)?
    var onRetry: ((String) -> Void)?
    var onProcessEnded: ((String) -> Void)?
    var onHistory: (([ChatMessage]) -> Void)?

    var isRunning: Bool { process?.isRunning == true }
    var threadID: String? { currentThreadID }

    func connect(root: URL, threadID: String?) async throws -> String {
        if isRunning, self.rootURL?.standardizedFileURL == root.standardizedFileURL, currentThreadID == threadID, threadID != nil {
            return threadID!
        }
        if isRunning { disconnect() }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw StudyChatError.unavailable("找不到 Codex 本地程序，请先打开或更新 Codex。")
        }
        rootURL = root.standardizedFileURL
        isDisconnecting = false
        connectionGeneration += 1
        let generation = connectionGeneration
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in self?.processEnded(process, generation: generation, message: process.terminationReason == .uncaughtSignal ? "Codex 子进程异常退出。" : "Codex 子进程已退出。") }
        }
        try process.run()
        self.process = process; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consumeStderr(data) }
        }

        _ = try await request(method: "initialize", params: [
            "clientInfo": ["name": "ncu-studyrocket", "version": "1.1"],
            "capabilities": ["experimentalApi": true]
        ])
        sendNotification(method: "initialized", params: [:])

        let thread: [String: Any]
        if let threadID {
            let response = try await request(method: "thread/resume", params: [
                "threadId": threadID, "includeTurns": true, "cwd": root.path,
                "sandbox": "read-only", "approvalPolicy": "never", "runtimeWorkspaceRoots": [root.path],
                "developerInstructions": Self.developerInstructions
            ])
            thread = try resultObject(response)
            currentThreadID = threadID
        } else {
            let response = try await request(method: "thread/start", params: [
                "cwd": root.path, "sandbox": "read-only", "approvalPolicy": "never",
                "runtimeWorkspaceRoots": [root.path], "threadSource": "studyrocket",
                "developerInstructions": Self.developerInstructions, "dynamicTools": [Self.proposalTool, Self.skillProposalTool]
            ])
            thread = try resultObject(response)
            guard let newID = (thread["thread"] as? [String: Any])?["id"] as? String else {
                throw StudyChatError.protocolError("Codex 没有返回学业任务 ID。")
            }
            currentThreadID = newID
            _ = try? await request(method: "thread/name/set", params: ["threadId": newID, "name": "StudyRocket 学业助理"])
        }
        let history = await Task.detached(priority: .utility) { self.parseHistory(thread["thread"] as? [String: Any]) ?? [] }.value
        var turnOrder: [String] = []
        for id in history.compactMap(\.turnID) where !turnOrder.contains(id) { turnOrder.append(id) }
        let recentTurnIDs = Set(turnOrder.suffix(20))
        onHistory?(history.filter { $0.turnID.map(recentTurnIDs.contains) ?? false })
        return currentThreadID!
    }

    func send(_ text: String) async throws -> ChatTurnResult {
        guard let threadID = currentThreadID, isRunning else { throw StudyChatError.unavailable("学业对话尚未连接。") }
        guard turnContinuation == nil else { throw StudyChatError.unavailable("上一轮对话仍在运行。") }
        completedItems.removeAll(); streamItems.removeAll(); bufferedDeltas.removeAll(); deltaFlushTask?.cancel(); activeTurnID = nil
        let response = try await request(method: "turn/start", params: [
            "threadId": threadID, "input": [["type": "text", "text": text]],
            "cwd": rootURL?.path ?? FileManager.default.currentDirectoryPath,
            "sandboxPolicy": ["type": "readOnly", "networkAccess": true],
            "approvalPolicy": "never", "effort": "medium"
        ])
        guard let turn = response["turn"] as? [String: Any], let turnID = turn["id"] as? String else {
            throw StudyChatError.protocolError("Codex 没有返回本轮 turn ID。")
        }
        activeTurnID = turnID
        onTurnStarted?(turnID, date(fromUnix: turn["startedAt"]))
        return try await withCheckedThrowingContinuation { continuation in
            turnContinuation = continuation
        }
    }

    func interrupt() {
        guard let threadID = currentThreadID, let turnID = activeTurnID, isRunning else { return }
        sendRequest(method: "turn/interrupt", params: ["threadId": threadID, "turnId": turnID])
        activeTurnID = nil
        finishTurn(.success(ChatTurnResult(turnID: turnID, status: .interrupted, errorMessage: nil, completedAt: .now)))
    }

    func disconnect() {
        isDisconnecting = true
        connectionGeneration += 1
        output?.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        self.process = nil; input = nil; output = nil; currentThreadID = nil; activeTurnID = nil; deltaFlushTask?.cancel(); bufferedDeltas.removeAll()
        let error = StudyChatError.unavailable("学业对话已断开。")
        finishPending(with: error)
        finishTurn(.failure(error))
    }

    private func processEnded(_ process: Process, generation: Int, message: String) {
        guard generation == connectionGeneration, self.process === process, !isDisconnecting else { return }
        self.process = nil; input = nil; output = nil; currentThreadID = nil; activeTurnID = nil
        finishPending(with: StudyChatError.unavailable(message))
        finishTurn(.failure(StudyChatError.unavailable(message)))
        onProcessEnded?(message)
    }

    private func consumeStderr(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        stderrTail = String((stderrTail + text).suffix(8192))
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 10) {
            let line = outputBuffer.prefix(upTo: newline); outputBuffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func matchesCurrentTurn(_ params: [String: Any]) -> Bool {
        guard let threadID = params["threadId"] as? String, threadID == currentThreadID else { return false }
        guard let activeTurnID else { return false }
        return (params["turnId"] as? String ?? activeTurnID) == activeTurnID
    }

    private func handle(_ object: [String: Any]) {
        if let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = object["error"] as? [String: Any] {
                continuation.resume(throwing: StudyChatError.protocolError(error["message"] as? String ?? "Codex 请求失败。"))
            } else {
                continuation.resume(returning: object["result"] as? [String: Any] ?? [:])
            }
            return
        }
        guard let method = object["method"] as? String, let params = object["params"] as? [String: Any] else { return }
        switch method {
        case "item/started":
            guard matchesCurrentTurn(params), let item = params["item"] as? [String: Any], let itemID = item["id"] as? String else { return }
            let phase = ChatMessagePhase(rawValue: item["phase"] as? String ?? "") ?? .unknown
            streamItems[itemID] = ("", phase)
        case "item/agentMessage/delta":
            guard matchesCurrentTurn(params), let itemID = params["itemId"] as? String, let delta = params["delta"] as? String else { return }
            let phase = streamItems[itemID]?.phase ?? .unknown
            streamItems[itemID, default: ("", phase)].text += delta
            bufferDelta(turnID: activeTurnID!, itemID: itemID, text: streamItems[itemID]?.text ?? delta, phase: phase)
        case "item/completed":
            guard matchesCurrentTurn(params), let item = params["item"] as? [String: Any], let itemID = item["id"] as? String, !completedItems.contains(itemID) else { return }
            completedItems.insert(itemID)
            let phase = ChatMessagePhase(rawValue: item["phase"] as? String ?? "") ?? streamItems[itemID]?.phase ?? .unknown
            let text = (item["text"] as? String) ?? streamItems[itemID]?.text ?? ""
            bufferedDeltas.removeValue(forKey: itemID)
            streamItems[itemID] = (text, phase)
            onItemCompleted?(activeTurnID!, itemID, text, phase)
        case "item/tool/call":
            guard matchesCurrentTurn(params), let requestID = object["id"] else { return }
            let result = onToolCall?(params) ?? ["success": false, "contentItems": [["type": "inputText", "text": "应用未接收到该工具调用。"]]]
            sendRaw(["id": requestID, "result": result])
        case "turn/completed":
            guard matchesCurrentTurn(params), let turn = params["turn"] as? [String: Any] else { return }
            guard (turn["id"] as? String) == activeTurnID else { return }
            let rawStatus = turn["status"] as? String ?? "failed"
            let status = ChatTurnState(rawValue: rawStatus) ?? .failed
            let error = (turn["error"] as? [String: Any])?["message"] as? String
            let result = ChatTurnResult(turnID: activeTurnID!, status: status, errorMessage: error, completedAt: date(fromUnix: turn["completedAt"]))
            onTurnCompleted?(result)
            switch status {
            case .failed:
                finishTurn(.failure(StudyChatError.protocolError(error ?? "本轮对话失败。")))
            case .completed, .interrupted:
                finishTurn(.success(result))
            case .inProgress:
                break
            }
        case "error":
            guard let threadID = params["threadId"] as? String, threadID == currentThreadID else { return }
            if let eventTurnID = params["turnId"] as? String, eventTurnID != activeTurnID { return }
            let message = (params["error"] as? [String: Any])?["message"] as? String ?? "Codex 返回错误。"
            if params["willRetry"] as? Bool == true {
                onRetry?(message)
            } else {
                finishTurn(.failure(StudyChatError.protocolError(message)))
            }
        default: break
        }
    }

    private func finishTurn(_ result: Result<ChatTurnResult, Error>) {
        guard let continuation = turnContinuation else { return }
        turnContinuation = nil; activeTurnID = nil
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    private func bufferDelta(turnID: String, itemID: String, text: String, phase: ChatMessagePhase) {
        bufferedDeltas[itemID] = (turnID, itemID, text, phase)
        guard deltaFlushTask == nil else { return }
        deltaFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            let pending = self.bufferedDeltas.values
            self.bufferedDeltas.removeAll()
            self.deltaFlushTask = nil
            for delta in pending { self.onReplyDelta?(delta.turnID, delta.itemID, delta.text, delta.phase) }
        }
    }

    private func finishPending(with error: Error) {
        let continuations = pending.values; pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            requestID += 1; pending[requestID] = continuation
            sendRaw(["id": requestID, "method": method, "params": params])
        }
    }

    private func sendRequest(method: String, params: [String: Any]) {
        requestID += 1; sendRaw(["id": requestID, "method": method, "params": params])
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

    nonisolated private func date(fromUnix value: Any?) -> Date? {
        guard let seconds = value as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    nonisolated private func parseHistory(_ thread: [String: Any]?) -> [ChatMessage]? {
        guard let turns = thread?["turns"] as? [[String: Any]] else { return nil }
        var result: [ChatMessage] = []
        for turn in turns {
            guard let items = turn["items"] as? [[String: Any]] else { continue }
            guard let turnID = turn["id"] as? String else { continue }
            let status = ChatTurnState(rawValue: turn["status"] as? String ?? "")
            let startedAt = date(fromUnix: turn["startedAt"])
            let completedAt = date(fromUnix: turn["completedAt"])
            for item in items {
                guard let type = item["type"] as? String, let id = item["id"] as? String else { continue }
                if type == "agentMessage", let text = item["text"] as? String {
                    let phase = ChatMessagePhase(rawValue: item["phase"] as? String ?? "") ?? .unknown
                    result.append(ChatMessage(id: id, role: .assistant, text: text, date: completedAt ?? startedAt ?? .now, turnID: turnID, phase: phase, turnState: status))
                } else if type == "userMessage", let content = item["content"] as? [[String: Any]], let text = content.compactMap({ $0["text"] as? String }).first {
                    result.append(ChatMessage(id: id, role: .user, text: text, date: startedAt ?? completedAt ?? .now, turnID: turnID, turnState: status))
                }
            }
        }
        return result.isEmpty ? nil : result
    }

    static let proposalTool: [String: Any] = [
        "name": "studyrocket_propose_changes", "description": "提出对学业 Markdown 的修改草案。绝不直接写文件；应用会展示差异并等待用户确认。", "type": "function",
        "inputSchema": ["type": "object", "properties": ["path": ["type": "string", "description": "仓库内 Markdown 相对路径"], "content": ["type": "string", "description": "完整候选文件正文"], "reason": ["type": "string", "description": "修改理由"]], "required": ["path", "content", "reason"]]
    ]

    static let skillProposalTool: [String: Any] = [
        "name": "studyrocket_propose_skill_update", "description": "仅在周复盘发现连续、可证据的稳定规律时，提出仓库 Skill 的修改草案。绝不直接写文件，用户必须确认。", "type": "function",
        "inputSchema": ["type": "object", "properties": ["path": ["type": "string"], "content": ["type": "string"], "reason": ["type": "string"]], "required": ["path", "content", "reason"]]
    ]

    static let developerInstructions = """
    你是 StudyRocket 学业助理，只处理南昌大学玛丽女王学院数据科学与大数据技术（中外合作办学）学生的课程答疑、学习规划、复盘、科研、竞赛和保研问题。先读 AGENTS.md、PROFILE.md 和相关工作台 Markdown；遵守仓库规则，未知信息标记【待核实】，不编造 GPA、排名、名额、日期或推免比例。学校政策必须基于仓库官方文件，时效信息需要联网核实并给官方来源。
    你运行在只读任务中，绝不直接编辑、创建、删除或提交文件。用户要求更新计划、交付物、复盘或档案时，读取当前内容后调用 studyrocket_propose_changes，传入完整候选正文和理由；不要把文件修改藏在普通回答里。应用会在用户确认后写入。
    课程答疑采用“解释 -> 例子 -> 自测 -> 归档”。计划必须是可勾选交付物，保留缓冲并给撞车降级方案。只记录用户明确提供的事实，不把推测写进行为账。执行日结、周复盘、月复盘或规划前，读取工作台/助理偏好与习惯.md。只有周复盘中同类事实连续至少 3 次时，才可调用 studyrocket_propose_skill_update；不得把个人事实写进 Skill。
    沟通采用平衡型关怀：如果用户明确表达压力、挫败、疲惫、犹豫或任务受阻，先用 1-2 句具体、克制的承接，再给一个最小下一步或降级方案；如果用户报告了完成的交付物，先具体指出已完成的事实及其意义，再继续安排。普通事实问答不要机械加安慰语。禁止空泛鼓励、过度共情、心理诊断、依赖性表达和结果保证。情绪只用于当前回应，不写入每日账、复盘、习惯画像或其他 Markdown。
    """
}

@MainActor
final class StudyChatStore: ObservableObject {
    @Published var turns: [ChatTurnPresentation] = []
    @Published var proposals: [MarkdownChangeProposal] = []
    @Published var skillProposals: [SkillChangeProposal] = []
    @Published var expandedProcessTurnIDs = Set<String>()
    @Published var expandedProposalTurnIDs = Set<String>()
    @Published var draft = ""
    @Published var status = ChatConnectionState.disconnected.rawValue
    @Published var connectionState: ChatConnectionState = .disconnected
    @Published var errorMessage: String?
    @Published var isBusy = false
    @Published var lastSubmitted: String?
    @Published var scrollTargetID: String?
    @Published private(set) var threadID: String?
    private let client = CodexAppServerClient()
    private var root: URL?
    private var pendingPrompt: String?
    private var pendingUnknownMessages: [String: [ChatMessage]] = [:]
    private var pendingSubmissionID: String?

    private func threadKey(for root: URL) -> String {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "studyRocketThreadID.\(digest)"
    }

    init() {
        client.onTurnStarted = { [weak self] turnID, startedAt in
            self?.assignPendingSubmission(to: turnID, startedAt: startedAt)
        }
        client.onReplyDelta = { [weak self] turnID, itemID, delta, phase in
            self?.replaceStreaming(turnID: turnID, itemID: itemID, text: delta, phase: phase)
        }
        client.onItemCompleted = { [weak self] turnID, itemID, text, phase in
            guard let self else { return }
            if phase == .commentary {
                self.appendProcess(ChatMessage(id: itemID, role: .assistant, text: text, date: .now, turnID: turnID, phase: phase))
            } else if phase == .unknown {
                self.pendingUnknownMessages[turnID, default: []].append(ChatMessage(id: itemID, role: .assistant, text: text, date: .now, turnID: turnID, phase: phase))
            } else if !text.isEmpty {
                self.appendFinal(ChatMessage(id: itemID, role: .assistant, text: text, date: .now, turnID: turnID, phase: phase))
            }
        }
        client.onTurnCompleted = { [weak self] result in
            guard let self else { return }
            switch result.status {
            case .completed:
                if let unknown = self.pendingUnknownMessages.removeValue(forKey: result.turnID), !unknown.isEmpty {
                    unknown.dropLast().forEach(self.appendProcess)
                    if let final = unknown.last { self.appendFinal(final) }
                }
                self.completeTurn(result); self.setState(.connected); self.isBusy = false
            case .interrupted:
                self.pendingUnknownMessages.removeValue(forKey: result.turnID); self.completeTurn(result); self.setState(.stopped); self.isBusy = false
            case .failed:
                self.pendingUnknownMessages.removeValue(forKey: result.turnID); self.completeTurn(result); self.setState(.failed); self.isBusy = false; self.errorMessage = result.errorMessage ?? "本轮对话失败。"
            case .inProgress: break
            }
        }
        client.onRetry = { [weak self] message in
            guard let self else { return }
            self.setState(.reconnecting); self.errorMessage = nil
            if !message.isEmpty { self.status = "重连中..." }
        }
        client.onProcessEnded = { [weak self] message in
            guard let self else { return }
            self.isBusy = false; self.markLatestTurn(.failed, errorMessage: message); self.setState(.failed); self.errorMessage = message
        }
        client.onHistory = { [weak self] history in
            guard let self else { return }
            self.turns = Self.present(history)
        }
        client.onToolCall = { [weak self] params in self?.receiveToolCall(params) ?? ["success": false, "contentItems": []] }
    }

    private func setState(_ state: ChatConnectionState) { connectionState = state; status = state.rawValue }

    private func turnIndex(_ id: String) -> Int? { turns.firstIndex(where: { $0.id == id }) }

    private func ensureTurn(_ id: String, date: Date? = nil) -> Int {
        if let index = turnIndex(id) { return index }
        turns.append(ChatTurnPresentation(id: id, startedAt: date))
        return turns.count - 1
    }

    private func assignPendingSubmission(to turnID: String, startedAt: Date?) {
        guard let pendingSubmissionID, let index = turnIndex(pendingSubmissionID) else { return }
        var turn = turns.remove(at: index)
        turn = ChatTurnPresentation(id: turnID, userMessage: turn.userMessage.map { ChatMessage(id: $0.id, role: $0.role, text: $0.text, date: startedAt ?? $0.date, turnID: turnID, phase: $0.phase, turnState: .inProgress) }, finalMessages: turn.finalMessages, processMessages: turn.processMessages, status: .inProgress, startedAt: startedAt ?? turn.startedAt, completedAt: nil)
        turns.insert(turn, at: index)
        self.pendingSubmissionID = nil
    }

    private func replaceStreaming(turnID: String, itemID: String, text: String, phase: ChatMessagePhase) {
        let index = ensureTurn(turnID)
        var turn = turns[index]
        let partial = ChatMessage(id: "streaming-\(itemID)", role: .assistant, text: text, date: .now, turnID: turnID, phase: phase)
        if phase == .commentary {
            if let existing = turn.processMessages.firstIndex(where: { $0.id == partial.id }) {
                let previous = turn.processMessages[existing]
                turn.processMessages[existing] = ChatMessage(id: previous.id, role: .assistant, text: text, date: previous.date, turnID: turnID, phase: phase)
            } else { turn.processMessages.append(partial) }
        } else {
            if let existing = turn.finalMessages.firstIndex(where: { $0.id == partial.id }) {
                let previous = turn.finalMessages[existing]
                turn.finalMessages[existing] = ChatMessage(id: previous.id, role: .assistant, text: text, date: previous.date, turnID: turnID, phase: phase)
            } else { turn.finalMessages.append(partial) }
        }
        turns[index] = turn
    }

    private func appendProcess(_ message: ChatMessage) {
        guard let turnID = message.turnID else { return }
        let index = ensureTurn(turnID)
        var turn = turns[index]
        turn.processMessages.removeAll { $0.id == message.id || $0.id == "streaming-\(message.id)" }
        turn.processMessages.append(message); turns[index] = turn
    }

    private func appendFinal(_ message: ChatMessage) {
        guard let turnID = message.turnID else { return }
        let index = ensureTurn(turnID)
        var turn = turns[index]
        turn.finalMessages.removeAll { $0.id == message.id || $0.id == "streaming-\(message.id)" }
        turn.finalMessages.append(message); turns[index] = turn
        scrollTargetID = turnID
    }

    private func completeTurn(_ result: ChatTurnResult) {
        let index = ensureTurn(result.turnID)
        var turn = turns[index]
        turn.status = result.status; turn.completedAt = result.completedAt ?? .now; turn.errorMessage = result.errorMessage
        if let user = turn.userMessage {
            turn.userMessage = ChatMessage(id: user.id, role: user.role, text: user.text, date: user.date, turnID: result.turnID, phase: user.phase, turnState: result.status)
        }
        turns[index] = turn
        if result.status == .failed { scrollTargetID = result.turnID }
    }

    private func markLatestTurn(_ status: ChatTurnState, errorMessage: String? = nil) {
        guard let index = turns.indices.last else { return }
        var turn = turns[index]; turn.status = status; turn.errorMessage = errorMessage; turn.completedAt = .now
        if let user = turn.userMessage { turn.userMessage = ChatMessage(id: user.id, role: user.role, text: user.text, date: user.date, turnID: user.turnID, phase: user.phase, turnState: status) }
        turns[index] = turn
        if status == .failed { scrollTargetID = turn.id }
    }

    static func present(_ history: [ChatMessage]) -> [ChatTurnPresentation] {
        var output: [ChatTurnPresentation] = []
        for message in history {
            guard let turnID = message.turnID else { continue }
            let index = output.firstIndex(where: { $0.id == turnID }) ?? {
                output.append(ChatTurnPresentation(id: turnID, status: message.turnState ?? .completed, startedAt: message.date, completedAt: message.turnState == .inProgress ? nil : message.date))
                return output.count - 1
            }()
            var turn = output[index]
            if message.role == .user { turn.userMessage = message; turn.startedAt = message.date }
            else if message.phase == .commentary { turn.processMessages.append(message) }
            else { turn.finalMessages.append(message) }
            if let state = message.turnState { turn.status = state; if state != .inProgress { turn.completedAt = message.date } }
            output[index] = turn
        }
        return output
    }

    func connect(to root: URL) async { await connectInternal(to: root, forceCreate: false) }

    private func connectInternal(to root: URL, forceCreate: Bool) async {
        if !forceCreate, self.root?.standardizedFileURL == root.standardizedFileURL, client.isRunning { return }
        self.root = root.standardizedFileURL
        turns = []; pendingUnknownMessages.removeAll(); proposals = []; skillProposals = []; expandedProcessTurnIDs.removeAll(); expandedProposalTurnIDs.removeAll(); errorMessage = nil; setState(.connecting)
        let key = threadKey(for: root)
        let stored = forceCreate ? nil : UserDefaults.standard.string(forKey: key)
        threadID = stored
        do {
            let id = try await client.connect(root: root, threadID: stored)
            threadID = id; UserDefaults.standard.set(id, forKey: key); setState(.connected)
            if let pendingPrompt { draft = pendingPrompt; self.pendingPrompt = nil }
        } catch {
            client.disconnect(); setState(.failed); errorMessage = error.localizedDescription
        }
    }

    func reconnect() async {
        guard let root else { return }
        client.disconnect(); await connectInternal(to: root, forceCreate: false)
    }

    func createNewTask() async {
        guard let root else { return }
        UserDefaults.standard.removeObject(forKey: threadKey(for: root)); client.disconnect(); threadID = nil
        await connectInternal(to: root, forceCreate: true)
    }

    var canCreateNewTask: Bool { root != nil && connectionState == .failed }
    func prepare(prompt: String) { pendingPrompt = prompt; draft = prompt }

    func toggleProcess(for turnID: String) {
        if expandedProcessTurnIDs.contains(turnID) { expandedProcessTurnIDs.remove(turnID) }
        else { expandedProcessTurnIDs.insert(turnID) }
    }

    func toggleProposal(for turnID: String) {
        if expandedProposalTurnIDs.contains(turnID) { expandedProposalTurnIDs.remove(turnID) }
        else { expandedProposalTurnIDs.insert(turnID) }
    }

    func setProposal(_ id: UUID, selected: Bool) {
        guard let index = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals[index].isSelected = selected
    }

    func send() { send(appendUser: true) }

    private func send(appendUser: Bool) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        lastSubmitted = text
        if appendUser {
            let localID = "local-\(UUID().uuidString)"
            pendingSubmissionID = localID
            turns.append(ChatTurnPresentation(id: localID, userMessage: ChatMessage(id: UUID().uuidString, role: .user, text: text, date: .now, turnID: localID, turnState: .inProgress), status: .inProgress, startedAt: .now))
            scrollTargetID = localID
        }
        draft = ""; errorMessage = nil; isBusy = true; setState(.thinking); pendingUnknownMessages.removeAll()
        Task {
            do {
                let result = try await client.send(text)
                if result.status == .interrupted { setState(.stopped) }
            } catch {
                isBusy = false; setState(.failed); errorMessage = error.localizedDescription; if draft.isEmpty { draft = text }
            }
        }
    }

    func retryLast() { guard let lastSubmitted else { return }; draft = lastSubmitted; send(appendUser: true) }
    func stop() { client.interrupt(); markLatestTurn(.interrupted); isBusy = false; setState(.stopped) }
    func disconnect() { client.disconnect(); isBusy = false; setState(.disconnected) }

    func applySelectedChanges(workspace: WorkspaceStore, for turnID: String) {
        let selected = proposals.filter { $0.turnID == turnID && $0.isSelected }; guard !selected.isEmpty else { return }
        do {
            let changes = selected.map { MarkdownRepository.Change(relative: $0.relativePath, content: $0.proposedContent, loadedHash: $0.baseHash) }
            try MarkdownRepository(root: workspace.rootURL).saveBatch(changes)
            proposals.removeAll { selected.contains($0) }; workspace.refreshGitStatus()
        } catch { errorMessage = error.localizedDescription }
    }

    func applySelectedSkillChanges(workspace: WorkspaceStore, for turnID: String) {
        let selected = skillProposals.filter { $0.turnID == turnID && $0.isSelected }
        guard !selected.isEmpty else { return }
        let repository = MarkdownRepository(root: workspace.rootURL)
        do {
            for proposal in selected {
                guard SkillRepository.isAllowed(relative: proposal.relativePath) else { throw MarkdownError.outsideWorkspace }
                let url = workspace.rootURL.appendingPathComponent(proposal.relativePath)
                let current = try String(contentsOf: url, encoding: .utf8)
                guard repository.hash(current) == proposal.baseHash else { throw MarkdownError.conflict }
                try SkillRepository.validate(proposal.proposedContent)
            }
            for proposal in selected {
                try Data(proposal.proposedContent.utf8).write(to: workspace.rootURL.appendingPathComponent(proposal.relativePath), options: .atomic)
            }
            skillProposals.removeAll { selected.contains($0) }
            workspace.refreshGitStatus()
        } catch { errorMessage = error.localizedDescription }
    }

    func openInCodex() {
        guard let threadID else { return }
        var components = URLComponents(); components.scheme = "codex"; components.host = "threads"; components.path = "/\(threadID)"
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private func receiveToolCall(_ params: [String: Any]) -> [String: Any] {
        guard let tool = params["tool"] as? String, let root else {
            return ["success": false, "contentItems": [["type": "inputText", "text": "工具参数无效，未建立草案。"]]]
        }
        let args: [String: Any]
        if let object = params["arguments"] as? [String: Any] { args = object }
        else if let string = params["arguments"] as? String, let data = string.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { args = object }
        else { return ["success": false, "contentItems": [["type": "inputText", "text": "工具参数无效，未建立草案。"]]] }
        guard let path = args["path"] as? String, let content = args["content"] as? String, let reason = args["reason"] as? String else { return ["success": false, "contentItems": [["type": "inputText", "text": "草案缺少路径、正文或理由。"]]] }
        let repository = MarkdownRepository(root: root)
        do {
            if tool == "studyrocket_propose_skill_update" {
                guard let turnID = params["turnId"] as? String, SkillRepository.isAllowed(relative: path) else { throw MarkdownError.outsideWorkspace }
                let url = root.appendingPathComponent(path)
                let original = try String(contentsOf: url, encoding: .utf8)
                try SkillRepository.validate(content)
                let proposal = SkillChangeProposal(turnID: turnID, relativePath: path, originalContent: original, proposedContent: content, reason: reason, baseHash: repository.hash(original))
                skillProposals.removeAll { $0.turnID == turnID && $0.relativePath == path }
                skillProposals.append(proposal)
                return ["success": true, "contentItems": [["type": "inputText", "text": "已建立 Skill 修改草案，等待用户确认。"]]]
            }
            guard tool == "studyrocket_propose_changes" else { throw StudyChatError.protocolError("不支持的工具。") }
            guard repository.isAllowedStudyPath(path) else { throw MarkdownError.outsideWorkspace }
            let original = try repository.read(path)
            guard let turnID = params["turnId"] as? String else { throw StudyChatError.protocolError("草案缺少回合 ID。") }
            let proposal = MarkdownChangeProposal(turnID: turnID, relativePath: path, originalContent: original, proposedContent: content, reason: reason, baseHash: repository.hash(original))
            proposals.removeAll { $0.turnID == turnID && $0.relativePath == path }; proposals.append(proposal)
            return ["success": true, "contentItems": [["type": "inputText", "text": "已建立修改草案：\(path)。应用将展示差异，用户确认后才会写入。"]]]
        } catch { return ["success": false, "contentItems": [["type": "inputText", "text": "无法建立草案：\(error.localizedDescription)"]] ] }
    }
}

enum SkillRepository {
    static let names = Set(["daily-checkin", "knowledge-ingest", "ncu-planner", "node-countdown", "retro-monthly", "retro-weekly", "term-roadmap", "weekly-reslot"])

    static func isAllowed(relative: String) -> Bool {
        let pieces = relative.split(separator: "/").map(String.init)
        return pieces.count == 4 && pieces[0] == ".agents" && pieces[1] == "skills" && names.contains(pieces[2]) && pieces[3] == "SKILL.md"
    }

    static func validate(_ content: String) throws {
        let lines = content.components(separatedBy: .newlines)
        guard lines.count <= 300, lines.first == "---", lines.dropFirst().contains("---"), content.contains("name:"), content.contains("description:") else {
            throw StudyChatError.protocolError("Skill 草案必须保留有效 frontmatter，且不得超过 300 行。")
        }
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

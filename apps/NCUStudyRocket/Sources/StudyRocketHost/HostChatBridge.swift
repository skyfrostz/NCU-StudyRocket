import Foundation
import AppKit
import CryptoKit
import StudyRocketShared
import StudyRocketChatCore

enum HostChatError: LocalizedError {
    case unavailable(String)
    case protocolError(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let value), .protocolError(let value): return value
        }
    }
}

/// A small, lock-protected one-shot bridge between the Host's callback-based
/// startup deadline and its async Codex self-check.  It deliberately uses the
/// main dispatch queue for the deadline: a stalled app-server must not depend
/// on the cooperative Swift task executor in order to leave `.starting`.
private final class HostStartupCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var completed = false

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if completed {
            lock.unlock()
            continuation.resume(throwing: HostChatError.unavailable("Host 自检已结束。"))
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !completed, let continuation else { lock.unlock(); return }
        completed = true
        self.continuation = nil
        lock.unlock()
        switch result {
        case .success: continuation.resume()
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

@MainActor
private final class HostCodexSession {
    private let executable = "/Applications/ChatGPT.app/Contents/Resources/codex"
    private let root: URL
    private let descriptorStore = StudyRocketTaskDescriptorStore()
    private var threadID: String
    private var migratedHistory: [ChatMessageDTO] = []
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outputBuffer = Data()
    private var requestID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var turnContinuation: CheckedContinuation<Void, Error>?
    private var pendingTurnResult: Result<Void, Error>?
    private var activeTurnID: String?
    private var replyItems: [String: String] = [:]
    private var completedItemIDs = Set<String>()
    private var history: [ChatMessageDTO] = []
    private var idleShutdownTask: Task<Void, Never>?
    var onToolCall: (([String: Any]) -> [String: Any])?
    var onProcessExit: (() -> Void)?
    var onReplyDelta: ((String, String, String, String?) -> Void)?
    var onItemCompleted: ((String, String, String, String?) -> Void)?
    var onTurnStatus: ((String, String, String?) -> Void)?

    init(root: URL, threadID: String = StudyRocketThreadProtocol.legacyHostThreadID) {
        self.root = root.standardizedFileURL
        self.threadID = threadID
    }

    var isRunning: Bool { process?.isRunning == true }
    var currentThreadID: String { threadID }

    private func processDidTerminate() {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
        input = nil
        output = nil
        process = nil
        let error = HostChatError.unavailable("Codex 本地任务已退出，请重新连接。")
        let interruptedTurnID = activeTurnID
        let requests = pending.values
        pending.removeAll()
        for continuation in requests { continuation.resume(throwing: error) }
        if let continuation = turnContinuation {
            turnContinuation = nil
            activeTurnID = nil
            continuation.resume(throwing: error)
        }
        pendingTurnResult = nil
        if let interruptedTurnID { onTurnStatus?(interruptedTurnID, "failed", error.localizedDescription) }
        onProcessExit?()
    }

    func connect() async throws {
        if isRunning {
            touchActivity()
            return
        }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw HostChatError.unavailable("找不到 Codex 本地程序。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.processDidTerminate() }
        }
        try process.run()
        self.process = process
        touchActivity()
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        // Do not rely on FileHandle.readabilityHandler here.  In a packaged
        // AppKit process it can fail to fire for a quiet child, leaving a
        // perfectly healthy app-server response buffered forever.  A blocking
        // reader on a utility queue keeps stdout flowing and drains stderr so
        // neither pipe can back-pressure the child process.
        beginReadingStdout(stdout.fileHandleForReading)
        drain(stderr.fileHandleForReading)

        _ = try await request(method: "initialize", params: [
            "clientInfo": ["name": "ncu-studyrocket-host", "version": "0.1.0"],
            "capabilities": ["experimentalApi": true]
        ])
        sendNotification(method: "initialized", params: [:])
        let descriptor = descriptorStore.load(for: root)
        let compatibleThreadID = descriptor?.protocolVersion == StudyRocketThreadProtocol.currentVersion ? descriptor?.threadID : nil
        let legacyThreadID = compatibleThreadID == nil ? (descriptor?.threadID ?? threadID) : nil
        if let legacyThreadID {
            if let response = try? await request(method: "thread/read", params: ["threadId": legacyThreadID, "includeTurns": true]),
               let legacyThread = try? resultObject(response) {
                migratedHistory = parseHistory((legacyThread["thread"] as? [String: Any]) ?? legacyThread)
            }
        }
        if let compatibleThreadID {
            threadID = compatibleThreadID
            _ = try await request(method: "thread/resume", params: [
                "threadId": threadID,
                "includeTurns": true,
                "cwd": root.path,
                "sandbox": "read-only",
                "approvalPolicy": "never",
                "runtimeWorkspaceRoots": [root.path],
                "developerInstructions": Self.developerInstructions
            ])
        } else {
            let response = try await request(method: "thread/start", params: [
                "cwd": root.path,
                "sandbox": "read-only",
                "approvalPolicy": "never",
                "runtimeWorkspaceRoots": [root.path],
                "threadSource": "studyrocket",
                "developerInstructions": Self.developerInstructions(legacyHistory: migratedHistory),
                "dynamicTools": StudyRocketDynamicToolContract.declaration
            ])
            guard let newID = (try resultObject(response)["thread"] as? [String: Any])?["id"] as? String else {
                throw HostChatError.protocolError("Codex 没有返回学业任务 ID。")
            }
            threadID = newID
            try? descriptorStore.save(StudyRocketTaskDescriptor(threadID: newID), for: root)
            _ = try? await request(method: "thread/name/set", params: ["threadId": newID, "name": "StudyRocket 学业助理"])
        }
        guard StudyRocketDynamicToolContract.declarationIsValid else {
            throw HostChatError.protocolError("StudyRocket 草案工具声明校验失败。")
        }
    }

    func loadHistory() async throws -> ChatHistoryResponse {
        try await connect()
        touchActivity()
        let response = try await request(method: "thread/read", params: ["threadId": threadID, "includeTurns": true])
        let result = (response["thread"] as? [String: Any]) ?? response
        let currentHistory = parseHistory(result)
        var byID = Dictionary(uniqueKeysWithValues: migratedHistory.map { ($0.id, $0) })
        for message in currentHistory { byID[message.id] = message }
        history = Array(byID.values.sorted { $0.date < $1.date }.suffix(30))
        return ChatHistoryResponse(revision: String(history.count), messages: history)
    }

    func send(_ text: String) async throws {
        try await connect()
        touchActivity()
        guard turnContinuation == nil else { throw HostChatError.unavailable("上一轮学业对话仍在运行。") }
        replyItems.removeAll()
        completedItemIDs.removeAll()
        let response = try await request(method: "turn/start", params: [
            "threadId": threadID,
            "input": [["type": "text", "text": text]],
            "cwd": root.path,
            "sandboxPolicy": ["type": "readOnly", "networkAccess": true],
            "approvalPolicy": "never",
            "effort": "medium"
        ])
        guard let turn = response["turn"] as? [String: Any], let turnID = turn["id"] as? String else {
            throw HostChatError.protocolError("Codex 没有返回本轮 turn ID。")
        }
        activeTurnID = turnID
        onTurnStatus?(turnID, "inProgress", nil)
        try await withCheckedThrowingContinuation { continuation in
            if let pendingTurnResult {
                self.pendingTurnResult = nil
                switch pendingTurnResult {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            } else {
                turnContinuation = continuation
            }
        }
        _ = try? await loadHistory()
    }

    func interrupt() {
        touchActivity()
        guard let activeTurnID, let input else { return }
        sendRaw(["id": nextID(), "method": "turn/interrupt", "params": ["threadId": threadID, "turnId": activeTurnID]], to: input)
    }

    func shutdown() {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
        if process?.isRunning == true { process?.terminate() }
        processDidTerminate()
    }

    private func touchActivity() {
        idleShutdownTask?.cancel()
        idleShutdownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.turnContinuation == nil else {
                self.touchActivity()
                return
            }
            self.shutdown()
        }
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 10) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func handle(_ object: [String: Any]) {
        if let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                continuation.resume(throwing: HostChatError.protocolError(message))
            } else {
                continuation.resume(returning: (object["result"] as? [String: Any]) ?? [:])
            }
            return
        }
        guard let method = object["method"] as? String, let params = object["params"] as? [String: Any] else { return }
        switch method {
        case "item/agentMessage/delta":
            guard let turnID = StudyRocketDynamicToolContract.routedTurnID(
                eventThreadID: params["threadId"] as? String,
                currentThreadID: threadID,
                activeTurnID: activeTurnID
            ),
                  let itemID = params["itemId"] as? String, let delta = params["delta"] as? String,
                  !completedItemIDs.contains(itemID) else { return }
            replyItems[itemID, default: ""] += delta
            onReplyDelta?(turnID, itemID, delta, params["phase"] as? String)
        case "item/completed":
            guard let turnID = StudyRocketDynamicToolContract.routedTurnID(
                eventThreadID: params["threadId"] as? String,
                currentThreadID: threadID,
                activeTurnID: activeTurnID
            ),
                  let item = params["item"] as? [String: Any],
                  item["type"] as? String == "agentMessage",
                  let itemID = item["id"] as? String,
                  let text = item["text"] as? String,
                  completedItemIDs.insert(itemID).inserted else { return }
            replyItems[itemID] = text
            onItemCompleted?(turnID, itemID, text, item["phase"] as? String)
        case "item/tool/call":
            guard let requestID = object["id"] else { return }
            guard let routedTurnID = StudyRocketDynamicToolContract.routedTurnID(
                eventThreadID: params["threadId"] as? String,
                currentThreadID: threadID,
                activeTurnID: activeTurnID
            ) else {
                sendRaw(["id": requestID, "result": [
                    "success": false,
                    "contentItems": [["type": "inputText", "text": "草案工具回合已失效，未建立修改草案。"]]
                ]])
                return
            }
            var routedParams = params
            routedParams["turnId"] = routedTurnID
            let result = onToolCall?(routedParams) ?? ["success": false, "contentItems": [["type": "inputText", "text": "应用未接收到草案工具调用。"]]]
            sendRaw(["id": requestID, "result": result])
        case "turn/completed":
            guard params["threadId"] as? String == threadID,
                  let turn = params["turn"] as? [String: Any],
                  let completedTurnID = turn["id"] as? String,
                  completedTurnID == activeTurnID else { return }
            let status = turn["status"] as? String ?? "failed"
            activeTurnID = nil
            let error = (turn["error"] as? [String: Any])?["message"] as? String
            onTurnStatus?(completedTurnID, status, error)
            if status == "completed" || status == "interrupted" {
                finishTurn(.success(()))
            } else {
                let message = error ?? "学业对话失败。"
                finishTurn(.failure(HostChatError.protocolError(message)))
            }
        case "error":
            guard params["threadId"] as? String == threadID else { return }
            guard let activeTurnID,
                  (params["turnId"] as? String ?? activeTurnID) == activeTurnID else { return }
            if params["willRetry"] as? Bool == true { return }
            let message = (params["error"] as? [String: Any])?["message"] as? String ?? "Codex 返回错误。"
            onTurnStatus?(activeTurnID, "failed", message)
            finishTurn(.failure(HostChatError.protocolError(message)))
        default: break
        }
    }

    private func finishTurn(_ result: Result<Void, Error>) {
        activeTurnID = nil
        if let continuation = turnContinuation {
            turnContinuation = nil
            switch result {
            case .success: continuation.resume()
            case .failure(let error): continuation.resume(throwing: error)
            }
        } else {
            pendingTurnResult = result
        }
    }

    private func parseHistory(_ thread: [String: Any]) -> [ChatMessageDTO] {
        guard let turns = thread["turns"] as? [[String: Any]] else { return [] }
        var messages: [ChatMessageDTO] = []
        for turn in turns.suffix(10) {
            guard let id = turn["id"] as? String, let items = turn["items"] as? [[String: Any]] else { continue }
            let status = turn["status"] as? String
            let date = date(from: turn["completedAt"] ?? turn["startedAt"]) ?? .now
            for item in items {
                guard let itemID = item["id"] as? String, let type = item["type"] as? String else { continue }
                if type == "agentMessage", let text = item["text"] as? String {
                    messages.append(ChatMessageDTO(id: itemID, role: "assistant", text: text, date: date, turnID: id, phase: item["phase"] as? String, status: status))
                } else if type == "userMessage", let content = item["content"] as? [[String: Any]], let text = content.compactMap({ $0["text"] as? String }).first {
                    messages.append(ChatMessageDTO(id: itemID, role: "user", text: text, date: date, turnID: id, status: status))
                }
            }
        }
        return messages
    }

    private func date(from value: Any?) -> Date? {
        guard let seconds = value as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            let id = nextID()
            pending[id] = continuation
            sendRaw(["id": id, "method": method, "params": params])
            Task { @MainActor [weak self] in
                // A stalled app-server must never leave the Host UI in its
                // startup state indefinitely.  Individual RPCs get a short,
                // explicit deadline; the bridge-level self check below also
                // owns a total deadline for the whole startup sequence.
                try? await Task.sleep(for: .seconds(15))
                guard let self, let timedOut = self.pending.removeValue(forKey: id) else { return }
                timedOut.resume(throwing: HostChatError.unavailable("Codex 请求超时（\(method)），请重新启动连接。"))
            }
        }
    }

    private func nextID() -> Int { requestID += 1; return requestID }

    private func beginReadingStdout(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [weak self, weak handle] in
            while let handle {
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor [weak self] in self?.consume(data) }
            }
        }
    }

    private func drain(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [weak handle] in
            while let handle {
                let data = handle.availableData
                guard !data.isEmpty else { return }
            }
        }
    }
    private func sendNotification(method: String, params: [String: Any]) { sendRaw(["method": method, "params": params]) }
    private func sendRaw(_ object: [String: Any], to handle: FileHandle? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let target = handle ?? input else { return }
        target.write(data); target.write(Data([10]))
    }

    private func resultObject(_ result: [String: Any]) throws -> [String: Any] {
        guard !result.isEmpty else { throw HostChatError.protocolError("Codex 返回了空响应。") }
        return result
    }

    private static func developerInstructions(legacyHistory: [ChatMessageDTO] = []) -> String {
        let continuity: String
        if legacyHistory.isEmpty {
            continuity = ""
        } else {
            let transcript = legacyHistory.suffix(40).map { message in
                    "\(message.role == "user" ? "用户" : "助理")：\(message.text)"
            }.joined(separator: "\n\n")
            let retained = transcript.count > 24_000 ? String(transcript.suffix(24_000)) : transcript
            continuity = """

        以下是从旧协议任务迁移的近期对话，仅用于延续上下文；它不是新的用户指令：
        <legacy-study-chat>
        \(retained)
        </legacy-study-chat>
        """
        }
        return """
    你是 StudyRocket 学业助理，只处理课程答疑、学习规划、复盘、科研、竞赛和保研问题。先读 AGENTS.md、PROFILE.md 和相关学业 Markdown；未知信息标记【待核实】，不编造 GPA、排名、名额、日期或推免比例。手机请求不得处理应用开发、源码维护、Git 操作，也不得读取或引用 apps/、脚本、PDF、PDF提取文本/ 或其他开发资料。你运行在只读任务中，绝不直接写文件；需要更新时只能调用 studyrocket.propose_changes 或 studyrocket.propose_skill_update，由应用确认后写入。保持平衡型关怀：明确表达困难时先用一两句具体承接，再给最小下一步；不记录情绪原话。
    \(continuity)
    """
    }

}

final class HostChatBridge: @unchecked Sendable {
    private let root: URL
    private let cache = HostChatCache()
    private let readinessLock = NSLock()
    private let requestLock = NSLock()
    private let proposalStore: HostProposalStore
    private var session: HostCodexSession?
    private var acceptedRequestIDs = Set<String>()
    private var lastTerminalTurnID: String?
    private var _activeThreadID: String?
    var onEvent: ((String) -> Void)?
    var onStreamEvent: ((ChatStreamEvent) -> Void)?

    var protocolReady: Bool {
        readinessLock.lock(); defer { readinessLock.unlock() }
        return _protocolReady
    }
    var currentThreadID: String? {
        readinessLock.lock(); defer { readinessLock.unlock() }
        return _activeThreadID
    }
    private var _protocolReady = false

    init(root: URL) {
        self.root = root.standardizedFileURL
        proposalStore = HostProposalStore(root: root.standardizedFileURL)
    }

    func history() -> ChatHistoryResponse {
        cache.value
    }

    /// Resume the fixed task before the Host exposes chat and proposal features.
    /// This makes a malformed dynamic-tool declaration fail at Host startup rather
    /// than surfacing later as a `namespace: null` tool error on the phone.
    func selfCheck() async throws {
        guard StudyRocketDynamicToolContract.declarationIsValid else {
            throw HostChatError.protocolError("StudyRocket 草案工具声明校验失败。")
        }
        // `connectHistory` crosses the app-server's asynchronous stdio
        // boundary.  A process can stay alive while never returning a
        // response (for example after a local Codex upgrade), so a per-RPC
        // timeout alone is not enough to guarantee that startup finishes.
        // Use the main run loop rather than a sibling Swift task for this
        // deadline; it continues to fire even if the cooperative executor is
        // occupied by the suspended stdio bridge.
        let completion = HostStartupCompletion()
        try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                completion.finish(.failure(HostChatError.unavailable("Codex 自检超时（25 秒），Host 已停止。请重新启动连接。")))
            }
            Task { [weak self] in
                guard let self else {
                    completion.finish(.failure(HostChatError.unavailable("Host 会话不可用。")))
                    return
                }
                do {
                    _ = try await self.connectHistory()
                    completion.finish(.success(()))
                } catch {
                    completion.finish(.failure(error))
                }
            }
        }
        setProtocolReady(true)
        onEvent?("chat.ready")
    }

    @discardableResult
    func send(_ text: String, requestID: String) -> Bool {
        guard !requestID.isEmpty else { return false }
        requestLock.lock()
        guard acceptedRequestIDs.insert(requestID).inserted else {
            requestLock.unlock()
            return false
        }
        if acceptedRequestIDs.count > 256, let first = acceptedRequestIDs.first {
            acceptedRequestIDs.remove(first)
        }
        requestLock.unlock()
        Task { @MainActor [weak self] in
            guard let self else { return }
            onEvent?("chat.started")
            ensureSession()
            lastTerminalTurnID = nil
            var succeeded = false
            do {
                try await session?.send(text)
                if let threadID = session?.currentThreadID {
                    setActiveThreadID(threadID)
                }
                if let value = try await session?.loadHistory() {
                    cache.set(value)
                }
                setProtocolReady(true)
                succeeded = true
            } catch {
                setProtocolReady(false)
                if session?.isRunning == true, let value = try? await session?.loadHistory() {
                    cache.set(value)
                }
                if lastTerminalTurnID == nil {
                    onStreamEvent?(ChatStreamEvent(kind: "status", text: error.localizedDescription, status: "failed"))
                }
                releaseRequestID(requestID)
                NSLog("StudyRocket Host chat error: %@", error.localizedDescription)
            }
            onEvent?(succeeded ? "chat.completed" : "chat.failed")
        }
        return true
    }

    func interrupt() {
        Task { @MainActor [weak self] in
            self?.session?.interrupt()
        }
        onEvent?("chat.interrupted")
    }

    func shutdown() {
        setProtocolReady(false)
        readinessLock.lock(); _activeThreadID = nil; readinessLock.unlock()
        // Retain the session until its app-server receives the termination signal.
        // A weak capture could be released with the HTTP server before this task ran,
        // leaving a fixed-thread writer alive across a Host restart.
        let retiringSession = session
        session = nil
        Task { @MainActor in
            retiringSession?.shutdown()
        }
    }

    func connectHistory() async throws -> ChatHistoryResponse {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor [weak self] in
                guard let self else {
                    continuation.resume(throwing: HostChatError.unavailable("Host 会话不可用。"))
                    return
                }
                ensureSession()
                do {
                    guard let value = try await session?.loadHistory() else { throw HostChatError.unavailable("Host 会话不可用。") }
                    if let threadID = session?.currentThreadID {
                        setActiveThreadID(threadID)
                    }
                    cache.set(value)
                    setProtocolReady(true)
                    continuation.resume(returning: value)
                } catch {
                    setProtocolReady(false)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func proposals() -> ProposalListResponse { proposalStore.list() }

    func apply(_ request: ProposalApplyRequest) throws -> ProposalListResponse { try proposalStore.apply(request) }

    private func setActiveThreadID(_ threadID: String?) {
        readinessLock.lock()
        _activeThreadID = threadID
        readinessLock.unlock()
    }

    @MainActor
    private func ensureSession() {
        guard session == nil else { return }
        let value = HostCodexSession(root: root)
        value.onProcessExit = { [weak self] in
            self?.setProtocolReady(false)
            self?.onEvent?("chat.failed")
        }
        value.onReplyDelta = { [weak self] turnID, itemID, text, phase in
            self?.onStreamEvent?(ChatStreamEvent(kind: "delta", turnID: turnID, itemID: itemID, text: text, phase: phase))
        }
        value.onItemCompleted = { [weak self] turnID, itemID, text, phase in
            self?.onStreamEvent?(ChatStreamEvent(kind: "item_completed", turnID: turnID, itemID: itemID, text: text, phase: phase))
        }
        value.onTurnStatus = { [weak self] turnID, status, text in
            guard let self else { return }
            if status == "completed" || status == "interrupted" || status == "failed" {
                self.lastTerminalTurnID = turnID
            }
            self.onStreamEvent?(ChatStreamEvent(kind: "status", turnID: turnID, text: text, status: status))
        }
        value.onToolCall = { [weak self] params in
            self?.registerToolCall(params) ?? ["success": false, "contentItems": [["type": "inputText", "text": "草案存储不可用。"]]]
        }
        session = value
    }

    private func registerToolCall(_ params: [String: Any]) -> [String: Any] {
        let namespace = params["namespace"] as? String
        let tool = params["tool"] as? String
        let args: [String: Any]
        if let object = params["arguments"] as? [String: Any] { args = object }
        else if let string = params["arguments"] as? String,
                let data = string.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { args = object }
        else { args = [:] }
        guard let tool, StudyRocketDynamicToolContract.accepts(namespace: namespace, tool: tool) else {
            return ["success": false, "contentItems": [["type": "inputText", "text": "草案工具必须使用 studyrocket 命名空间。"]]]
        }
        let turnID = (params["turnId"] as? String) ?? "unknown-turn"
        return proposalStore.register(arguments: args, tool: tool, turnID: turnID)
    }

    private func setProtocolReady(_ value: Bool) {
        readinessLock.lock(); _protocolReady = value; readinessLock.unlock()
    }

    private func releaseRequestID(_ requestID: String) {
        requestLock.lock(); acceptedRequestIDs.remove(requestID); requestLock.unlock()
    }
}

private final class HostChatCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ChatHistoryResponse(revision: "0", messages: [])

    var value: ChatHistoryResponse {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ value: ChatHistoryResponse) {
        lock.lock(); stored = value; lock.unlock()
    }
}

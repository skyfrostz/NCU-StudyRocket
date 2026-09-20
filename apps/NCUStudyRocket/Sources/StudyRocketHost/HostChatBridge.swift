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
/// startup deadline and its async Codex self-check.  It deliberately uses a
/// utility dispatch queue for the deadline: a stalled app-server must not
/// depend on the main run loop or cooperative Swift task executor.
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
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        switch result {
        case .success: continuation.resume()
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

private enum HostCodexSessionExit {
    case idle
    case retired
    case unexpected
}

@MainActor
private final class HostCodexSession {
    private let executable = "/Applications/ChatGPT.app/Contents/Resources/codex"
    private let root: URL
    private let descriptorStore: StudyRocketTaskDescriptorStore
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
    private var terminalTurns: [ChatTurnTerminalDTO] = []
    private var idleShutdownTask: Task<Void, Never>?
    private var requestedExit: HostCodexSessionExit?
    var onToolCall: (([String: Any]) -> [String: Any])?
    var onProcessExit: ((HostCodexSessionExit) -> Void)?
    var onReplyDelta: ((String, String, String, String?) -> Void)?
    var onItemCompleted: ((String, String, String, String?) -> Void)?
    var onTurnStatus: ((String, String, String?, String?, Date?) -> Void)?

    init(
        root: URL,
        descriptorStore: StudyRocketTaskDescriptorStore = StudyRocketTaskDescriptorStore(),
        threadID: String = StudyRocketThreadProtocol.legacyHostThreadID
    ) {
        self.root = root.standardizedFileURL
        self.descriptorStore = descriptorStore
        self.threadID = threadID
    }

    var isRunning: Bool { process?.isRunning == true }
    var currentThreadID: String { threadID }

    private func processDidTerminate() {
        guard process != nil || input != nil || output != nil else { return }
        let exit = requestedExit ?? .unexpected
        requestedExit = nil
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
        if let interruptedTurnID { onTurnStatus?(interruptedTurnID, "failed", error.localizedDescription, nil, .now) }
        onProcessExit?(exit)
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
        process.environment = StudyRocketCodexErrorPresentation.childProcessEnvironment()
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
        let config = try await request(method: "config/read", params: ["cwd": root.path])
        guard let selection = StudyRocketModelSelection.configReadResult(config) else {
            throw HostChatError.protocolError("Codex 未返回当前模型配置，请在 Mac 重新登录后重启 Host。")
        }
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
            let resumed = try await request(method: "thread/resume", params: [
                "threadId": threadID,
                "includeTurns": true,
                "cwd": root.path,
                "sandbox": "read-only",
                "approvalPolicy": "never",
                "runtimeWorkspaceRoots": [root.path],
                "developerInstructions": Self.developerInstructions(),
                "model": selection.model,
                "modelProvider": selection.modelProvider
            ])
            if StudyRocketModelSelection.threadResult(resumed) != selection {
                let resumedHistory = parseHistory((resumed["thread"] as? [String: Any]) ?? resumed)
                migratedHistory = Array((migratedHistory + resumedHistory).suffix(40))
                threadID = try await startFixedThread(selection: selection, legacyHistory: migratedHistory)
            }
        } else {
            threadID = try await startFixedThread(selection: selection, legacyHistory: migratedHistory)
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
        terminalTurns = parseTerminalTurns(result)
        return ChatHistoryResponse(revision: String(history.count), messages: history, terminalTurns: terminalTurns)
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
        onTurnStatus?(turnID, "inProgress", nil, nil, nil)
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

    func shutdown(exit: HostCodexSessionExit = .retired) {
        requestedExit = exit
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
        guard process?.isRunning == true else {
            processDidTerminate()
            return
        }
        process?.terminate()
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
            self.shutdown(exit: .idle)
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
                continuation.resume(throwing: HostChatError.protocolError(StudyRocketCodexErrorPresentation.message(for: message)))
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
            let error = ((turn["error"] as? [String: Any])?["message"] as? String)
                .map { StudyRocketCodexErrorPresentation.message(for: $0) }
            let issueCode = StudyRocketCodexErrorPresentation.isAuthenticationFailure(error) ? "provider_auth_failed" : nil
            onTurnStatus?(completedTurnID, status, error, issueCode, date(from: turn["completedAt"]) ?? .now)
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
            let message = StudyRocketCodexErrorPresentation.message(
                for: (params["error"] as? [String: Any])?["message"] as? String,
                fallback: "Codex 返回错误。"
            )
            let issueCode = StudyRocketCodexErrorPresentation.isAuthenticationFailure((params["error"] as? [String: Any])?["message"] as? String) ? "provider_auth_failed" : nil
            onTurnStatus?(activeTurnID, "failed", message, issueCode, .now)
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

    private func startFixedThread(selection: StudyRocketModelSelection, legacyHistory: [ChatMessageDTO]) async throws -> String {
        let response = try await request(method: "thread/start", params: [
            "cwd": root.path,
            "sandbox": "read-only",
            "approvalPolicy": "never",
            "runtimeWorkspaceRoots": [root.path],
            "threadSource": "studyrocket",
            "developerInstructions": Self.developerInstructions(legacyHistory: legacyHistory),
            "dynamicTools": StudyRocketDynamicToolContract.declaration,
            "model": selection.model,
            "modelProvider": selection.modelProvider
        ])
        guard let newID = (try resultObject(response)["thread"] as? [String: Any])?["id"] as? String else {
            throw HostChatError.protocolError("Codex 没有返回学业任务 ID。")
        }
        // Descriptor persistence is atomic; only switch the live task after it
        // succeeds so a failed write cannot strand the fixed task reference.
        try descriptorStore.save(StudyRocketTaskDescriptor(threadID: newID), for: root)
        _ = try? await request(method: "thread/name/set", params: ["threadId": newID, "name": "StudyRocket 学业助理"])
        return newID
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

    private func parseTerminalTurns(_ thread: [String: Any]) -> [ChatTurnTerminalDTO] {
        guard let turns = thread["turns"] as? [[String: Any]] else { return [] }
        return turns.suffix(40).compactMap { turn in
            guard let turnID = turn["id"] as? String,
                  let status = turn["status"] as? String,
                  ["completed", "interrupted", "failed"].contains(status) else { return nil }
            let raw = (turn["error"] as? [String: Any])?["message"] as? String
            let issueCode = StudyRocketCodexErrorPresentation.isAuthenticationFailure(raw) ? "provider_auth_failed" : nil
            let message = raw.map { StudyRocketCodexErrorPresentation.message(for: $0) }
            return ChatTurnTerminalDTO(turnID: turnID, status: status, issueCode: issueCode, message: message, completedAt: date(from: turn["completedAt"]))
        }
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
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [weak self] in
                Task { @MainActor [weak self] in
                    // A stalled app-server must never leave the Host UI in its
                    // startup state indefinitely.  Individual RPCs get a short,
                    // explicit deadline; the bridge-level self check below also
                    // owns a total deadline for the whole startup sequence.
                    guard let self, let timedOut = self.pending.removeValue(forKey: id) else { return }
                    timedOut.resume(throwing: HostChatError.unavailable("Codex 请求超时（\(method)），请重新启动连接。"))
                }
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
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let target = handle ?? input else {
            NSLog("StudyRocket Host refused an invalid Codex JSON payload")
            return
        }
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
    你是 StudyRocket 学业助理：既是完成课程、计划、复盘、科研、竞赛和保研工作的协作伙伴与导师，也是在学习、成长、生活适应或个人困扰中可以倾诉的可信赖同行者。根据用户当下目的切换语气，不把每次交流都变成效率优化或计划任务。先读 AGENTS.md、PROFILE.md 和相关学业 Markdown；未知信息标记【待核实】，不编造 GPA、排名、名额、日期或推免比例。手机请求不得处理应用开发、源码维护、Git 操作，也不得读取或引用 apps/、脚本、PDF、PDF提取文本/ 或其他开发资料。你运行在只读任务中，绝不直接写文件；需要更新时只能调用 studyrocket.propose_changes 或 studyrocket.propose_skill_update，由应用确认后写入。编辑工作台/下周计划.md 时，同一时段的多个事项用 <br> 分隔且不要在时段单元格内写 Markdown 复选框；带明确开始时间的事项必须归入上午（12:00 前）、中午（12:00-17:59）或晚上（18:00 起），只有无法判断时段的事项才能放入待分配。沟通分情境处理：课程答疑、工作执行和保研咨询时保持直接、清晰、证据扎实和可执行；用户谈压力、挫败、疲惫、犹豫、关系、生活困扰，或只是想聊聊时，先用自然语言准确回应其处境和难处，不预设、不评判、不急于正能量化，也不要把承接限制为一两句或立刻变成待办、降级方案和学习计划。允许用户选择继续倾诉、一起梳理或转为行动；每次最多提出一个温和的开放问题，给建议前先确认用户是否希望听建议。混合情境先陪伴，再共同确认是否需要行动方案。完成进展先指出已完成事实及其意义。禁止空泛鼓励、模板化正能量、过度共情、心理诊断、淡化痛苦、依赖性表达或结果保证；不声称能取代现实中的朋友、家人、咨询师或医疗服务。若出现自伤、自杀、伤害他人、无法保证安全等即时风险，优先平静确认当下安全，并明确鼓励立即联系身边可信赖的人、当地紧急服务或急诊支持；不要用成绩、计划或一般建议转移风险。情绪只用于当前回应，不记录情绪原话。
    \(continuity)
    """
    }

}

final class HostChatBridge: @unchecked Sendable {
    private let root: URL
    private let descriptorStore: StudyRocketTaskDescriptorStore
    private let disablesCodex: Bool
    private let cache = HostChatCache()
    private let readinessLock = NSLock()
    private let requestLock = NSLock()
    private let proposalStore: HostProposalStore
    private var session: HostCodexSession?
    private var acceptedRequestIDs = Set<String>()
    private var lastTerminalTurnID: String?
    private var _activeThreadID: String?
    private var _chatState: StudyRocketChatState = .starting
    private var _chatIssueCode: String?
    var onEvent: ((String) -> Void)?
    var onStreamEvent: ((ChatStreamEvent) -> Void)?

    var chatState: StudyRocketChatState {
        readinessLock.lock(); defer { readinessLock.unlock() }
        return _chatState
    }
    var chatIssueCode: String? {
        readinessLock.lock(); defer { readinessLock.unlock() }
        return _chatIssueCode
    }
    var canGenerateChat: Bool {
        !disablesCodex && chatState.canGenerate
    }
    var currentThreadID: String? {
        readinessLock.lock(); defer { readinessLock.unlock() }
        return _activeThreadID
    }

    init(
        root: URL,
        descriptorStore: StudyRocketTaskDescriptorStore = StudyRocketTaskDescriptorStore(),
        proposalBackupRoot: URL? = nil,
        disablesCodex: Bool = false
    ) {
        self.root = root.standardizedFileURL
        self.descriptorStore = descriptorStore
        self.disablesCodex = disablesCodex
        proposalStore = HostProposalStore(root: root.standardizedFileURL, backupRoot: proposalBackupRoot)
        if disablesCodex {
            setChatState(.unavailable, issueCode: "self_check_no_codex")
        }
    }

    func history() -> ChatHistoryResponse {
        cache.value
    }

    /// Resume the fixed task before the Host exposes chat and proposal features.
    /// This makes a malformed dynamic-tool declaration fail at Host startup rather
    /// than surfacing later as a `namespace: null` tool error on the phone.
    func selfCheck() async throws {
        guard !disablesCodex else {
            throw HostChatError.unavailable("隔离自检已禁用 Codex；计划和同步接口仍可验证。")
        }
        setChatState(.starting)
        guard StudyRocketDynamicToolContract.declarationIsValid else {
            throw HostChatError.protocolError("StudyRocket 草案工具声明校验失败。")
        }
        // `connectHistory` crosses the app-server's asynchronous stdio
        // boundary.  A process can stay alive while never returning a
        // response (for example after a local Codex upgrade), so a per-RPC
        // timeout alone is not enough to guarantee that startup finishes.
        // Use a utility queue rather than the main run loop or a sibling Swift
        // task; it continues to fire even if the stdio bridge is suspended.
        let completion = HostStartupCompletion()
        let timeout = DispatchWorkItem {
            NSLog("StudyRocket Host Codex self-check reached its 25-second deadline")
            completion.finish(.failure(HostChatError.unavailable("Codex 自检超时（25 秒），首页仍可用；学业对话尚未就绪。")))
        }
        let timeoutQueue = DispatchQueue(label: "com.skyfrost.ncustudyrocket.self-check-timeout", qos: .utility)
        do {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                timeoutQueue.asyncAfter(deadline: .now() + 25, execute: timeout)
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
        } catch {
            timeout.cancel()
            NSLog("StudyRocket Host Codex self-check failed: %@", error.localizedDescription)
            setChatState(.unavailable)
            await retireSession()
            throw error
        }
        timeout.cancel()
        setChatState(.protocolReadyAuthUnknown)
        onEvent?("chat.protocolReady")
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
                setChatState(.ready)
                succeeded = true
            } catch {
                let message = StudyRocketCodexErrorPresentation.message(for: error.localizedDescription)
                let isAuthFailure = StudyRocketCodexErrorPresentation.isAuthenticationFailure(error.localizedDescription)
                setChatState(isAuthFailure ? .authFailed : .unavailable, issueCode: isAuthFailure ? "provider_auth_failed" : nil)
                if session?.isRunning == true, let value = try? await session?.loadHistory() {
                    cache.set(value)
                }
                if lastTerminalTurnID == nil {
                    let terminal = ChatTurnTerminalDTO(turnID: "host-\(requestID)", status: "failed", issueCode: isAuthFailure ? "provider_auth_failed" : nil, message: message, completedAt: .now)
                    cache.record(terminal)
                    onStreamEvent?(ChatStreamEvent(kind: "status", turnID: terminal.turnID, text: message, status: "failed", issueCode: terminal.issueCode, completedAt: terminal.completedAt))
                }
                releaseRequestID(requestID)
                NSLog("StudyRocket Host chat error: %@", message)
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
        Task { await retireSession() }
    }

    /// A failed self-check must release only the Codex child.  The HTTP server,
    /// pairing records, local session and plan APIs stay alive so a later retry
    /// can recover the chat path without making the phone reconnect.
    private func retireSession() async {
        setChatState(.unavailable)
        setActiveThreadID(nil)
        await MainActor.run {
            // HostCodexSession is main-actor isolated.  Retire it on the same
            // actor as ensureSession so the next self-check observes nil and
            // starts a fresh app-server instead of racing the failed session.
            let retiringSession = session
            session = nil
            retiringSession?.shutdown()
        }
    }

    func connectHistory() async throws -> ChatHistoryResponse {
        guard !disablesCodex else {
            throw HostChatError.unavailable("隔离自检未启动 Codex 对话。")
        }
        return try await withCheckedThrowingContinuation { continuation in
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
                    if chatState == .starting { setChatState(.protocolReadyAuthUnknown) }
                    continuation.resume(returning: value)
                } catch {
                    setChatState(.unavailable)
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
        guard !disablesCodex else { return }
        guard session == nil else { return }
        let value = HostCodexSession(root: root, descriptorStore: descriptorStore)
        value.onProcessExit = { [weak self] exit in
            guard let self else { return }
            switch exit {
            case .idle:
                // The next real message reconnects the child process.  Keep
                // this gate open so an intentional resource release cannot
                // strand an otherwise healthy Host in an unavailable state.
                self.setChatState(.protocolReadyAuthUnknown)
                self.onEvent?("chat.protocolReady")
            case .retired:
                break
            case .unexpected:
                self.setChatState(.unavailable)
                self.onEvent?("chat.failed")
            }
        }
        value.onReplyDelta = { [weak self] turnID, itemID, text, phase in
            self?.onStreamEvent?(ChatStreamEvent(kind: "delta", turnID: turnID, itemID: itemID, text: text, phase: phase))
        }
        value.onItemCompleted = { [weak self] turnID, itemID, text, phase in
            self?.onStreamEvent?(ChatStreamEvent(kind: "item_completed", turnID: turnID, itemID: itemID, text: text, phase: phase))
        }
        value.onTurnStatus = { [weak self] turnID, status, text, issueCode, completedAt in
            guard let self else { return }
            if status == "completed" || status == "interrupted" || status == "failed" {
                self.lastTerminalTurnID = turnID
                self.cache.record(ChatTurnTerminalDTO(turnID: turnID, status: status, issueCode: issueCode, message: text, completedAt: completedAt))
            }
            self.onStreamEvent?(ChatStreamEvent(kind: "status", turnID: turnID, text: text, status: status, issueCode: issueCode, completedAt: completedAt))
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
        guard let tool,
              let normalized = StudyRocketDynamicToolContract.normalizedCall(namespace: namespace, tool: tool) else {
            return ["success": false, "contentItems": [["type": "inputText", "text": "草案工具必须使用 studyrocket 命名空间。"]]]
        }
        guard let turnID = params["turnId"] as? String, !turnID.isEmpty else {
            return ["success": false, "contentItems": [["type": "inputText", "text": "草案缺少回合 ID。"]]]
        }
        return proposalStore.register(arguments: args, tool: normalized.tool, turnID: turnID)
    }

    private func setChatState(_ state: StudyRocketChatState, issueCode: String? = nil) {
        readinessLock.lock()
        _chatState = state
        _chatIssueCode = issueCode
        readinessLock.unlock()
    }

    private func releaseRequestID(_ requestID: String) {
        requestLock.lock(); acceptedRequestIDs.remove(requestID); requestLock.unlock()
    }
}

private final class HostChatCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ChatHistoryResponse(revision: "0", messages: [], terminalTurns: [])

    var value: ChatHistoryResponse {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ value: ChatHistoryResponse) {
        lock.lock(); stored = value; lock.unlock()
    }

    func record(_ terminal: ChatTurnTerminalDTO) {
        lock.lock(); defer { lock.unlock() }
        var terminals = stored.terminalTurns ?? []
        terminals.removeAll { $0.turnID == terminal.turnID }
        terminals.append(terminal)
        stored = ChatHistoryResponse(revision: stored.revision, messages: stored.messages, terminalTurns: Array(terminals.suffix(40)))
    }
}

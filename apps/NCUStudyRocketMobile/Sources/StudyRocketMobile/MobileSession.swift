import Foundation
import StudyRocketShared
#if os(iOS)
import LocalAuthentication
#endif

public enum MobileConnectionState: Equatable, Sendable {
    case unconfigured
    case connecting
    case online
    case offline(lastUpdated: Date?)
    case failed(String)

    public var title: String {
        switch self {
        case .unconfigured: return "尚未连接 Mac"
        case .connecting: return "正在连接 Mac"
        case .online: return "已连接 Mac"
        case .offline(let date):
            if let date { return "离线 · 缓存于 \(Self.dateFormatter.string(from: date))" }
            return "离线"
        case .failed(let message): return message
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}

private struct PendingDeliveryToggle: Codable, Equatable {
    let text: String
    let isCompleted: Bool
}

private struct MobilePendingDrafts: Codable {
    var week: WeeklyPlanSnapshot?
    var daily: DailySnapshot?
    var deliveries: [PendingDeliveryToggle]
}

public enum MobileDocumentKey {
    public static let all: Set<String> = ["course", "research", "recommendation", "life", "library"]
}

@MainActor
public final class MobileSession: ObservableObject {
    @Published public private(set) var state: MobileConnectionState = .unconfigured
    @Published public private(set) var health: HealthResponse?
    @Published public private(set) var snapshot: SnapshotResponse?
    @Published public private(set) var chatMessages: [ChatMessageDTO] = []
    @Published public private(set) var proposals: [ProposalDTO] = []
    @Published public private(set) var isChatBusy = false
    @Published public private(set) var chatRevision = 0
    @Published public private(set) var pendingWeekDraft: WeeklyPlanSnapshot?
    @Published public private(set) var pendingDailyDraft: DailySnapshot?
    @Published public private(set) var pendingDeliveryCount = 0
    /// Documents are fetched only after the user opens one of the five
    /// allowlisted summaries.  Keeping this separate from the snapshot keeps
    /// the home payload small and makes offline behaviour explicit.
    @Published public private(set) var documentDetails: [String: DocumentDetail] = [:]
    @Published public var inputDraft = "" {
        didSet { UserDefaults.standard.set(inputDraft, forKey: "studyrocket.inputDraft") }
    }

    private let cacheURL: URL
    private let draftsURL: URL
    private let documentsURL: URL
    private let endpointKey = "studyrocket.hostEndpoint"
    private var client: StudyRocketRemoteClient?
    private var eventsTask: Task<Void, Never>?
    private var reconnectFailures = 0
    private var streamGeneration = 0
    private var completedTurnIDs = Set<String>()
    private var completedItemKeys = Set<String>()

    public init(cacheDirectory: URL? = nil) {
        let base = cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("NCU StudyRocket Mobile", isDirectory: true)
        cacheURL = base.appendingPathComponent("snapshot.json")
        draftsURL = base.appendingPathComponent("pending-drafts.json")
        documentsURL = base.appendingPathComponent("documents", isDirectory: true)
        inputDraft = UserDefaults.standard.string(forKey: "studyrocket.inputDraft") ?? ""
        loadCache()
        loadDocumentCache()
        loadDrafts()
        if let endpoint = UserDefaults.standard.string(forKey: endpointKey), let url = URL(string: endpoint), url.scheme?.lowercased() == "https" {
            client = StudyRocketRemoteClient(endpoint: url)
            if snapshot != nil { state = .offline(lastUpdated: snapshot?.fetchedAt) }
        }
    }

    public var savedEndpoint: String? { UserDefaults.standard.string(forKey: endpointKey) }

    /// Fetch a complete read-only document, falling back to the last version
    /// the user opened when the Host is unavailable.
    public func document(for documentKey: String) async -> DocumentDetail? {
        guard MobileDocumentKey.all.contains(documentKey) else { return nil }
        let cached = documentDetails[documentKey]
        guard let client else { return cached }
        do {
            let value = try await client.document(documentKey: documentKey)
            documentDetails[documentKey] = value
            saveDocumentCache(value)
            return value
        } catch {
            return cached
        }
    }

    public func configure(endpoint: URL) {
        guard endpoint.scheme?.lowercased() == "https" else {
            state = .failed("手机端只允许 HTTPS Host 地址。")
            return
        }
        client = StudyRocketRemoteClient(endpoint: endpoint)
        state = .connecting
        Task { await refresh() }
    }

    public func pair(endpoint: URL, code: String, deviceName: String) async throws {
        guard endpoint.scheme?.lowercased() == "https" else { throw MobileEndpointError.insecure }
        let remote = StudyRocketRemoteClient(endpoint: endpoint)
        do {
            _ = try await remote.pair(code: code, deviceName: deviceName)
        } catch {
            throw MobileEndpointError.contextualized(error)
        }
        client = remote
        UserDefaults.standard.set(endpoint.absoluteString, forKey: endpointKey)
        state = .connecting
        await refresh()
    }

    public func refresh() async {
        guard let client else {
            if snapshot == nil { state = .unconfigured }
            return
        }
        do {
            let health = try await client.health()
            guard health.repositoryBound, health.codexReady, health.dynamicToolsReady != false else {
                throw MobileHostStateError.notReady
            }
            self.health = health
            let value = try await client.snapshot()
            snapshot = value
            state = .online
            saveCache(value)
            startEventStream()
        } catch {
            state = .offline(lastUpdated: snapshot?.fetchedAt)
        }
    }

    public func sendDraft() async {
        let text = inputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client else { return }
        guard !isChatBusy else { return }
        isChatBusy = true
        let pendingID = "mobile-pending-\(UUID().uuidString)"
        chatMessages.append(ChatMessageDTO(id: pendingID, role: "user", text: text, date: .now, status: "inProgress"))
        chatRevision &+= 1
        do {
            try await client.sendChat(text: text)
            inputDraft = ""
            // SSE is the primary path. A single delayed history refresh is only
            // a recovery path if the network dropped while the request succeeded.
            try? await Task.sleep(for: .seconds(2))
            if isChatBusy { await refreshChat() }
        } catch {
            chatMessages.removeAll { $0.id == pendingID }
            chatRevision &+= 1
            state = .failed(error.localizedDescription)
            isChatBusy = false
        }
    }

    public func interruptChat() async {
        guard let client, isChatBusy else { return }
        do {
            try await client.interruptChat()
        } catch {
            state = .failed(error.localizedDescription)
        }
        isChatBusy = false
    }

    public func refreshChat() async {
        guard let client else { return }
        let generation = streamGeneration
        do {
            let history = try await client.chatHistory().messages
            guard generation == streamGeneration else { return }
            mergeHistory(history)
        } catch {
            // 对话历史加载失败不清空已有内容，页面仍可保留当前草稿。
        }
    }

    public func startEventStream() {
        guard eventsTask == nil, let client else { return }
        reconnectFailures = 0
        streamGeneration &+= 1
        let generation = streamGeneration
        eventsTask = Task { [weak self] in
            var retryIndex = 0
            while !Task.isCancelled {
                guard let self else { return }
                let stream = await client.events()
                var receivedEvent = false
                var streamEnded = false
                do {
                    for try await value in stream {
                        guard !Task.isCancelled else { break }
                        if !receivedEvent {
                            receivedEvent = true
                            self.reconnectFailures = 0
                            retryIndex = 0
                            self.state = .online
                            Task { [weak self] in
                                guard let self, self.streamGeneration == generation else { return }
                                await self.refreshChat()
                            }
                        }
                        self.consumeHostEvent(value)
                    }
                    streamEnded = true
                } catch {
                    if !Task.isCancelled {
                        self.reconnectFailures += 1
                        if self.reconnectFailures >= 3 {
                            self.state = .failed("实时连接连续失败 3 次，历史记录仍保留。")
                        } else {
                            self.state = .connecting
                        }
                    }
                }
                if streamEnded, !Task.isCancelled {
                    self.reconnectFailures += 1
                    if self.reconnectFailures >= 3 {
                        self.state = .failed("实时连接连续失败 3 次，历史记录仍保留。")
                    } else {
                        self.state = .connecting
                    }
                }
                guard !Task.isCancelled else { break }
                let delays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(5)]
                let delay = delays[min(retryIndex, delays.count - 1)]
                retryIndex += 1
                try? await Task.sleep(for: delay)
            }
            self?.eventsTask = nil
        }
    }

    public func stopEventStream() {
        streamGeneration &+= 1
        eventsTask?.cancel()
        eventsTask = nil
    }

    public func refreshProposals() async {
        guard let client else { return }
        if let value = try? await client.proposals() { proposals = value.proposals }
    }

    private func consumeHostEvent(_ event: HostEventEnvelope) {
        if event.kind == "heartbeat" { return }
        if let snapshot = event.snapshot {
            self.snapshot = snapshot
            state = .online
            saveCache(snapshot)
        }

        switch event.kind {
        case "chat.started": isChatBusy = true
        case "chat.completed", "chat.interrupted", "chat.failed":
            isChatBusy = false
        default: break
        }

        if let chat = event.chat { applyChatEvent(chat) }
    }

    private func applyChatEvent(_ event: ChatStreamEvent) {
        switch event.kind {
        case "delta":
            guard let turnID = event.turnID, let itemID = event.itemID, let text = event.text else { return }
            let key = streamKey(turnID: turnID, itemID: itemID)
            guard !completedItemKeys.contains(key), !completedTurnIDs.contains(turnID) else { return }
            let id = "stream-\(turnID)-\(itemID)"
            if let index = chatMessages.firstIndex(where: { $0.id == id }) {
                let current = chatMessages[index]
                chatMessages[index] = ChatMessageDTO(id: id, role: "assistant", text: current.text + text, date: current.date, turnID: turnID, phase: event.phase ?? current.phase, status: "inProgress")
            } else {
                chatMessages.append(ChatMessageDTO(id: id, role: "assistant", text: text, date: .now, turnID: turnID, phase: event.phase, status: "inProgress"))
            }
            isChatBusy = true
            chatRevision &+= 1
        case "item_completed":
            guard let turnID = event.turnID, let itemID = event.itemID, let text = event.text else { return }
            let key = streamKey(turnID: turnID, itemID: itemID)
            guard completedItemKeys.insert(key).inserted else { return }
            let id = "stream-\(turnID)-\(itemID)"
            if let index = chatMessages.firstIndex(where: { $0.id == id }) {
                let current = chatMessages[index]
                chatMessages[index] = ChatMessageDTO(id: id, role: "assistant", text: text, date: current.date, turnID: turnID, phase: event.phase ?? current.phase, status: completedTurnIDs.contains(turnID) ? "completed" : "inProgress")
            } else {
                chatMessages.append(ChatMessageDTO(id: id, role: "assistant", text: text, date: .now, turnID: turnID, phase: event.phase, status: completedTurnIDs.contains(turnID) ? "completed" : "inProgress"))
            }
            chatRevision &+= 1
        case "status":
            switch event.status {
            case "completed":
                if let turnID = event.turnID { completedTurnIDs.insert(turnID) }
                isChatBusy = false
                Task { [weak self] in
                    await self?.refreshChat()
                    await self?.refreshProposals()
                }
            case "interrupted", "failed":
                if let turnID = event.turnID { completedTurnIDs.insert(turnID) }
                isChatBusy = false
                Task { [weak self] in await self?.refreshChat() }
            default: break
            }
            chatRevision &+= 1
        default: break
        }
    }

    private func mergeHistory(_ history: [ChatMessageDTO]) {
        let streamMessages = chatMessages.filter { $0.id.hasPrefix("stream-") }
        let pendingMessages = chatMessages.filter { $0.id.hasPrefix("mobile-pending-") }
        var merged = history.map { message in
            let status = message.status ?? (message.turnID.map { completedTurnIDs.contains($0) } == true ? "completed" : nil)
            if let turnID = message.turnID {
                if status == "completed" || status == "interrupted" || status == "failed" { completedTurnIDs.insert(turnID) }
                completedItemKeys.insert(streamKey(turnID: turnID, itemID: message.id))
            }
            return ChatMessageDTO(id: message.id, role: message.role, text: message.text, date: message.date, turnID: message.turnID, phase: message.phase, status: status)
        }

        for message in streamMessages {
            guard let turnID = message.turnID, let historyMessage = history.first(where: { $0.turnID == turnID && $0.id == streamItemID(message.id, turnID: turnID) }) else {
                if let turnID = message.turnID, !completedTurnIDs.contains(turnID) { merged.append(message) }
                continue
            }
            if let index = merged.firstIndex(where: { $0.id == historyMessage.id }) {
                merged[index] = historyMessage
            }
        }
        for message in pendingMessages where !history.contains(where: { $0.role == "user" && $0.text == message.text }) {
            merged.append(message)
        }
        let sorted = merged.sorted { $0.date < $1.date }
        if chatMessages != sorted { chatMessages = sorted; chatRevision &+= 1 }
    }

    private func streamKey(turnID: String, itemID: String) -> String { "\(turnID)|\(itemID)" }

    private func streamItemID(_ streamID: String, turnID: String) -> String {
        let prefix = "stream-\(turnID)-"
        return streamID.hasPrefix(prefix) ? String(streamID.dropFirst(prefix.count)) : streamID
    }

    public func applyProposals(ids: [String]? = nil) async {
        guard let client, let current = snapshot, !proposals.isEmpty else { return }
        let selectedIDs = ids ?? proposals.map(\.id)
        guard !selectedIDs.isEmpty else { return }
        do {
            let challenge = try await client.proposalChallenge()
            let authorization = try await MobileProposalAuthorization.evaluate(challenge: challenge)
            let response = try await client.applyProposals(ids: selectedIDs, authorization: authorization, baseRevision: current.revision)
            proposals = response.remaining.proposals
            await refresh()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func saveWeek(_ plan: WeeklyPlanSnapshot) async {
        guard let client, let current = snapshot, state == .online else {
            pendingWeekDraft = plan
            saveDrafts()
            return
        }
        do {
            let value = try await client.applyWeek(plan: plan, baseRevision: current.revision)
            snapshot = value
            state = .online
            saveCache(value)
        } catch {
            pendingWeekDraft = plan
            saveDrafts()
            state = .failed(error.localizedDescription)
        }
    }

    public func toggleDelivery(_ delivery: DeliverySnapshot) async {
        guard let client, let current = snapshot, state == .online else {
            var drafts = loadPendingDrafts()
            drafts.deliveries.removeAll { $0.text == delivery.text }
            drafts.deliveries.append(PendingDeliveryToggle(text: delivery.text, isCompleted: !delivery.isCompleted))
            pendingDeliveryCount = drafts.deliveries.count
            saveDrafts(drafts)
            return
        }
        do {
            let value = try await client.toggleDelivery(text: delivery.text, isCompleted: !delivery.isCompleted, baseRevision: current.revision)
            snapshot = value
            state = .online
            saveCache(value)
        } catch {
            var drafts = loadPendingDrafts()
            drafts.deliveries.removeAll { $0.text == delivery.text }
            drafts.deliveries.append(PendingDeliveryToggle(text: delivery.text, isCompleted: !delivery.isCompleted))
            saveDrafts(drafts)
            state = .failed(error.localizedDescription)
        }
    }

    public func saveDaily(_ entry: DailySnapshot) async {
        guard let client, let current = snapshot, state == .online else {
            pendingDailyDraft = entry
            saveDrafts()
            return
        }
        do {
            let value = try await client.saveDaily(entry: entry, baseRevision: current.revision)
            snapshot = value
            state = .online
            saveCache(value)
        } catch {
            pendingDailyDraft = entry
            saveDrafts()
            state = .failed(error.localizedDescription)
        }
    }

    public var hasPendingDrafts: Bool {
        pendingWeekDraft != nil || pendingDailyDraft != nil || pendingDeliveryCount > 0
    }

    public func commitPendingDrafts() async {
        guard let client, let current = snapshot, state == .online else { return }
        do {
            if let week = pendingWeekDraft {
                let value = try await client.applyWeek(plan: week, baseRevision: current.revision)
                snapshot = value
                pendingWeekDraft = nil
                saveCache(value)
                saveDrafts()
            }
            if let daily = pendingDailyDraft, let latest = snapshot {
                let value = try await client.saveDaily(entry: daily, baseRevision: latest.revision)
                snapshot = value
                pendingDailyDraft = nil
                saveCache(value)
                saveDrafts()
            }
            var drafts = loadPendingDrafts()
            while let draft = drafts.deliveries.first {
                guard let latest = snapshot else { break }
                let delivery = latest.home.visibleDeliveries.first { $0.text == draft.text } ?? latest.week.deliveries.first { $0.text == draft.text }
                guard let delivery else {
                    drafts.deliveries.removeFirst()
                    pendingDeliveryCount = drafts.deliveries.count
                    saveDrafts(drafts)
                    continue
                }
                let value = try await client.toggleDelivery(text: delivery.text, isCompleted: draft.isCompleted, baseRevision: latest.revision)
                snapshot = value
                drafts.deliveries.removeAll { $0.text == draft.text }
                pendingDeliveryCount = drafts.deliveries.count
                saveDrafts(drafts)
            }
            saveDrafts()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func discardPendingDrafts() {
        pendingWeekDraft = nil
        pendingDailyDraft = nil
        pendingDeliveryCount = 0
        saveDrafts(MobilePendingDrafts(week: nil, daily: nil, deliveries: []))
    }

    public func clearLocalCache() {
        eventsTask?.cancel()
        eventsTask = nil
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: draftsURL)
        try? FileManager.default.removeItem(at: documentsURL)
        snapshot = nil
        chatMessages = []
        completedTurnIDs.removeAll()
        completedItemKeys.removeAll()
        proposals = []
        documentDetails = [:]
        health = nil
        pendingWeekDraft = nil
        pendingDailyDraft = nil
        pendingDeliveryCount = 0
        inputDraft = ""
        state = .unconfigured
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL), let value = try? JSONDecoder().decode(SnapshotResponse.self, from: data) else { return }
        snapshot = value
        state = .offline(lastUpdated: value.fetchedAt)
    }

    private func loadDocumentCache() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let detail = try? decoder.decode(DocumentDetail.self, from: data), MobileDocumentKey.all.contains(detail.documentKey) else { continue }
            documentDetails[detail.documentKey] = detail
        }
    }

    private func saveDocumentCache(_ value: DocumentDetail) {
        guard MobileDocumentKey.all.contains(value.documentKey) else { return }
        do {
            try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
            let url = documentsURL.appendingPathComponent("\(value.documentKey).json")
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            // A cache failure must never make a successful read fail.
        }
    }

    private func loadPendingDrafts() -> MobilePendingDrafts {
        guard let data = try? Data(contentsOf: draftsURL), let value = try? JSONDecoder().decode(MobilePendingDrafts.self, from: data) else {
            return MobilePendingDrafts(week: pendingWeekDraft, daily: pendingDailyDraft, deliveries: [])
        }
        return value
    }

    private func loadDrafts() {
        let value = loadPendingDrafts()
        pendingWeekDraft = value.week
        pendingDailyDraft = value.daily
        pendingDeliveryCount = value.deliveries.count
    }

    private func saveDrafts(_ value: MobilePendingDrafts? = nil) {
        let drafts = value ?? MobilePendingDrafts(week: pendingWeekDraft, daily: pendingDailyDraft, deliveries: loadPendingDrafts().deliveries)
        pendingWeekDraft = drafts.week
        pendingDailyDraft = drafts.daily
        pendingDeliveryCount = drafts.deliveries.count
        do {
            try FileManager.default.createDirectory(at: draftsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(drafts).write(to: draftsURL, options: .atomic)
        } catch {
            // 本地草稿保存失败不影响在线数据；页面仍保留当前内存草稿。
        }
    }

    private func saveCache(_ value: SnapshotResponse) {
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: cacheURL, options: .atomic)
        } catch {
            // 缓存失败不影响在线读写；下次启动仍会尝试重新拉取。
        }
    }
}

public struct StudyRocketRemoteError: LocalizedError {
    public let body: APIErrorBody
    public var errorDescription: String? { body.message }
}

public enum MobileEndpointError: LocalizedError {
    case insecure
    case systemTailscaleRequired

    public var errorDescription: String? {
        switch self {
        case .insecure:
            return "手机端只允许 HTTPS Host 地址，不会降级到明文 HTTP。"
        case .systemTailscaleRequired:
            return "安全连接失败：此地址需要 iOS 系统级 Tailscale VPN。NovaScale 的内置 tailnet 仅供 NovaScale 自身使用，不能为 NCU StudyRocket 提供网络。请安装并连接官方 Tailscale App 后重试。"
        }
    }

    static func contextualized(_ error: Error) -> Error {
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return MobileEndpointError.systemTailscaleRequired
        default:
            return error
        }
    }
}

private enum MobileHostStateError: LocalizedError {
    case notReady
    var errorDescription: String? { "Mac Host 正在完成协议自检，请稍后重试。" }
}

public actor StudyRocketRemoteClient {
    public let endpoint: URL
    private let session: URLSession
    private let identity = MobileDeviceIdentity()
    private var deviceID: String?

    public init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
        deviceID = UserDefaults.standard.string(forKey: "studyrocket.deviceID")
    }

    public func pair(code: String, deviceName: String) async throws -> PairResponse {
        let publicKey = try identity.publicKeyBase64()
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PairRequest(code: code, deviceName: deviceName, publicKey: publicKey))
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let result = try JSONDecoder().decode(PairResponse.self, from: data)
        deviceID = result.deviceID
        UserDefaults.standard.set(result.deviceID, forKey: "studyrocket.deviceID")
        return result
    }

    public func snapshot() async throws -> SnapshotResponse {
        try await get("/v1/snapshot", as: SnapshotResponse.self)
    }

    public func health() async throws -> HealthResponse {
        try await get("/v1/health", as: HealthResponse.self)
    }

    public func week() async throws -> WeeklyPlanSnapshot {
        try await get("/v1/week", as: WeeklyPlanSnapshot.self)
    }

    public func daily() async throws -> DailySnapshot {
        try await get("/v1/daily", as: DailySnapshot.self)
    }

    public func summaries() async throws -> [SummaryCard] {
        try await get("/v1/summaries", as: [SummaryCard].self)
    }

    public func document(documentKey: String) async throws -> DocumentDetail {
        guard MobileDocumentKey.all.contains(documentKey) else {
            throw StudyRocketRemoteError(body: APIErrorBody(code: "invalid_document", message: "资料键无效。"))
        }
        return try await get("/v1/documents/\(documentKey)", as: DocumentDetail.self)
    }

    public func sendChat(text: String) async throws {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/chat/send"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SendChatRequest(text: text))
        try authenticate(&request)
        let (_, response) = try await session.data(for: request)
        try validate(response, data: nil)
    }

    public func chatHistory() async throws -> ChatHistoryResponse {
        try await get("/v1/chat/history", as: ChatHistoryResponse.self)
    }

    public func events() -> AsyncThrowingStream<HostEventEnvelope, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: endpoint.appendingPathComponent("v1/events"))
                    request.httpMethod = "GET"
                    request.timeoutInterval = 90
                    try authenticate(&request)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw StudyRocketRemoteError(body: APIErrorBody(code: "events_unavailable", message: "Mac Host 事件连接失败。", retryable: true))
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let data = Data(line.dropFirst(6).utf8)
                        if let event = try? JSONDecoder().decode(HostEventEnvelope.self, from: data) {
                            continuation.yield(event)
                        } else if let snapshot = try? JSONDecoder().decode(SnapshotResponse.self, from: data) {
                            // Compatibility with a Host that predates typed SSE.
                            continuation.yield(HostEventEnvelope(kind: "snapshot", snapshot: snapshot))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func interruptChat() async throws {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/chat/interrupt"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(InterruptRequest(turnID: "active"))
        try authenticate(&request)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
    }

    public func proposals() async throws -> ProposalListResponse {
        try await get("/v1/proposals", as: ProposalListResponse.self)
    }

    public func proposalChallenge() async throws -> ProposalAuthorizationChallenge {
        try await get("/v1/proposals/challenge", as: ProposalAuthorizationChallenge.self)
    }

    public func applyProposals(ids: [String], authorization: String, baseRevision: String) async throws -> ProposalApplyResponse {
        try await post("/v1/proposals/apply", body: ProposalApplyRequest(proposalIDs: ids, authorization: authorization, metadata: WriteMetadata(baseRevision: baseRevision)), as: ProposalApplyResponse.self)
    }

    public func applyWeek(plan: WeeklyPlanSnapshot, baseRevision: String) async throws -> SnapshotResponse {
        try await post("/v1/week", body: PlanWriteRequest(plan: plan, metadata: WriteMetadata(baseRevision: baseRevision)), as: SnapshotResponse.self)
    }

    public func toggleDelivery(text: String, isCompleted: Bool, baseRevision: String) async throws -> SnapshotResponse {
        try await post("/v1/deliveries/toggle", body: DeliveryToggleRequest(text: text, isCompleted: isCompleted, metadata: WriteMetadata(baseRevision: baseRevision)), as: SnapshotResponse.self)
    }

    public func saveDaily(entry: DailySnapshot, baseRevision: String) async throws -> SnapshotResponse {
        try await post("/v1/daily", body: DailyWriteRequest(entry: entry, metadata: WriteMetadata(baseRevision: baseRevision)), as: SnapshotResponse.self)
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        var request = URLRequest(url: endpoint.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "GET"
        try authenticate(&request)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(type, from: data)
    }

    private func post<T: Decodable, Body: Encodable>(_ path: String, body: Body, as type: T.Type) async throws -> T {
        var request = URLRequest(url: endpoint.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        try authenticate(&request)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(type, from: data)
    }

    private func authenticate(_ request: inout URLRequest) throws {
        guard let deviceID else { return }
        let body = request.httpBody ?? Data()
        let timestamp = Int64(Date().timeIntervalSince1970)
        let nonce = UUID().uuidString
        let bodyHash = RequestSigning.bodyHash(body)
        #if os(iOS)
        let signature = RequestSigning.sign(privateKey: try identity.secureEnclaveKey(), method: request.httpMethod ?? "GET", path: request.url?.path ?? "/", timestamp: timestamp, nonce: nonce, bodyHash: bodyHash)
        #else
        let signature = RequestSigning.sign(privateKey: try identity.softwareKey(), method: request.httpMethod ?? "GET", path: request.url?.path ?? "/", timestamp: timestamp, nonce: nonce, bodyHash: bodyHash)
        #endif
        request.setValue(deviceID, forHTTPHeaderField: "X-StudyRocket-Device")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-StudyRocket-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-StudyRocket-Nonce")
        request.setValue(signature, forHTTPHeaderField: "X-StudyRocket-Signature")
    }

    private func validate(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let data, let body = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
                throw StudyRocketRemoteError(body: body)
            }
            throw StudyRocketRemoteError(body: APIErrorBody(code: "http_error", message: "Mac Host 暂时不可用。", retryable: true))
        }
    }
}

public enum MobileProposalAuthorization {
    public static func evaluate() async throws -> String {
        try await evaluate(challenge: nil)
    }

    public static func evaluate(challenge: ProposalAuthorizationChallenge?) async throws -> String {
        #if os(iOS)
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw error ?? NSError(domain: "StudyRocket", code: 1, userInfo: [NSLocalizedDescriptionKey: "此设备不可用 Face ID。"])
        }
        let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "确认将选定学业草案写入 Mac 仓库")
        guard success else { throw NSError(domain: "StudyRocket", code: 2, userInfo: [NSLocalizedDescriptionKey: "Face ID 未通过，草案未写入。"]) }
        if let challenge {
            let identity = MobileDeviceIdentity()
            let signature = RequestSigning.signAuthorization(privateKey: try identity.secureEnclaveKey(), challenge: challenge.challenge)
            return "\(challenge.challenge)|\(signature)"
        }
        #endif
        return UUID().uuidString
    }
}

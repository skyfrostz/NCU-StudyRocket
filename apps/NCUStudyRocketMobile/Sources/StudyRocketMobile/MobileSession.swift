import Foundation
import StudyRocketShared
import StudyRocketWidgetSupport
#if os(iOS)
import LocalAuthentication
import WidgetKit
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
        case .failed: return "连接失败"
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
    let idempotencyKey: String?

    init(text: String, isCompleted: Bool, idempotencyKey: String? = nil) {
        self.text = text
        self.isCompleted = isCompleted
        self.idempotencyKey = idempotencyKey
    }
}

private struct PendingPeriodToggle: Codable, Equatable {
    let dayID: String
    let periodID: String
    let taskID: String?
    let textHash: String?
    let isCompleted: Bool
    let idempotencyKey: String?

    init(
        dayID: String,
        periodID: String,
        taskID: String? = nil,
        textHash: String? = nil,
        isCompleted: Bool,
        idempotencyKey: String? = nil
    ) {
        self.dayID = dayID
        self.periodID = periodID
        self.taskID = taskID
        self.textHash = textHash
        self.isCompleted = isCompleted
        self.idempotencyKey = idempotencyKey
    }

    var key: String {
        if let taskID { return "\(dayID)|\(periodID)|\(taskID)" }
        return "\(dayID)|\(periodID)|legacy:\(textHash ?? "unknown")"
    }

    var periodKey: String { "\(dayID)|\(periodID)" }

    var isLegacy: Bool { taskID == nil }
}

private struct PendingChatDelta {
    let turnID: String
    let itemID: String
    var text: String
    var phase: String?
}

enum MobileChatProgress: Equatable, Sendable {
    case sending
    case thinking
    case responding
    case recovering

    var title: String {
        switch self {
        case .sending: "正在发送"
        case .thinking: "正在思考"
        case .responding: "正在生成回复"
        case .recovering: "仍在等待回复"
        }
    }

    var detail: String {
        switch self {
        case .sending: "正在将消息发送到 Mac Host。"
        case .thinking: "学业助理正在分析你的问题。"
        case .responding: "回复会逐步显示在这里。"
        case .recovering: "连接仍在恢复，正在继续获取回复。"
        }
    }
}

private struct ActiveMobileChatRequest {
    let pendingID: String
    let text: String
    var turnID: String?
}

private struct MobilePendingDrafts: Codable {
    var week: WeeklyPlanSnapshot?
    var daily: DailySnapshot?
    var deliveries: [PendingDeliveryToggle]
    var periods: [PendingPeriodToggle]

    init(week: WeeklyPlanSnapshot?, daily: DailySnapshot?, deliveries: [PendingDeliveryToggle], periods: [PendingPeriodToggle] = []) {
        self.week = week
        self.daily = daily
        self.deliveries = deliveries
        self.periods = periods
    }

    private enum CodingKeys: String, CodingKey { case week, daily, deliveries, periods }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        week = try values.decodeIfPresent(WeeklyPlanSnapshot.self, forKey: .week)
        daily = try values.decodeIfPresent(DailySnapshot.self, forKey: .daily)
        deliveries = try values.decodeIfPresent([PendingDeliveryToggle].self, forKey: .deliveries) ?? []
        periods = try values.decodeIfPresent([PendingPeriodToggle].self, forKey: .periods) ?? []
    }
}

public enum MobileDocumentKey {
    public static let all: Set<String> = ["course", "research", "recommendation", "life", "library", "timetable"]
}

struct MobileDeliveryMutation: Hashable, Sendable {
    let deliveryID: String
    let token: UUID
    let repositoryGeneration: UInt64
}

enum MobileDeliveryToggleResult: Equatable, Sendable {
    case confirmed(SnapshotResponse)
    case queuedOffline
    case failed(String)
    case staleGeneration
}

struct MobileLegacyPendingReviewItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case delivery
        case period
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let isCompleted: Bool
    let canSync: Bool
}

struct MobileLegacyPendingReview: Equatable, Sendable {
    let items: [MobileLegacyPendingReviewItem]

    var selectableIDs: Set<String> {
        Set(items.lazy.filter(\.canSync).map(\.id))
    }
}

@MainActor
public final class MobileSession: ObservableObject {
    @Published public private(set) var state: MobileConnectionState = .unconfigured
    @Published public private(set) var health: HealthResponse?
    @Published public private(set) var snapshot: SnapshotResponse?
    @Published public private(set) var chatMessages: [ChatMessageDTO] = []
    @Published public private(set) var proposals: [ProposalDTO] = []
    @Published public private(set) var isChatBusy = false
    @Published private(set) var chatProgress: MobileChatProgress?
    @Published public private(set) var chatRevision = 0
    @Published public private(set) var pendingWeekDraft: WeeklyPlanSnapshot?
    @Published public private(set) var pendingDailyDraft: DailySnapshot?
    @Published public private(set) var pendingDeliveryCount = 0
    @Published public private(set) var pendingDeliveryStates: [String: Bool] = [:]
    @Published public private(set) var pendingPeriodCount = 0
    @Published public private(set) var pendingPeriodStates: [String: Bool] = [:]
    @Published public private(set) var lastConnectionIssue: String?
    @Published public private(set) var lastChatIssue: String?
    @Published public private(set) var lastChatIssueCode: String?
    @Published public private(set) var lastFailedChatText: String?
    @Published public private(set) var repositoryGeneration: UInt64 = 0
    @Published private(set) var isReplayingPendingToggles = false
    @Published private(set) var pendingToggleSyncIssue: String?
    @Published private(set) var legacyPendingToggleCount = 0
    @Published private(set) var legacyPendingReview: MobileLegacyPendingReview?
    /// Documents are fetched only after the user opens one of the allowlisted
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
    private let repositoryIDKey = "studyrocket.repositoryID"
    private var client: StudyRocketRemoteClient?
    private var clientEndpoint: URL?
    private var activeRepositoryID: String?
    private var clientGeneration = 0
    private var pairAttemptGeneration = 0
    private var eventsTask: Task<Void, Never>?
    private var reconnectFailures = 0
    private var streamGeneration = 0
    private var completedTurnIDs = Set<String>()
    private var completedItemKeys = Set<String>()
    private var pendingChatDeltas: [String: PendingChatDelta] = [:]
    private var deltaFlushTask: Task<Void, Never>?
    private var activeChatRequest: ActiveMobileChatRequest?
    private var chatRecoveryTask: Task<Void, Never>?
    private var activeDeliveryMutations = Set<MobileDeliveryMutation>()
    private var completedDeliveryMutations: [MobileDeliveryMutation: MobileDeliveryToggleResult] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshTaskToken: UUID?
    private var pendingReplayTask: Task<Void, Never>?
    private var legacyReviewDeferred = false
    private var isEventProbeInFlight = false
    private var isEventRecoveryInFlight = false
    private let eventStreamsEnabled: Bool
    private let chatRecoveryDelays: [Duration]

    public convenience init(cacheDirectory: URL? = nil) {
        self.init(cacheDirectory: cacheDirectory, client: nil, eventStreamsEnabled: true)
    }

    init(
        cacheDirectory: URL?,
        client: StudyRocketRemoteClient?,
        eventStreamsEnabled: Bool,
        chatRecoveryDelays: [Duration] = [.milliseconds(600), .seconds(1), .seconds(2), .seconds(5)]
    ) {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let base = cacheDirectory ?? applicationSupport.appendingPathComponent("NCU StudyRocket Mobile", isDirectory: true)
        cacheURL = base.appendingPathComponent("snapshot.json")
        draftsURL = base.appendingPathComponent("pending-drafts.json")
        documentsURL = base.appendingPathComponent("documents", isDirectory: true)
        self.eventStreamsEnabled = eventStreamsEnabled
        self.chatRecoveryDelays = chatRecoveryDelays.isEmpty ? [.seconds(2)] : chatRecoveryDelays
        inputDraft = UserDefaults.standard.string(forKey: "studyrocket.inputDraft") ?? ""
        activeRepositoryID = UserDefaults.standard.string(forKey: repositoryIDKey)
        loadCache()
        loadDrafts()
        if let client {
            self.client = client
            clientEndpoint = client.endpoint
            state = snapshot == nil ? .connecting : .offline(lastUpdated: snapshot?.fetchedAt)
            return
        }
        if let endpoint = UserDefaults.standard.string(forKey: endpointKey),
           let url = URL(string: endpoint),
           MobileEndpointError.accepts(url) {
            self.client = StudyRocketRemoteClient(endpoint: url)
            clientEndpoint = url
            if snapshot != nil { state = .offline(lastUpdated: snapshot?.fetchedAt) }
        }
    }

    public var savedEndpoint: String? { UserDefaults.standard.string(forKey: endpointKey) }

    /// Legacy Hosts expose only `dynamicToolsReady`; newer Hosts additionally
    /// distinguish protocol readiness from provider authentication.
    public var isChatAvailable: Bool {
        guard state == .online, let health else { return false }
        if let value = health.chatState, let chatState = StudyRocketChatState(rawValue: value) {
            return chatState.canGenerate
        }
        return health.dynamicToolsReady == true
    }

    public var canViewProposals: Bool { state == .online && client != nil }
    public var canApplyProposals: Bool { canViewProposals && snapshot != nil && !proposals.isEmpty }

    public var chatUnavailableMessage: String? {
        guard state == .online, let health else { return nil }
        if health.chatIssueCode == "provider_auth_failed" || lastChatIssueCode == "provider_auth_failed" {
            return "Codex 身份验证已失效。请在 Mac 上重新登录 Codex，然后重新打开 StudyRocket Host。"
        }
        guard !isChatAvailable else { return nil }
        return "学业对话尚未就绪。Mac Host 会继续重试协议自检；首页、计划和勾选仍可用。"
    }

    /// Fetch a complete read-only document, falling back to the last version
    /// the user opened when the Host is unavailable.
    public func document(for documentKey: String) async -> DocumentDetail? {
        guard MobileDocumentKey.all.contains(documentKey) else { return nil }
        let generation = clientGeneration
        let cached: DocumentDetail?
        if let memoryValue = documentDetails[documentKey] {
            cached = memoryValue
        } else {
            cached = await Self.readCachedDocument(
                at: documentsURL.appendingPathComponent("\(documentKey).json"),
                expectedKey: documentKey
            )
        }
        guard generation == clientGeneration else { return nil }
        if let cached { documentDetails[documentKey] = cached }
        guard let client else { return cached }
        if let cached {
            Task { [weak self] in
                guard let value = try? await client.document(documentKey: documentKey) else { return }
                guard let self, generation == self.clientGeneration else { return }
                self.documentDetails[documentKey] = value
                self.saveDocumentCache(value)
            }
            return cached
        }
        do {
            let value = try await client.document(documentKey: documentKey)
            guard generation == clientGeneration else { return nil }
            documentDetails[documentKey] = value
            saveDocumentCache(value)
            return value
        } catch {
            return cached
        }
    }

    public func configure(endpoint: URL) {
        guard MobileEndpointError.accepts(endpoint) else {
            state = .failed(MobileEndpointError.invalidEndpoint.localizedDescription)
            return
        }
        pairAttemptGeneration &+= 1
        replaceClient(with: StudyRocketRemoteClient(endpoint: endpoint), endpoint: endpoint, persistEndpoint: false)
        Task { await refresh() }
    }

    public func pair(endpoint: URL, code: String, deviceName: String) async throws {
        guard MobileEndpointError.accepts(endpoint) else { throw MobileEndpointError.invalidEndpoint }
        pairAttemptGeneration &+= 1
        let attemptGeneration = pairAttemptGeneration
        let remote = StudyRocketRemoteClient(endpoint: endpoint)
        do {
            let response = try await remote.pair(code: code, deviceName: deviceName)
            guard attemptGeneration == pairAttemptGeneration else { throw MobileHostStateError.connectionChanged }
            UserDefaults.standard.set(response.deviceID, forKey: "studyrocket.deviceID")
        } catch {
            throw MobileEndpointError.contextualized(error)
        }
        replaceClient(with: remote, endpoint: endpoint, persistEndpoint: true)
        await refresh()
    }

    public func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        if let pendingReplayTask {
            await pendingReplayTask.value
        }
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        refreshTaskToken = token
        refreshTask = task
        await task.value
        if refreshTaskToken == token {
            refreshTask = nil
            refreshTaskToken = nil
        }
    }

    private func performRefresh() async {
        guard let client else {
            if snapshot == nil { state = .unconfigured }
            return
        }
        var generation = clientGeneration
        do {
            let health = try await client.health()
            guard generation == clientGeneration else { return }
            if let incomingRepositoryID = health.repositoryID,
               let activeRepositoryID,
               incomingRepositoryID != activeRepositoryID {
                stopEventStream()
                clientGeneration &+= 1
                generation = clientGeneration
                advanceRepositoryGeneration()
                clearRemoteHostState()
            }
            activeRepositoryID = health.repositoryID
            if let repositoryID = health.repositoryID {
                UserDefaults.standard.set(repositoryID, forKey: repositoryIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: repositoryIDKey)
            }
            self.health = health
            if health.chatIssueCode == "provider_auth_failed" {
                setChatIssue(code: "provider_auth_failed", message: nil)
            }
            guard health.repositoryBound, health.codexReady else {
                throw MobileHostStateError.configurationUnavailable
            }
            let value = try await client.snapshot()
            guard generation == clientGeneration else { return }
            snapshot = value
            state = .online
            reconnectFailures = 0
            lastConnectionIssue = nil
            saveCache(value)
            startEventStream()
            prepareLegacyPendingReviewIfNeeded()
            if legacyPendingToggleCount == 0 {
                await replayPendingToggles()
            }
        } catch {
            guard generation == clientGeneration else { return }
            let contextualized = MobileEndpointError.contextualized(error)
            lastConnectionIssue = contextualized.localizedDescription
            state = connectionFailureState(for: contextualized)
        }
    }

    public func sendDraft() async {
        let text = inputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client else { return }
        guard isChatAvailable else { return }
        guard !isChatBusy else { return }
        let generation = clientGeneration
        let pendingID = "mobile-pending-\(UUID().uuidString)"
        activeChatRequest = ActiveMobileChatRequest(pendingID: pendingID, text: text)
        isChatBusy = true
        chatProgress = .sending
        lastChatIssue = nil
        lastChatIssueCode = nil
        chatMessages.append(ChatMessageDTO(id: pendingID, role: "user", text: text, date: .now, status: "inProgress"))
        chatRevision &+= 1
        do {
            let acceptedHistory = try await client.sendChat(text: text)
            guard generation == clientGeneration else { return }
            inputDraft = ""
            if let acceptedHistory { mergeHistory(acceptedHistory) }
            if isChatBusy {
                if chatProgress != .responding { chatProgress = .thinking }
                startChatRecovery(generation: generation)
            }
        } catch {
            guard generation == clientGeneration else { return }
            lastFailedChatText = text
            if let index = chatMessages.firstIndex(where: { $0.id == pendingID }) {
                let pending = chatMessages[index]
                chatMessages[index] = ChatMessageDTO(id: pending.id, role: pending.role, text: pending.text, date: pending.date, turnID: pending.turnID, phase: pending.phase, status: "failed")
                chatRevision &+= 1
            }
            if let remoteError = error as? StudyRocketRemoteError, remoteError.body.code == "codex_starting" {
                markChatUnavailable()
            } else {
                finishChatActivity(issue: error.localizedDescription, issueCode: (error as? StudyRocketRemoteError)?.body.code)
            }
        }
    }

    public func interruptChat() async {
        guard let client, isChatBusy else { return }
        let generation = clientGeneration
        do {
            try await client.interruptChat()
        } catch {
            guard generation == clientGeneration else { return }
            // Proposals are a separate, optional read surface. The terminal
            // reducer will still refresh them after a completed turn, while a
            // transient proposals read must not overwrite that turn's result.
            NSLog("StudyRocket Mobile proposal refresh failed: %@", error.localizedDescription)
        }
        guard generation == clientGeneration else { return }
        finishChatActivity()
    }

    public func refreshChat() async {
        guard let client, canViewProposals else { return }
        let currentStreamGeneration = streamGeneration
        let endpointGeneration = clientGeneration
        do {
            let history = try await client.chatHistory()
            guard currentStreamGeneration == streamGeneration,
                  endpointGeneration == clientGeneration else { return }
            mergeHistory(history)
        } catch {
            if let remoteError = error as? StudyRocketRemoteError, remoteError.body.code == "codex_starting" {
                markChatUnavailable()
            } else {
                setChatIssue(code: (error as? StudyRocketRemoteError)?.body.code, message: error.localizedDescription)
            }
            // 对话历史加载失败不清空已有内容，页面仍可保留当前草稿。
        }
    }

    public func startEventStream() {
        guard eventStreamsEnabled, eventsTask == nil, let client else { return }
        reconnectFailures = 0
        streamGeneration &+= 1
        let currentStreamGeneration = streamGeneration
        let endpointGeneration = clientGeneration
        eventsTask = Task { [weak self] in
            var retryIndex = 0
            while !Task.isCancelled {
                guard let self,
                      self.streamGeneration == currentStreamGeneration,
                      self.clientGeneration == endpointGeneration else { return }
                let stream = await client.events()
                var receivedEvent = false
                var streamEnded = false
                do {
                    for try await value in stream {
                        guard !Task.isCancelled,
                              self.streamGeneration == currentStreamGeneration,
                              self.clientGeneration == endpointGeneration else { break }
                        if !receivedEvent {
                            receivedEvent = true
                            retryIndex = 0
                            self.noteEventStreamConnected()
                        }
                        self.consumeHostEvent(value)
                    }
                    streamEnded = true
                } catch {
                    if !Task.isCancelled,
                       self.streamGeneration == currentStreamGeneration,
                       self.clientGeneration == endpointGeneration {
                        self.noteEventStreamFailure()
                    }
                }
                if streamEnded,
                   !Task.isCancelled,
                   self.streamGeneration == currentStreamGeneration,
                   self.clientGeneration == endpointGeneration {
                    self.noteEventStreamFailure()
                }
                guard !Task.isCancelled,
                      self.streamGeneration == currentStreamGeneration,
                      self.clientGeneration == endpointGeneration else { break }
                let delays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(5)]
                let delay = delays[min(retryIndex, delays.count - 1)]
                retryIndex += 1
                try? await Task.sleep(for: delay)
            }
            guard let self,
                  self.streamGeneration == currentStreamGeneration,
                  self.clientGeneration == endpointGeneration else { return }
            self.eventsTask = nil
        }
    }

    public func stopEventStream() {
        streamGeneration &+= 1
        eventsTask?.cancel()
        eventsTask = nil
        reconnectFailures = 0
        isEventProbeInFlight = false
        isEventRecoveryInFlight = false
    }

    /// An event stream can reconnect before the three-failure health probe
    /// runs. Fetch a fresh snapshot here so queued offline completions are
    /// replayed even when the first recovered event is only a heartbeat.
    func noteEventStreamConnected() {
        reconnectFailures = 0
        guard !isEventRecoveryInFlight else { return }
        isEventRecoveryInFlight = true
        let streamGeneration = self.streamGeneration
        let endpointGeneration = clientGeneration
        Task { [weak self] in
            guard let self,
                  self.streamGeneration == streamGeneration,
                  self.clientGeneration == endpointGeneration else { return }
            await self.refresh()
            guard self.streamGeneration == streamGeneration,
                  self.clientGeneration == endpointGeneration else { return }
            await self.refreshChat()
            guard self.streamGeneration == streamGeneration,
                  self.clientGeneration == endpointGeneration else { return }
            self.isEventRecoveryInFlight = false
        }
    }

    func noteEventStreamFailure() {
        reconnectFailures += 1
        guard reconnectFailures >= 3, !isEventProbeInFlight else { return }
        reconnectFailures = 0
        isEventProbeInFlight = true
        let streamGeneration = self.streamGeneration
        let endpointGeneration = clientGeneration
        Task { [weak self] in
            guard let self,
                  self.streamGeneration == streamGeneration,
                  self.clientGeneration == endpointGeneration else { return }
            await self.refresh()
            guard self.streamGeneration == streamGeneration,
                  self.clientGeneration == endpointGeneration else { return }
            self.isEventProbeInFlight = false
        }
    }

    public func refreshProposals() async {
        guard let client, canViewProposals else { return }
        let generation = clientGeneration
        do {
            let value = try await client.proposals()
            guard generation == clientGeneration else { return }
            proposals = value.proposals
        } catch {
            guard generation == clientGeneration else { return }
            NSLog("StudyRocket Mobile proposal refresh failed: %@", error.localizedDescription)
        }
    }

    private func consumeHostEvent(_ event: HostEventEnvelope) {
        if event.kind == "heartbeat" { return }
        if let snapshot = event.snapshot {
            self.snapshot = snapshot
            state = .online
            saveCache(snapshot)
        }

        switch event.kind {
        case "chat.ready", "chat.protocolReady":
            Task { [weak self] in await self?.refresh() }
        case "chat.started":
            isChatBusy = true
            if chatProgress == nil || chatProgress == .sending { chatProgress = .thinking }
        case "chat.completed", "chat.interrupted":
            finishChatActivity()
        case "chat.failed":
            finishChatActivity(issue: lastChatIssue ?? "学业对话未能完成，请重新发送。", issueCode: lastChatIssueCode)
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
            if var pending = pendingChatDeltas[key] {
                pending.text += text
                pending.phase = event.phase ?? pending.phase
                pendingChatDeltas[key] = pending
            } else {
                pendingChatDeltas[key] = PendingChatDelta(turnID: turnID, itemID: itemID, text: text, phase: event.phase)
            }
            adoptActiveChatTurn(turnID)
            isChatBusy = true
            chatProgress = .responding
            scheduleDeltaFlush()
        case "item_completed":
            guard let turnID = event.turnID, let itemID = event.itemID, let text = event.text else { return }
            let key = streamKey(turnID: turnID, itemID: itemID)
            pendingChatDeltas.removeValue(forKey: key)
            guard completedItemKeys.insert(key).inserted else { return }
            adoptActiveChatTurn(turnID)
            isChatBusy = true
            chatProgress = .responding
            let id = "stream-\(turnID)-\(itemID)"
            if let index = chatMessages.firstIndex(where: { $0.id == id }) {
                let current = chatMessages[index]
                chatMessages[index] = ChatMessageDTO(id: id, role: "assistant", text: text, date: current.date, turnID: turnID, phase: event.phase ?? current.phase, status: completedTurnIDs.contains(turnID) ? "completed" : "inProgress")
            } else {
                chatMessages.append(ChatMessageDTO(id: id, role: "assistant", text: text, date: .now, turnID: turnID, phase: event.phase, status: completedTurnIDs.contains(turnID) ? "completed" : "inProgress"))
            }
            chatRevision &+= 1
        case "status":
            flushPendingChatDeltas()
            if let turnID = event.turnID { adoptActiveChatTurn(turnID) }
            switch event.status {
            case "inProgress":
                isChatBusy = true
                if chatProgress != .responding { chatProgress = .thinking }
            case "completed", "interrupted", "failed":
                guard let turnID = event.turnID else {
                    finishChatActivity(issue: event.status == "failed" ? event.text ?? "学业对话未能完成，请重新发送。" : nil, issueCode: event.issueCode)
                    return
                }
                applyTerminal(ChatTurnTerminalDTO(turnID: turnID, status: event.status ?? "failed", issueCode: event.issueCode, message: event.text, completedAt: event.completedAt))
            default: break
            }
            chatRevision &+= 1
        default: break
        }
    }

    private func startChatRecovery(generation: Int) {
        chatRecoveryTask?.cancel()
        chatRecoveryTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled {
                let delay = self.chatRecoveryDelays[min(attempt, self.chatRecoveryDelays.count - 1)]
                attempt += 1
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      generation == self.clientGeneration,
                      self.isChatBusy else { return }
                if self.chatProgress != .responding {
                    self.chatProgress = attempt > self.chatRecoveryDelays.count ? .recovering : .thinking
                }
                await self.refreshChat()
            }
        }
    }

    private func adoptActiveChatTurn(_ turnID: String) {
        guard var request = activeChatRequest else { return }
        request.turnID = turnID
        activeChatRequest = request
    }

    private func finishChatActivity(issue: String? = nil, issueCode: String? = nil) {
        chatRecoveryTask?.cancel()
        chatRecoveryTask = nil
        activeChatRequest = nil
        isChatBusy = false
        chatProgress = nil
        if let issue { setChatIssue(code: issueCode, message: issue) }
    }

    private func setChatIssue(code: String?, message: String?) {
        lastChatIssueCode = code
        if code == "provider_auth_failed" {
            lastChatIssue = "Codex 身份验证已失效。请在 Mac 上重新登录 Codex，然后重新打开 StudyRocket Host。"
        } else if let message, !message.isEmpty {
            lastChatIssue = message
        }
    }

    public func restoreFailedChatDraft() {
        guard let text = lastFailedChatText, !text.isEmpty else { return }
        inputDraft = text
        lastChatIssue = nil
        lastChatIssueCode = nil
    }

    private func applyTerminal(_ terminal: ChatTurnTerminalDTO) {
        guard Self.isTerminalChatStatus(terminal.status) else { return }
        guard completedTurnIDs.insert(terminal.turnID).inserted else { return }
        if terminal.status == "failed" {
            lastFailedChatText = activeChatRequest?.text ?? lastFailedChatText
            finishChatActivity(issue: terminal.message ?? "学业对话未能完成，请重新发送。", issueCode: terminal.issueCode)
        } else {
            finishChatActivity()
            lastChatIssue = nil
            lastChatIssueCode = nil
            lastFailedChatText = nil
        }
        Task { [weak self] in
            await self?.refreshChat()
            await self?.refreshProposals()
        }
    }

    private func reconcileChatActivity(with history: [ChatMessageDTO], terminals: [ChatTurnTerminalDTO]) {
        guard var request = activeChatRequest else { return }
        let matchedTurnID = request.turnID ?? history.reversed().first(where: {
            $0.role == "user" && $0.text == request.text
        })?.turnID
        guard let turnID = matchedTurnID else {
            if isChatBusy, chatProgress == .sending { chatProgress = .thinking }
            return
        }
        request.turnID = turnID
        activeChatRequest = request
        let turnMessages = history.filter { $0.turnID == turnID }
        if let terminal = terminals.last(where: { $0.turnID == turnID }) {
            applyTerminal(terminal)
        } else if let status = turnMessages.compactMap(\.status).last(where: Self.isTerminalChatStatus) {
            applyTerminal(ChatTurnTerminalDTO(turnID: turnID, status: status))
        } else if turnMessages.contains(where: { $0.role == "assistant" }) {
            isChatBusy = true
            chatProgress = .responding
        } else if isChatBusy {
            chatProgress = .thinking
        }
    }

    private static func isTerminalChatStatus(_ value: String) -> Bool {
        ["completed", "interrupted", "failed"].contains(value)
    }

    private func scheduleDeltaFlush() {
        guard deltaFlushTask == nil else { return }
        deltaFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self?.flushPendingChatDeltas()
            self?.deltaFlushTask = nil
        }
    }

    private func flushPendingChatDeltas() {
        guard !pendingChatDeltas.isEmpty else { return }
        let values = Array(pendingChatDeltas.values)
        pendingChatDeltas.removeAll(keepingCapacity: true)
        for value in values {
            let id = "stream-\(value.turnID)-\(value.itemID)"
            if let index = chatMessages.firstIndex(where: { $0.id == id }) {
                let current = chatMessages[index]
                chatMessages[index] = ChatMessageDTO(id: id, role: "assistant", text: current.text + value.text, date: current.date, turnID: value.turnID, phase: value.phase ?? current.phase, status: "inProgress")
            } else {
                chatMessages.append(ChatMessageDTO(id: id, role: "assistant", text: value.text, date: .now, turnID: value.turnID, phase: value.phase, status: "inProgress"))
            }
        }
        chatRevision &+= 1
    }

    private func mergeHistory(_ response: ChatHistoryResponse) {
        let history = response.messages
        let activeHistoryTurnID = activeChatRequest?.turnID ?? history.reversed().first(where: {
            $0.role == "user" && $0.text == activeChatRequest?.text
        })?.turnID
        let streamMessages = chatMessages.filter { $0.id.hasPrefix("stream-") }
        let pendingMessages = chatMessages.filter { $0.id.hasPrefix("mobile-pending-") }
        var merged = history.map { message in
            let status = message.status ?? (message.turnID.map { completedTurnIDs.contains($0) } == true ? "completed" : nil)
            if let turnID = message.turnID {
                if (status == "completed" || status == "interrupted" || status == "failed"), turnID != activeHistoryTurnID {
                    completedTurnIDs.insert(turnID)
                }
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
        reconcileChatActivity(with: sorted, terminals: response.terminalTurns ?? [])
    }

    private func streamKey(turnID: String, itemID: String) -> String { "\(turnID)|\(itemID)" }

    private func streamItemID(_ streamID: String, turnID: String) -> String {
        let prefix = "stream-\(turnID)-"
        return streamID.hasPrefix(prefix) ? String(streamID.dropFirst(prefix.count)) : streamID
    }

    public func applyProposals(ids: [String]? = nil) async {
        guard let client, canApplyProposals, let current = snapshot else { return }
        let generation = clientGeneration
        let selectedIDs = ids ?? proposals.map(\.id)
        guard !selectedIDs.isEmpty else { return }
        do {
            let challenge = try await client.proposalChallenge()
            guard generation == clientGeneration else { return }
            let authorization = try await MobileProposalAuthorization.evaluate(challenge: challenge)
            guard generation == clientGeneration else { return }
            let response = try await client.applyProposals(ids: selectedIDs, authorization: authorization, baseRevision: current.revision)
            guard generation == clientGeneration else { return }
            proposals = response.remaining.proposals
            await refresh()
        } catch {
            guard generation == clientGeneration else { return }
            lastChatIssue = error.localizedDescription
        }
    }

    public func saveWeek(_ plan: WeeklyPlanSnapshot) async {
        let normalizedPlan = WeeklyPlanTaskNormalizer.normalized(plan)
        guard let client, let current = snapshot, state == .online, !isReplayingPendingToggles else {
            pendingWeekDraft = normalizedPlan
            saveDrafts()
            return
        }
        let generation = clientGeneration
        do {
            let value = try await client.applyWeek(plan: normalizedPlan, baseRevision: current.revision)
            guard generation == clientGeneration else { return }
            snapshot = value
            state = .online
            saveCache(value)
        } catch {
            guard generation == clientGeneration else { return }
            pendingWeekDraft = normalizedPlan
            saveDrafts()
            recordConnectionFailureIfNeeded(error)
        }
    }

    func toggleDelivery(
        _ delivery: DeliverySnapshot,
        isCompleted: Bool,
        mutation: MobileDeliveryMutation
    ) async -> MobileDeliveryToggleResult {
        guard mutation.deliveryID == delivery.id,
              mutation.repositoryGeneration == repositoryGeneration else {
            return .staleGeneration
        }
        if let completed = completedDeliveryMutations[mutation] { return completed }
        guard activeDeliveryMutations.insert(mutation).inserted else { return .staleGeneration }

        let result = await performDeliveryToggle(delivery, isCompleted: isCompleted, mutation: mutation)
        activeDeliveryMutations.remove(mutation)
        if mutation.repositoryGeneration == repositoryGeneration {
            completedDeliveryMutations[mutation] = result
        }
        return result
    }

    private func performDeliveryToggle(
        _ delivery: DeliverySnapshot,
        isCompleted desired: Bool,
        mutation: MobileDeliveryMutation
    ) async -> MobileDeliveryToggleResult {
        if pendingDeliveryStates[delivery.text] != nil {
            return .failed("此交付物已有待同步修改，请先取消或完成同步。")
        }
        lastConnectionIssue = nil
        guard let client, let current = snapshot, state == .online, !isReplayingPendingToggles else {
            var drafts = loadPendingDrafts()
            drafts.deliveries.removeAll { $0.text == delivery.text }
            drafts.deliveries.append(PendingDeliveryToggle(
                text: delivery.text,
                isCompleted: desired,
                idempotencyKey: mutation.token.uuidString
            ))
            saveDrafts(drafts)
            return .queuedOffline
        }
        let generation = clientGeneration
        let requestRepositoryGeneration = repositoryGeneration
        do {
            let value = try await client.toggleDelivery(
                text: delivery.text,
                isCompleted: desired,
                baseRevision: current.revision,
                idempotencyKey: mutation.token.uuidString,
                timeoutInterval: 12
            )
            guard generation == clientGeneration,
                  requestRepositoryGeneration == repositoryGeneration else {
                return .staleGeneration
            }
            guard let authoritative = value.week.deliveries.first(where: {
                $0.id == delivery.id
                    || $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        == delivery.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }), authoritative.isCompleted == desired else {
                let message = "Mac Host 返回的交付物状态未确认本次修改，已恢复原状态。"
                pendingToggleSyncIssue = message
                return .failed(message)
            }
            snapshot = value
            var drafts = loadPendingDrafts()
            drafts.deliveries.removeAll { $0.text == delivery.text }
            saveDrafts(drafts)
            lastConnectionIssue = nil
            pendingToggleSyncIssue = nil
            state = .online
            saveCache(value)
            return .confirmed(value)
        } catch {
            guard generation == clientGeneration,
                  requestRepositoryGeneration == repositoryGeneration else {
                return .staleGeneration
            }
            if Task.isCancelled { return .staleGeneration }
            if shouldReconcileAfterWrite(error),
               let reconciled = await reconciledSnapshot(
                    client: client,
                    generation: generation,
                    delivery: delivery,
                    isCompleted: desired
               ) {
                if reconciled.confirmed { return .confirmed(reconciled.snapshot) }
                let message = "Mac Host 未确认本次交付物修改，已恢复权威状态。"
                pendingToggleSyncIssue = message
                return .failed(message)
            }
            let message = "未能保存交付物完成状态：\(error.localizedDescription)"
            recordOperationFailure(error, message: message)
            return .failed(message)
        }
    }

    func cancelPendingDelivery(_ delivery: DeliverySnapshot) {
        var drafts = loadPendingDrafts()
        drafts.deliveries.removeAll { $0.text == delivery.text && $0.idempotencyKey != nil }
        saveDrafts(drafts)
        pendingToggleSyncIssue = nil
        refreshLegacyPendingReviewIfVisible()
    }

    public func effectiveDeliveryCompletion(_ delivery: DeliverySnapshot) -> Bool {
        pendingDeliveryStates[delivery.text] ?? delivery.isCompleted
    }

    public func isDeliveryTogglePending(_ delivery: DeliverySnapshot) -> Bool {
        pendingDeliveryStates[delivery.text] != nil
    }

    func isLegacyDeliveryTogglePending(_ delivery: DeliverySnapshot) -> Bool {
        loadPendingDrafts().deliveries.contains { $0.text == delivery.text && $0.idempotencyKey == nil }
    }

    func canCancelPendingDelivery(_ delivery: DeliverySnapshot) -> Bool {
        !isReplayingPendingToggles
            && loadPendingDrafts().deliveries.contains { $0.text == delivery.text && $0.idempotencyKey != nil }
    }

    public func effectiveTaskCompletion(
        dayID: String,
        period: PeriodSnapshot,
        task: PeriodTaskSnapshot
    ) -> Bool {
        pendingPeriodStates[taskKey(dayID: dayID, periodID: period.id, taskID: task.id)] ?? task.isCompleted
    }

    public func isTaskTogglePending(
        dayID: String,
        period: PeriodSnapshot,
        task: PeriodTaskSnapshot
    ) -> Bool {
        pendingPeriodStates[taskKey(dayID: dayID, periodID: period.id, taskID: task.id)] != nil
    }

    public func toggleTask(
        dayID: String,
        period: PeriodSnapshot,
        task: PeriodTaskSnapshot,
        isCompleted desired: Bool
    ) async {
        guard ["morning", "noon", "evening"].contains(period.id),
              period.tasks.contains(where: { $0.id == task.id }) else { return }
        let key = taskKey(dayID: dayID, periodID: period.id, taskID: task.id)
        if pendingPeriodStates[key] != nil {
            return
        }
        let idempotencyKey = UUID().uuidString
        lastConnectionIssue = nil
        pendingPeriodStates[key] = desired

        guard let client, let current = snapshot, state == .online, !isReplayingPendingToggles else {
            var drafts = loadPendingDrafts()
            drafts.periods.removeAll { $0.key == key }
            drafts.periods.append(PendingPeriodToggle(
                dayID: dayID,
                periodID: period.id,
                taskID: task.id,
                isCompleted: desired,
                idempotencyKey: idempotencyKey
            ))
            saveDrafts(drafts)
            return
        }

        let generation = clientGeneration
        do {
            let value = try await client.togglePeriod(
                dayID: dayID,
                periodID: period.id,
                taskID: task.id,
                isCompleted: desired,
                baseRevision: current.revision,
                idempotencyKey: idempotencyKey,
                timeoutInterval: 12
            )
            guard generation == clientGeneration else { return }
            snapshot = value
            pendingPeriodStates.removeValue(forKey: key)
            lastConnectionIssue = nil
            pendingToggleSyncIssue = nil
            state = .online
            saveCache(value)
        } catch {
            guard generation == clientGeneration else { return }
            if Task.isCancelled { return }
            if shouldReconcileAfterWrite(error),
               let reconciled = await reconciledSnapshot(
                    client: client,
                    generation: generation,
                    dayID: dayID,
                    period: period,
                    task: task,
                    isCompleted: desired
               ) {
                pendingPeriodStates.removeValue(forKey: key)
                if reconciled.confirmed { return }
                pendingToggleSyncIssue = "Mac Host 未确认“\(task.text)”的完成状态，已恢复权威状态。"
                return
            }
            pendingPeriodStates.removeValue(forKey: key)
            let message = "未能保存“\(task.text)”完成状态：\(error.localizedDescription)"
            recordOperationFailure(error, message: message)
        }
    }

    func cancelPendingTask(dayID: String, period: PeriodSnapshot, task: PeriodTaskSnapshot) {
        let key = taskKey(dayID: dayID, periodID: period.id, taskID: task.id)
        var drafts = loadPendingDrafts()
        drafts.periods.removeAll { $0.key == key && $0.idempotencyKey != nil }
        saveDrafts(drafts)
        pendingToggleSyncIssue = nil
        refreshLegacyPendingReviewIfVisible()
    }

    func isLegacyPeriodTogglePending(dayID: String, period: PeriodSnapshot) -> Bool {
        let key = periodKey(dayID: dayID, periodID: period.id)
        return loadPendingDrafts().periods.contains { $0.periodKey == key && $0.isLegacy }
    }

    func canCancelPendingTask(dayID: String, period: PeriodSnapshot, task: PeriodTaskSnapshot) -> Bool {
        let key = taskKey(dayID: dayID, periodID: period.id, taskID: task.id)
        return !isReplayingPendingToggles
            && loadPendingDrafts().periods.contains { $0.key == key && $0.idempotencyKey != nil }
    }

    public func effectivePeriodCompletion(dayID: String, period: PeriodSnapshot) -> Bool {
        !period.tasks.isEmpty && period.tasks.allSatisfy {
            effectiveTaskCompletion(dayID: dayID, period: period, task: $0)
        }
    }

    public func isPeriodTogglePending(dayID: String, period: PeriodSnapshot) -> Bool {
        period.tasks.contains { isTaskTogglePending(dayID: dayID, period: period, task: $0) }
    }

    func presentLegacyPendingReview() {
        legacyReviewDeferred = false
        prepareLegacyPendingReviewIfNeeded(force: true)
    }

    func deferLegacyPendingReview() {
        guard legacyPendingToggleCount > 0 else { return }
        legacyReviewDeferred = true
        legacyPendingReview = nil
    }

    func applyLegacyPendingReview(selectedIDs: Set<String>) async {
        guard let snapshot else { return }
        let currentReview = makeLegacyPendingReview(from: loadPendingDrafts(), snapshot: snapshot)
        let selectable = currentReview.selectableIDs
        var drafts = loadPendingDrafts()
        drafts.deliveries = drafts.deliveries.compactMap { draft in
            guard draft.idempotencyKey == nil else { return draft }
            let id = legacyDeliveryReviewID(draft)
            guard selectedIDs.contains(id) else { return nil }
            guard selectable.contains(id) else { return draft }
            return PendingDeliveryToggle(
                text: draft.text,
                isCompleted: draft.isCompleted,
                idempotencyKey: UUID().uuidString
            )
        }
        drafts.periods = drafts.periods.compactMap { draft in
            guard draft.isLegacy else { return draft }
            let id = legacyPeriodReviewID(draft)
            guard selectedIDs.contains(id) else { return nil }
            guard selectable.contains(id) else { return draft }
            guard let period = matchingPeriod(dayID: draft.dayID, periodID: draft.periodID, in: snapshot)?.period,
                  let task = period.tasks.first,
                  period.tasks.count == 1 else { return draft }
            return PendingPeriodToggle(
                dayID: draft.dayID,
                periodID: draft.periodID,
                taskID: task.id,
                isCompleted: draft.isCompleted,
                idempotencyKey: UUID().uuidString
            )
        }
        legacyReviewDeferred = false
        legacyPendingReview = nil
        saveDrafts(drafts)
        prepareLegacyPendingReviewIfNeeded()
        if legacyPendingToggleCount == 0 {
            await replayPendingToggles()
        }
    }

    func discardLegacyPendingToggles() {
        var drafts = loadPendingDrafts()
        drafts.deliveries.removeAll { $0.idempotencyKey == nil }
        drafts.periods.removeAll(where: \.isLegacy)
        legacyReviewDeferred = false
        legacyPendingReview = nil
        pendingToggleSyncIssue = nil
        saveDrafts(drafts)
    }

    func retryPendingToggles() async {
        pendingToggleSyncIssue = nil
        if state != .online {
            await refresh()
            return
        }
        prepareLegacyPendingReviewIfNeeded()
        guard legacyPendingToggleCount == 0 else {
            presentLegacyPendingReview()
            return
        }
        await replayPendingToggles()
    }

    private func prepareLegacyPendingReviewIfNeeded(force: Bool = false) {
        let drafts = loadPendingDrafts()
        let hasLegacy = drafts.deliveries.contains { $0.idempotencyKey == nil }
            || drafts.periods.contains(where: \.isLegacy)
        guard hasLegacy else {
            legacyReviewDeferred = false
            legacyPendingReview = nil
            return
        }
        guard let snapshot, force || !legacyReviewDeferred else { return }
        legacyPendingReview = makeLegacyPendingReview(from: drafts, snapshot: snapshot)
    }

    private func refreshLegacyPendingReviewIfVisible() {
        guard legacyPendingReview != nil else { return }
        prepareLegacyPendingReviewIfNeeded(force: true)
    }

    private func makeLegacyPendingReview(
        from drafts: MobilePendingDrafts,
        snapshot: SnapshotResponse
    ) -> MobileLegacyPendingReview {
        var items: [MobileLegacyPendingReviewItem] = []
        for draft in drafts.deliveries where draft.idempotencyKey == nil {
            let delivery = matchingDelivery(text: draft.text, in: snapshot)
            let target = draft.isCompleted ? "标记为已完成" : "恢复为未完成"
            items.append(MobileLegacyPendingReviewItem(
                id: legacyDeliveryReviewID(draft),
                kind: .delivery,
                title: delivery?.text ?? draft.text,
                detail: delivery.map { [$0.dateLabel, target].compactMap { $0 }.joined(separator: " · ") }
                    ?? "任务已变化，无法自动同步",
                isCompleted: draft.isCompleted,
                canSync: delivery != nil
            ))
        }
        for draft in drafts.periods where draft.isLegacy {
            let match = matchingPeriod(dayID: draft.dayID, periodID: draft.periodID, in: snapshot)
            let canSync = match.map {
                $0.period.tasks.count == 1
                    && PeriodCompletion.textHash(for: $0.period.text) == draft.textHash
            } == true
            let target = draft.isCompleted ? "标记为已完成" : "恢复为未完成"
            items.append(MobileLegacyPendingReviewItem(
                id: legacyPeriodReviewID(draft),
                kind: .period,
                title: canSync ? (match?.period.tasks.first?.text ?? "时段任务") : "\(draft.dayID) · \(periodTitle(draft.periodID))",
                detail: canSync ? "\(match?.dateLabel ?? draft.dayID) · \(match?.period.title ?? periodTitle(draft.periodID)) · \(target)"
                    : match?.period.tasks.count ?? 0 > 1
                        ? "旧版操作指向多个任务，请在首页逐项确认。"
                        : "任务已变化，无法自动同步",
                isCompleted: draft.isCompleted,
                canSync: canSync
            ))
        }
        return MobileLegacyPendingReview(items: items)
    }

    private func legacyDeliveryReviewID(_ draft: PendingDeliveryToggle) -> String {
        "delivery:\(PeriodCompletion.textHash(for: draft.text)):\(draft.isCompleted)"
    }

    private func legacyPeriodReviewID(_ draft: PendingPeriodToggle) -> String {
        "period:\(draft.dayID):\(draft.periodID):\(draft.textHash ?? "unknown"):\(draft.isCompleted)"
    }

    private func periodTitle(_ periodID: String) -> String {
        switch periodID {
        case "morning": return "上午"
        case "noon": return "中午"
        case "evening": return "晚上"
        default: return periodID
        }
    }

    public func saveDaily(_ entry: DailySnapshot) async {
        guard let client, let current = snapshot, state == .online, !isReplayingPendingToggles else {
            pendingDailyDraft = entry
            saveDrafts()
            return
        }
        let generation = clientGeneration
        do {
            let value = try await client.saveDaily(entry: entry, baseRevision: current.revision)
            guard generation == clientGeneration else { return }
            snapshot = value
            state = .online
            saveCache(value)
        } catch {
            guard generation == clientGeneration else { return }
            pendingDailyDraft = entry
            saveDrafts()
            recordConnectionFailureIfNeeded(error)
        }
    }

    public var hasPendingDrafts: Bool {
        pendingWeekDraft != nil || pendingDailyDraft != nil || pendingDeliveryCount > 0 || pendingPeriodCount > 0
    }

    public func commitPendingDrafts() async {
        if let pendingReplayTask {
            await pendingReplayTask.value
        }
        guard let client, snapshot != nil, state == .online else { return }
        let generation = clientGeneration
        do {
            if let week = pendingWeekDraft, let latest = snapshot {
                let value = try await client.applyWeek(plan: week, baseRevision: latest.revision)
                guard generation == clientGeneration else { return }
                snapshot = value
                pendingWeekDraft = nil
                saveCache(value)
                saveDrafts()
            }
            if let daily = pendingDailyDraft, let latest = snapshot {
                let value = try await client.saveDaily(entry: daily, baseRevision: latest.revision)
                guard generation == clientGeneration else { return }
                snapshot = value
                pendingDailyDraft = nil
                saveCache(value)
                saveDrafts()
            }
            prepareLegacyPendingReviewIfNeeded()
            if legacyPendingToggleCount == 0 {
                await replayPendingToggles()
            }
        } catch {
            guard generation == clientGeneration else { return }
            recordConnectionFailureIfNeeded(error)
        }
    }

    private func replayPendingToggles() async {
        if let pendingReplayTask {
            await pendingReplayTask.value
            return
        }
        let drafts = loadPendingDrafts()
        guard legacyPendingToggleCount == 0,
              (drafts.deliveries.contains(where: { $0.idempotencyKey != nil })
                || drafts.periods.contains(where: { $0.idempotencyKey != nil && !$0.isLegacy })) else {
            if pendingDeliveryCount == 0, pendingPeriodCount == 0 {
                pendingToggleSyncIssue = nil
            }
            return
        }
        guard client != nil, snapshot != nil, state == .online else { return }

        let generation = clientGeneration
        let requestRepositoryGeneration = repositoryGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performPendingToggleReplay(
                generation: generation,
                repositoryGeneration: requestRepositoryGeneration
            )
        }
        pendingReplayTask = task
        isReplayingPendingToggles = true
        await task.value
        guard generation == clientGeneration,
              requestRepositoryGeneration == repositoryGeneration else { return }
        pendingReplayTask = nil
        isReplayingPendingToggles = false
    }

    private func performPendingToggleReplay(generation: Int, repositoryGeneration: UInt64) async {
        guard let client else { return }
        pendingToggleSyncIssue = nil

        while !Task.isCancelled {
            let drafts = loadPendingDrafts()
            guard let draft = drafts.deliveries.first(where: { $0.idempotencyKey != nil }) else { break }
            guard generation == clientGeneration,
                  repositoryGeneration == self.repositoryGeneration,
                  let latest = snapshot else { return }
            guard let delivery = matchingDelivery(text: draft.text, in: latest) else {
                pendingToggleSyncIssue = "交付物已变化，自动同步已暂停。请重新加载后检查待同步项目。"
                return
            }
            if delivery.isCompleted == draft.isCompleted {
                removePendingDeliveryDraft(draft)
                continue
            }
            do {
                let value = try await client.toggleDelivery(
                    text: delivery.text,
                    isCompleted: draft.isCompleted,
                    baseRevision: latest.revision,
                    idempotencyKey: draft.idempotencyKey!,
                    timeoutInterval: 12
                )
                guard generation == clientGeneration,
                      repositoryGeneration == self.repositoryGeneration else { return }
                guard matchingDelivery(text: draft.text, in: value)?.isCompleted == draft.isCompleted else {
                    snapshot = value
                    state = .online
                    saveCache(value)
                    pendingToggleSyncIssue = "Mac Host 未确认一个交付物的目标状态，自动同步已暂停。"
                    return
                }
                snapshot = value
                state = .online
                lastConnectionIssue = nil
                saveCache(value)
                removePendingDeliveryDraft(draft)
            } catch {
                guard generation == clientGeneration,
                      repositoryGeneration == self.repositoryGeneration,
                      !Task.isCancelled else { return }
                if shouldReconcileAfterWrite(error),
                   let reconciled = await reconciledSnapshot(
                        client: client,
                        generation: generation,
                        delivery: delivery,
                        isCompleted: draft.isCompleted
                   ) {
                    if reconciled.confirmed {
                        removePendingDeliveryDraft(draft)
                        continue
                    }
                    pendingToggleSyncIssue = "计划已在 Mac 上变化，交付物同步未完成。请重新加载后重试。"
                    return
                }
                recordOperationFailure(error, message: "交付物同步未完成：\(error.localizedDescription)")
                return
            }
        }

        while !Task.isCancelled {
            let drafts = loadPendingDrafts()
            guard let draft = drafts.periods.first(where: { $0.idempotencyKey != nil && !$0.isLegacy }),
                  let taskID = draft.taskID else { break }
            guard generation == clientGeneration,
                  repositoryGeneration == self.repositoryGeneration,
                  let latest = snapshot else { return }
            guard let match = matchingPeriod(dayID: draft.dayID, periodID: draft.periodID, in: latest),
                  let task = match.period.tasks.first(where: { $0.id == taskID }) else {
                pendingToggleSyncIssue = "时段任务已变化，自动同步已暂停。请重新加载后检查待同步项目。"
                return
            }
            if task.isCompleted == draft.isCompleted {
                removePendingPeriodDraft(draft)
                continue
            }
            do {
                let value = try await client.togglePeriod(
                    dayID: draft.dayID,
                    periodID: draft.periodID,
                    taskID: taskID,
                    isCompleted: draft.isCompleted,
                    baseRevision: latest.revision,
                    idempotencyKey: draft.idempotencyKey!,
                    timeoutInterval: 12
                )
                guard generation == clientGeneration,
                      repositoryGeneration == self.repositoryGeneration else { return }
                guard let updated = matchingPeriod(dayID: draft.dayID, periodID: draft.periodID, in: value),
                      updated.period.tasks.first(where: { $0.id == taskID })?.isCompleted == draft.isCompleted else {
                    snapshot = value
                    state = .online
                    saveCache(value)
                    pendingToggleSyncIssue = "Mac Host 未确认一个时段任务的目标状态，自动同步已暂停。"
                    return
                }
                snapshot = value
                state = .online
                lastConnectionIssue = nil
                saveCache(value)
                removePendingPeriodDraft(draft)
            } catch {
                guard generation == clientGeneration,
                      repositoryGeneration == self.repositoryGeneration,
                      !Task.isCancelled else { return }
                if shouldReconcileAfterWrite(error),
                   let reconciled = await reconciledSnapshot(
                        client: client,
                        generation: generation,
                        dayID: draft.dayID,
                        period: match.period,
                        task: task,
                        isCompleted: draft.isCompleted
                   ) {
                    if reconciled.confirmed {
                        removePendingPeriodDraft(draft)
                        continue
                    }
                    pendingToggleSyncIssue = "计划已在 Mac 上变化，时段同步未完成。请重新加载后重试。"
                    return
                }
                recordOperationFailure(error, message: "时段同步未完成：\(error.localizedDescription)")
                return
            }
        }

        if !Task.isCancelled {
            pendingToggleSyncIssue = nil
        }
    }

    private func removePendingDeliveryDraft(_ draft: PendingDeliveryToggle) {
        var drafts = loadPendingDrafts()
        drafts.deliveries.removeAll { $0 == draft }
        saveDrafts(drafts)
    }

    private func removePendingPeriodDraft(_ draft: PendingPeriodToggle) {
        var drafts = loadPendingDrafts()
        drafts.periods.removeAll { $0 == draft }
        saveDrafts(drafts)
    }

    private func matchingDelivery(text: String, in snapshot: SnapshotResponse) -> DeliverySnapshot? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.week.deliveries.first {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
        }
    }

    private func matchingPeriod(
        dayID: String,
        periodID: String,
        in snapshot: SnapshotResponse
    ) -> (dateLabel: String, period: PeriodSnapshot)? {
        if let day = snapshot.week.days.first(where: { $0.id == dayID }),
           let period = day.slots.first(where: { $0.id == periodID }) {
            return (day.dateLabel, period)
        }
        if let day = snapshot.week.historicalRows.first(where: { $0.id == dayID }),
           let period = day.slots.first(where: { $0.id == periodID }) {
            return (day.dateLabel, period)
        }
        if let day = snapshot.week.futureRows.first(where: { $0.id == dayID }),
           let period = day.slots.first(where: { $0.id == periodID }) {
            return (day.dateLabel, period)
        }
        return nil
    }

    private func shouldReconcileAfterWrite(_ error: Error) -> Bool {
        if let remote = error as? StudyRocketRemoteError {
            return remote.body.code == "conflict"
        }
        guard let urlError = error as? URLError else { return false }
        return urlError.code != .cancelled
    }

    private func reconciledSnapshot(
        client: StudyRocketRemoteClient,
        generation: Int,
        delivery: DeliverySnapshot,
        isCompleted: Bool
    ) async -> (snapshot: SnapshotResponse, confirmed: Bool)? {
        guard let value = try? await client.snapshot(timeoutInterval: 5),
              generation == clientGeneration else { return nil }
        snapshot = value
        state = .online
        lastConnectionIssue = nil
        saveCache(value)
        return (value, matchingDelivery(text: delivery.text, in: value)?.isCompleted == isCompleted)
    }

    private func reconciledSnapshot(
        client: StudyRocketRemoteClient,
        generation: Int,
        dayID: String,
        period: PeriodSnapshot,
        task: PeriodTaskSnapshot,
        isCompleted: Bool
    ) async -> (snapshot: SnapshotResponse, confirmed: Bool)? {
        guard let value = try? await client.snapshot(timeoutInterval: 5),
              generation == clientGeneration else { return nil }
        snapshot = value
        state = .online
        lastConnectionIssue = nil
        saveCache(value)
        let match = matchingPeriod(dayID: dayID, periodID: period.id, in: value)
        let updatedTask = match?.period.tasks.first(where: { $0.id == task.id })
        return (value, updatedTask?.isCompleted == isCompleted)
    }

    private func recordOperationFailure(_ error: Error, message: String) {
        pendingToggleSyncIssue = message
        recordConnectionFailureIfNeeded(error)
    }

    private func recordConnectionFailureIfNeeded(_ error: Error) {
        let contextualized = MobileEndpointError.contextualized(error)
        guard isTransportOrConnectionFailure(contextualized) else { return }
        lastConnectionIssue = contextualized.localizedDescription
        state = connectionFailureState(for: contextualized)
    }

    private func connectionFailureState(for error: Error) -> MobileConnectionState {
        if isAuthenticationOrConfigurationFailure(error) {
            return .failed(error.localizedDescription)
        }
        return snapshot == nil
            ? .failed(error.localizedDescription)
            : .offline(lastUpdated: snapshot?.fetchedAt)
    }

    private func isTransportOrConnectionFailure(_ error: Error) -> Bool {
        if error is URLError || error is MobileEndpointError { return true }
        return isAuthenticationOrConfigurationFailure(error)
    }

    private func isAuthenticationOrConfigurationFailure(_ error: Error) -> Bool {
        if let remote = error as? StudyRocketRemoteError {
            return ["unauthorized", "repository_unbound"].contains(remote.body.code)
        }
        guard let hostError = error as? MobileHostStateError else { return false }
        switch hostError {
        case .configurationUnavailable, .incompatibleAPI:
            return true
        case .connectionChanged:
            return false
        }
    }

    public func discardPendingDrafts() {
        pendingReplayTask?.cancel()
        pendingReplayTask = nil
        isReplayingPendingToggles = false
        pendingWeekDraft = nil
        pendingDailyDraft = nil
        pendingDeliveryCount = 0
        pendingDeliveryStates = [:]
        pendingPeriodCount = 0
        pendingPeriodStates = [:]
        legacyPendingToggleCount = 0
        legacyPendingReview = nil
        legacyReviewDeferred = false
        pendingToggleSyncIssue = nil
        saveDrafts(MobilePendingDrafts(week: nil, daily: nil, deliveries: [], periods: []))
    }

    public func clearLocalCache() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskToken = nil
        finishChatActivity()
        clientGeneration &+= 1
        pairAttemptGeneration &+= 1
        advanceRepositoryGeneration()
        stopEventStream()
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        pendingChatDeltas.removeAll()
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: draftsURL)
        try? FileManager.default.removeItem(at: documentsURL)
        clearWidgetSnapshot()
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
        pendingDeliveryStates = [:]
        pendingPeriodCount = 0
        pendingPeriodStates = [:]
        legacyPendingToggleCount = 0
        legacyPendingReview = nil
        legacyReviewDeferred = false
        pendingToggleSyncIssue = nil
        isReplayingPendingToggles = false
        inputDraft = ""
        lastConnectionIssue = nil
        lastChatIssue = nil
        if client == nil {
            state = .unconfigured
        } else {
            state = .connecting
            Task { await refresh() }
        }
    }

    private func replaceClient(with newClient: StudyRocketRemoteClient, endpoint: URL, persistEndpoint: Bool) {
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskToken = nil
        stopEventStream()
        clientGeneration &+= 1
        advanceRepositoryGeneration()
        client = newClient
        clientEndpoint = endpoint
        if persistEndpoint {
            UserDefaults.standard.set(endpoint.absoluteString, forKey: endpointKey)
        }
        clearRemoteHostState()
        state = .connecting
    }

    private func advanceRepositoryGeneration() {
        pendingReplayTask?.cancel()
        pendingReplayTask = nil
        isReplayingPendingToggles = false
        repositoryGeneration &+= 1
        activeDeliveryMutations.removeAll()
        completedDeliveryMutations.removeAll()
    }

    private func clearRemoteHostState() {
        finishChatActivity()
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        pendingChatDeltas.removeAll()
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: draftsURL)
        try? FileManager.default.removeItem(at: documentsURL)
        clearWidgetSnapshot()
        snapshot = nil
        health = nil
        chatMessages = []
        chatRevision &+= 1
        proposals = []
        documentDetails = [:]
        completedTurnIDs.removeAll()
        completedItemKeys.removeAll()
        reconnectFailures = 0
        pendingWeekDraft = nil
        pendingDailyDraft = nil
        pendingDeliveryCount = 0
        pendingDeliveryStates = [:]
        pendingPeriodCount = 0
        pendingPeriodStates = [:]
        legacyPendingToggleCount = 0
        legacyPendingReview = nil
        legacyReviewDeferred = false
        pendingToggleSyncIssue = nil
        activeRepositoryID = nil
        UserDefaults.standard.removeObject(forKey: repositoryIDKey)
        inputDraft = ""
        lastConnectionIssue = nil
    }

    private nonisolated static func sameEndpoint(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs,
              let lhsParts = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let rhsParts = URLComponents(url: rhs, resolvingAgainstBaseURL: false) else { return false }
        return lhsParts.scheme?.lowercased() == rhsParts.scheme?.lowercased()
            && lhsParts.host?.lowercased() == rhsParts.host?.lowercased()
            && (lhsParts.port ?? 443) == (rhsParts.port ?? 443)
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL), let value = try? JSONDecoder().decode(SnapshotResponse.self, from: data) else { return }
        snapshot = value
        state = .offline(lastUpdated: value.fetchedAt)
        saveWidgetSnapshot(value)
    }

    private nonisolated static func readCachedDocument(at url: URL, expectedKey: String) async -> DocumentDetail? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  let detail = try? JSONDecoder().decode(DocumentDetail.self, from: data),
                  detail.documentKey == expectedKey,
                  MobileDocumentKey.all.contains(detail.documentKey) else { return nil }
            return detail
        }.value
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
            return MobilePendingDrafts(week: pendingWeekDraft, daily: pendingDailyDraft, deliveries: [], periods: [])
        }
        return value
    }

    private func loadDrafts() {
        let value = loadPendingDrafts()
        pendingWeekDraft = value.week
        pendingDailyDraft = value.daily
        pendingDeliveryCount = value.deliveries.count
        pendingDeliveryStates = Dictionary(value.deliveries.map { ($0.text, $0.isCompleted) }, uniquingKeysWith: { _, latest in latest })
        pendingPeriodCount = value.periods.count
        pendingPeriodStates = Dictionary(value.periods.map { ($0.key, $0.isCompleted) }, uniquingKeysWith: { _, latest in latest })
        legacyPendingToggleCount = value.deliveries.filter { $0.idempotencyKey == nil }.count
            + value.periods.filter(\.isLegacy).count
    }

    private func saveDrafts(_ value: MobilePendingDrafts? = nil) {
        let existing = loadPendingDrafts()
        let drafts = value ?? MobilePendingDrafts(
            week: pendingWeekDraft,
            daily: pendingDailyDraft,
            deliveries: existing.deliveries,
            periods: existing.periods
        )
        pendingWeekDraft = drafts.week
        pendingDailyDraft = drafts.daily
        pendingDeliveryCount = drafts.deliveries.count
        pendingDeliveryStates = Dictionary(drafts.deliveries.map { ($0.text, $0.isCompleted) }, uniquingKeysWith: { _, latest in latest })
        pendingPeriodCount = drafts.periods.count
        pendingPeriodStates = Dictionary(drafts.periods.map { ($0.key, $0.isCompleted) }, uniquingKeysWith: { _, latest in latest })
        legacyPendingToggleCount = drafts.deliveries.filter { $0.idempotencyKey == nil }.count
            + drafts.periods.filter(\.isLegacy).count
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
        saveWidgetSnapshot(value)
    }

    private func saveWidgetSnapshot(_ value: SnapshotResponse) {
        StudyRocketWidgetSnapshotStore.save(MobileWidgetSnapshotBuilder.make(from: value))
        #if os(iOS)
        WidgetCenter.shared.reloadTimelines(ofKind: StudyRocketWidgetConfiguration.kind)
        #endif
    }

    private func clearWidgetSnapshot() {
        StudyRocketWidgetSnapshotStore.remove()
        #if os(iOS)
        WidgetCenter.shared.reloadTimelines(ofKind: StudyRocketWidgetConfiguration.kind)
        #endif
    }

    private func periodKey(dayID: String, periodID: String) -> String { "\(dayID)|\(periodID)" }

    private func taskKey(dayID: String, periodID: String, taskID: String) -> String {
        "\(dayID)|\(periodID)|\(taskID)"
    }

    private func markChatUnavailable() {
        if let current = health {
            health = HealthResponse(
                apiVersion: current.apiVersion,
                hostVersion: current.hostVersion,
                repositoryBound: current.repositoryBound,
                codexReady: current.codexReady,
                pairedDeviceCount: current.pairedDeviceCount,
                activeThreadID: current.activeThreadID,
                repositoryID: current.repositoryID,
                dynamicToolsReady: false,
                chatState: StudyRocketChatState.unavailable.rawValue,
                chatIssueCode: current.chatIssueCode
            )
        }
        finishChatActivity()
    }
}

public struct StudyRocketRemoteError: LocalizedError {
    public let body: APIErrorBody
    public var errorDescription: String? { body.message }
}

public enum MobileEndpointError: LocalizedError {
    case invalidEndpoint
    case systemTailscaleRequired

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            if Self.simulatorLoopbackHTTPEnabled {
                return "Host 地址必须是无账号、查询参数和子路径的完整 HTTPS 地址；仅本机模拟器调试可使用 http://localhost:43817。"
            }
            return "Host 地址必须是无账号、查询参数和子路径的完整 HTTPS 地址。"
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

    static func accepts(_ url: URL, allowSimulatorLoopbackHTTP: Bool = simulatorLoopbackHTTPEnabled) -> Bool {
        let isSimpleHostAddress = url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
            && url.query == nil
            && url.fragment == nil
            && (url.path.isEmpty || url.path == "/")
        guard isSimpleHostAddress else { return false }

        if url.scheme?.lowercased() == "https" { return true }

        // The iOS Simulator runs on the Mac but cannot use its scoped
        // Tailscale MagicDNS resolver.  Keep this opt-in and exact so device
        // builds continue to require the Tailscale HTTPS endpoint.
        return allowSimulatorLoopbackHTTP
            && url.scheme?.lowercased() == "http"
            && url.host?.lowercased() == "localhost"
            && (url.port == nil || url.port == Int(StudyRocketAPI.defaultHostPort))
    }

    private static var simulatorLoopbackHTTPEnabled: Bool {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--studyrocket-simulator-loopback-http")
        #else
        return false
        #endif
    }
}

private enum MobileHostStateError: LocalizedError {
    case configurationUnavailable
    case incompatibleAPI(received: Int)
    case connectionChanged

    var errorDescription: String? {
        switch self {
        case .configurationUnavailable:
            return "Host 配置不可用：请确认仓库已绑定且 Mac 已安装 Codex。"
        case .incompatibleAPI(let received):
            return "Mac Host 协议版本不兼容（Host: \(received)，手机: \(StudyRocketAPI.version)），请同时更新两端。"
        case .connectionChanged:
            return "连接地址已更改，本次请求结果已丢弃。"
        }
    }
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
        guard result.apiVersion == StudyRocketAPI.version else {
            throw MobileHostStateError.incompatibleAPI(received: result.apiVersion)
        }
        deviceID = result.deviceID
        return result
    }

    public func snapshot(timeoutInterval: TimeInterval? = nil) async throws -> SnapshotResponse {
        try await get("/v1/snapshot", timeoutInterval: timeoutInterval, as: SnapshotResponse.self)
    }

    public func health() async throws -> HealthResponse {
        let value = try await get("/v1/health", as: HealthResponse.self)
        guard value.apiVersion == StudyRocketAPI.version else {
            throw MobileHostStateError.incompatibleAPI(received: value.apiVersion)
        }
        return value
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

    public func sendChat(text: String) async throws -> ChatHistoryResponse? {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/chat/send"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SendChatRequest(text: text))
        try authenticate(&request)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try? JSONDecoder().decode(ChatHistoryResponse.self, from: data)
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

    public func toggleDelivery(
        text: String,
        isCompleted: Bool,
        baseRevision: String,
        idempotencyKey: String,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> SnapshotResponse {
        try await post(
            "/v1/deliveries/toggle",
            body: DeliveryToggleRequest(
                text: text,
                isCompleted: isCompleted,
                metadata: WriteMetadata(baseRevision: baseRevision, idempotencyKey: idempotencyKey)
            ),
            timeoutInterval: timeoutInterval,
            as: SnapshotResponse.self
        )
    }

    public func togglePeriod(
        dayID: String,
        periodID: String,
        taskID: String,
        isCompleted: Bool,
        baseRevision: String,
        idempotencyKey: String = UUID().uuidString,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> SnapshotResponse {
        try await post(
            "/v1/periods/toggle",
            body: PeriodCompletionToggleRequest(
                dayID: dayID,
                periodID: periodID,
                taskID: taskID,
                isCompleted: isCompleted,
                metadata: WriteMetadata(baseRevision: baseRevision, idempotencyKey: idempotencyKey)
            ),
            timeoutInterval: timeoutInterval,
            as: SnapshotResponse.self
        )
    }

    public func saveDaily(entry: DailySnapshot, baseRevision: String) async throws -> SnapshotResponse {
        try await post("/v1/daily", body: DailyWriteRequest(entry: entry, metadata: WriteMetadata(baseRevision: baseRevision)), as: SnapshotResponse.self)
    }

    private func get<T: Decodable>(_ path: String, timeoutInterval: TimeInterval? = nil, as type: T.Type) async throws -> T {
        var request = URLRequest(url: endpoint.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "GET"
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
        try authenticate(&request)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(type, from: data)
    }

    private func post<T: Decodable, Body: Encodable>(
        _ path: String,
        body: Body,
        timeoutInterval: TimeInterval? = nil,
        as type: T.Type
    ) async throws -> T {
        var request = URLRequest(url: endpoint.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
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
        #if os(iOS) && !targetEnvironment(simulator)
        let signature = try RequestSigning.sign(privateKey: identity.secureEnclaveKey(), method: request.httpMethod ?? "GET", path: request.url?.path ?? "/", timestamp: timestamp, nonce: nonce, bodyHash: bodyHash)
        #else
        let signature = try RequestSigning.sign(privateKey: identity.softwareKey(), method: request.httpMethod ?? "GET", path: request.url?.path ?? "/", timestamp: timestamp, nonce: nonce, bodyHash: bodyHash)
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
            #if targetEnvironment(simulator)
            let signature = try RequestSigning.signAuthorization(privateKey: identity.softwareKey(), challenge: challenge.challenge)
            #else
            let signature = try RequestSigning.signAuthorization(privateKey: identity.secureEnclaveKey(), challenge: challenge.challenge)
            #endif
            return "\(challenge.challenge)|\(signature)"
        }
        #endif
        return UUID().uuidString
    }
}

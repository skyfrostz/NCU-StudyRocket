import Foundation
import StudyRocketShared
import StudyRocketWidgetSupport
#if os(iOS)
import LocalAuthentication
import Network
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
        case .unconfigured: return "尚未连接服务"
        case .connecting: return "正在连接服务"
        case .online: return "已连接服务"
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
    let deliveryID: String?
    let confirmedTaskIDs: [String]?
    var key: String { deliveryID ?? text }
    let text: String
    let isCompleted: Bool
    let idempotencyKey: String?

    init(text: String, isCompleted: Bool, idempotencyKey: String? = nil, deliveryID: String? = nil, confirmedTaskIDs: [String]? = nil) {
        self.deliveryID = deliveryID
        self.confirmedTaskIDs = confirmedTaskIDs
        self.text = text
        self.isCompleted = isCompleted
        self.idempotencyKey = idempotencyKey
    }
}

private struct PendingPeriodToggle: Codable, Equatable {
    let logicalTaskID: String?
    let assignmentID: String?
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
        idempotencyKey: String? = nil,
        logicalTaskID: String? = nil,
        assignmentID: String? = nil
    ) {
        self.logicalTaskID = logicalTaskID
        self.assignmentID = assignmentID
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
        case .sending: "正在将消息发送到 学业服务。"
        case .thinking: "学业助理正在分析你的问题。"
        case .responding: "回复会逐步显示在这里。"
        case .recovering: "连接仍在恢复，正在继续获取回复。"
        }
    }
}

private struct ActiveMobileChatRequest {
    let pendingID: String
    let text: String
    var attachmentIDs: [String] = []
    var turnID: String?
    var priorTurnIDs: Set<String> = []
    var operationID: String { String(pendingID.dropFirst("mobile-pending-".count)) }
}

private struct MobilePendingDrafts: Codable {
    var week: WeeklyPlanSnapshot?
    var events: [OneOffEvent]?
    var eventBaseHash: String?
    var weekBaseRevision: String?
    var daily: DailySnapshot?
    var dailyBaseRevision: String?
    var dailyOperationID: String?
    var deliveries: [PendingDeliveryToggle]
    var periods: [PendingPeriodToggle]

    init(week: WeeklyPlanSnapshot?, daily: DailySnapshot?, deliveries: [PendingDeliveryToggle], periods: [PendingPeriodToggle] = [], events: [OneOffEvent]? = nil, eventBaseHash: String? = nil, weekBaseRevision: String? = nil, dailyBaseRevision: String? = nil, dailyOperationID: String? = nil) {
        self.week = week
        self.events = events
        self.eventBaseHash = eventBaseHash
        self.weekBaseRevision = weekBaseRevision
        self.daily = daily
        self.dailyBaseRevision = dailyBaseRevision
        self.dailyOperationID = dailyOperationID
        self.deliveries = deliveries
        self.periods = periods
    }

    private enum CodingKeys: String, CodingKey { case week, daily, deliveries, periods, events, eventBaseHash, weekBaseRevision, dailyBaseRevision, dailyOperationID }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        week = try values.decodeIfPresent(WeeklyPlanSnapshot.self, forKey: .week)
        events = try values.decodeIfPresent([OneOffEvent].self, forKey: .events)
        eventBaseHash = try values.decodeIfPresent(String.self, forKey: .eventBaseHash)
        weekBaseRevision = try values.decodeIfPresent(String.self, forKey: .weekBaseRevision)
        daily = try values.decodeIfPresent(DailySnapshot.self, forKey: .daily)
        dailyBaseRevision = try values.decodeIfPresent(String.self, forKey: .dailyBaseRevision)
        dailyOperationID = try values.decodeIfPresent(String.self, forKey: .dailyOperationID)
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
    @Published public private(set) var retryingChat = false
    private var chatHistoryRequestSequence: UInt64 = 0
    private var appliedChatHistorySequence: UInt64 = 0
    private var chatTerminalReceipts: [String: ChatTurnTerminalDTO] = [:]
    private var failedChatAttachmentIDs: [String] = []
    private var resumingReplacement = false
    private var failedChatTurnID: String?
    private var failedChatPendingID: String?
    private var failedChatWasRejected = false
    @Published public private(set) var repositoryGeneration: UInt64 = 0
    @Published private(set) var isReplayingPendingToggles = false
    @Published private(set) var pendingToggleSyncIssue: String?
    @Published private(set) var legacyPendingToggleCount = 0
    @Published private(set) var legacyPendingReview: MobileLegacyPendingReview?
    /// Documents are fetched only after the user opens one of the allowlisted
    /// allowlisted summaries.  Keeping this separate from the snapshot keeps
    /// the home payload small and makes offline behaviour explicit.
    @Published public private(set) var documentDetails: [String: DocumentDetail] = [:]
    @Published private(set) var organization: MobileOrganizationWorkflow?
    @Published private(set) var isApplyingProposals = false
    @Published private(set) var proposalApplyOutcome: MobileProposalApplyOutcome?
    private var organizationStarting = false

    let chatDraftStore: MobileChatDraftStore
    @Published public var inputDraft = "" {
        didSet { UserDefaults.standard.set(inputDraft, forKey: "studyrocket.inputDraft"); chatDraftStore.setText(inputDraft) }
    }

    @Published public private(set) var archivedHistory: [CloudArchivedMessage] = []
    @Published public private(set) var archivedHistoryCursor: Int?
    @Published public private(set) var archivedHistoryLoaded = false
    @Published public private(set) var archivedHistoryLoading = false
    @Published public private(set) var archivedHistoryError: String?
    public var isCloudService: Bool { health?.backend == "cloud" }

    public func cloudVersions(after: Int = 0) async throws -> CloudVersionPage {
        guard let client else { throw MobileHostStateError.configurationUnavailable }
        let generation = clientGeneration
        let page = try await client.cloudVersions(after: after)
        guard generation == clientGeneration else { throw MobileHostStateError.connectionChanged }
        return page
    }
    public func cloudVersion(id: String, path: String) async throws -> CloudFileContent {
        guard let client else { throw MobileHostStateError.configurationUnavailable }
        let generation = clientGeneration
        let file = try await client.cloudVersion(id: id, path: path)
        guard generation == clientGeneration else { throw MobileHostStateError.connectionChanged }
        return file
    }

    public func loadArchivedHistory(reset: Bool = false) async {
        guard let client, !archivedHistoryLoading else { return }
        let generation = clientGeneration
        archivedHistoryLoading = true; archivedHistoryError = nil
        do {
            let page = try await client.archivedHistory(after: reset ? 0 : archivedHistoryCursor ?? 0)
            guard generation == clientGeneration else { return }
            if reset { archivedHistory = [] }
            archivedHistory.append(contentsOf: page.messages.filter { item in !archivedHistory.contains(where: { $0.id == item.id }) })
            archivedHistoryCursor = page.nextCursor; archivedHistoryLoaded = true
        } catch { if generation == clientGeneration { archivedHistoryError = error.localizedDescription } }
        if generation == clientGeneration { archivedHistoryLoading = false }
    }

    @Published public private(set) var refreshingConversation = false
    @Published public private(set) var conversationRefreshError: String?
    private var conversationTask: Task<Void, Never>?
    private var conversationToken = UUID()

    private struct QueuedFact: Codable {
        let repositoryID: String
        let endpoint: URL?
        let fact: QuickFact
    }
    @Published private var factQueue: [QueuedFact] = []
    @Published private(set) var factSyncError: String?
    private var factSyncToken: UUID?
    private let factsURL: URL
    var pendingFacts: [QuickFact] {
        factQueue.filter { queued in
            guard let current = clientEndpoint, queued.repositoryID == activeRepositoryID else { return false }
            return queued.endpoint == nil || Self.sameEndpoint(queued.endpoint, current)
        }.map(\.fact)
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
    private var observedChatTurnID: String?
    private var chatRecoveryTask: Task<Void, Never>?
    private var activeDeliveryMutations = Set<MobileDeliveryMutation>()
    private var completedDeliveryMutations: [MobileDeliveryMutation: MobileDeliveryToggleResult] = [:]
    // Scene lifetime is independent of endpoint/repository identity. An HTTP
    // response from a suspended scene must not restart its event stream.
    private var isForeground = true
    private var hasEnteredForeground = false
    private var foregroundGeneration = 0
    private var connectionRetryTask: Task<Void, Never>?
    private var connectionRetryToken: UUID?
    private var automaticRefreshBlocked = false
    private var lastRefreshWasTransient = false
    var connectionRetryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15)]
    #if os(iOS)
    private var networkMonitor: NWPathMonitor?
    #endif
    private var lastNetworkPathAvailable: Bool?
    var isEventStreamRunning: Bool { eventsTask != nil }
    private var refreshTask: Task<Void, Never>?
    private var refreshTaskToken: UUID?
    @Published public private(set) var isRefreshingSnapshot = false
    private var pendingSynchronizationTask: Task<Void, Never>?
    private var pendingSynchronizationToken: UUID?
    private var pendingReplayTask: Task<Void, Never>?
    private var pendingReplayToken: UUID?
    private var legacyReviewDeferred = false
    private var snapshotInvalidationTask: Task<Void, Never>?
    private var snapshotInvalidationToken: UUID?
    private var pendingSnapshotInvalidation: Date?
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
        chatDraftStore = MobileChatDraftStore(root: base.appendingPathComponent("chat-drafts", isDirectory: true))
        factsURL = base.appendingPathComponent("pending-facts.json")
        cacheURL = base.appendingPathComponent("snapshot.json")
        draftsURL = base.appendingPathComponent("pending-drafts.json")
        documentsURL = base.appendingPathComponent("documents", isDirectory: true)
        self.eventStreamsEnabled = eventStreamsEnabled
        self.chatRecoveryDelays = chatRecoveryDelays.isEmpty ? [.seconds(2)] : chatRecoveryDelays
        inputDraft = UserDefaults.standard.string(forKey: "studyrocket.inputDraft") ?? ""
        activeRepositoryID = UserDefaults.standard.string(forKey: repositoryIDKey)
        chatDraftStore.bind(repository: activeRepositoryID, fallbackText: inputDraft)
        inputDraft = chatDraftStore.text
        if let data = try? Data(contentsOf: factsURL) {
            do { factQueue = try JSONDecoder().decode([QueuedFact].self, from: data) }
            catch { factSyncError = "无法读取本机记录草稿，请保留缓存。" }
        }
        loadCache()
        loadDrafts()
        reloadPreservedQueues()
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

    public struct PreservedQueue: Codable, Identifiable {
        public let id: UUID
        public let createdAt: Date
        public let endpoint: URL?
        public let repositoryID: String?
        public let drafts: Data?
        public let facts: Data?
        public let chats: Data?
        public let cachedSnapshot: Data?
        public let input: String
    }

    @Published public private(set) var preservedQueues: [PreservedQueue] = []
    private var queueArchiveURL: URL { draftsURL.deletingLastPathComponent().appendingPathComponent("preserved-queues", isDirectory: true) }

    /// Switching service never destroys an unsent operation. Archive bytes are verified
    /// before any endpoint, repository identity or active draft file can change.
    private func preserveCurrentQueue() throws {
        let drafts = try FileManager.default.fileExists(atPath: draftsURL.path) ? Data(contentsOf: draftsURL) : nil
        let facts = try FileManager.default.fileExists(atPath: factsURL.path) ? Data(contentsOf: factsURL) : nil
        let chats = try FileManager.default.fileExists(atPath: cloudChatsURL.path) ? Data(contentsOf: cloudChatsURL) : nil
        guard drafts != nil || facts != nil || chats != nil || !inputDraft.isEmpty else { return }
        let archive = PreservedQueue(id: UUID(), createdAt: .now, endpoint: clientEndpoint,
            repositoryID: activeRepositoryID, drafts: drafts, facts: facts, chats: chats,
            cachedSnapshot: try FileManager.default.fileExists(atPath: cacheURL.path) ? Data(contentsOf: cacheURL) : nil, input: inputDraft)
        try FileManager.default.createDirectory(at: queueArchiveURL, withIntermediateDirectories: true)
        let target = queueArchiveURL.appendingPathComponent(archive.id.uuidString + ".json")
        let encoded = try JSONEncoder().encode(archive)
        try encoded.write(to: target, options: .atomic)
        guard try Data(contentsOf: target) == encoded else { throw CocoaError(.fileWriteUnknown) }
        reloadPreservedQueues()
    }

    public func reloadPreservedQueues() {
        preservedQueues = ((try? FileManager.default.contentsOfDirectory(at: queueArchiveURL, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? JSONDecoder().decode(PreservedQueue.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func preservedQueueText(_ archive: PreservedQueue) -> String {
        var parts = ["原服务：" + (archive.endpoint?.absoluteString ?? "待核实"), "原仓库：" + (archive.repositoryID ?? "待核实")]
        if !archive.input.isEmpty { parts.append("未发送文字：\n" + archive.input) }
        for (name, data) in [("计划与勾选原始草稿", archive.drafts), ("记录原始草稿", archive.facts), ("未确认对话", archive.chats)] {
            if let data, let value = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
               let text = String(data: pretty, encoding: .utf8) { parts.append(name + "：\n" + text) }
        }
        return parts.joined(separator: "\n\n")
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

    var supportsChatAttachments: Bool { health?.capabilities?.contains("chat-attachments") == true }
    var supportsTargetedInterrupt: Bool { health?.capabilities?.contains("targeted-interrupt") == true }

    public var canViewProposals: Bool { state == .online && client != nil }
    public var canApplyProposals: Bool { canViewProposals && snapshot != nil && !proposals.isEmpty }

    public var chatUnavailableMessage: String? {
        guard state == .online, let health else { return nil }
        if health.chatIssueCode == "provider_auth_failed" || lastChatIssueCode == "provider_auth_failed" {
            return health.backend == "cloud" ? "云模型服务认证失败，请检查服务端凭据；输入和草稿已保留。" : "Codex 身份验证已失效。请在 Mac 上重新登录 Codex，然后重新打开 StudyRocket Host。"
        }
        guard !isChatAvailable else { return nil }
        return "学业对话尚未就绪。学业服务 会继续重试协议自检；首页、计划和勾选仍可用。"
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
        do {
            try replaceClient(with: StudyRocketRemoteClient(endpoint: endpoint), endpoint: endpoint, persistEndpoint: false)
            Task { await refresh() }
        } catch { lastConnectionIssue = "未切换服务：无法备份待提交草稿。"; state = .failed(lastConnectionIssue!) }
    }

    public func pair(endpoint: URL, code: String, deviceName: String) async throws {
        guard MobileEndpointError.accepts(endpoint) else { throw MobileEndpointError.invalidEndpoint }
        pairAttemptGeneration &+= 1
        let attemptGeneration = pairAttemptGeneration
        let remote = StudyRocketRemoteClient(endpoint: endpoint)
        do {
            // Pair first: public health intentionally does not reveal repository UUID,
            // and a device ID from another service must not block new pairing.
            let response = try await remote.pair(code: code, deviceName: deviceName)
            let candidateHealth = try await remote.health(timeoutInterval: 8)
            guard attemptGeneration == pairAttemptGeneration else { throw MobileHostStateError.connectionChanged }
            try replaceClient(with: remote, endpoint: endpoint, persistEndpoint: true, incomingRepositoryID: candidateHealth.repositoryID)
            UserDefaults.standard.set(response.deviceID, forKey: "studyrocket.deviceID")
        } catch {
            throw MobileEndpointError.contextualized(error)
        }
        await refresh()
    }

    /// Called synchronously by scene changes so a queued activation cannot
    /// overtake a later background event before its refresh Task starts.
    public func foregroundDidChange(isActive: Bool) {
        guard isActive else { leaveForeground(); return }
        guard let lifecycle = prepareForeground() else { return }
        Task { [weak self] in await self?.refreshForeground(lifecycle: lifecycle) }
    }

    public func enterForeground() async {
        guard let lifecycle = prepareForeground() else {
            if let refreshTask { await refreshTask.value }
            return
        }
        await refreshForeground(lifecycle: lifecycle)
    }

    private func prepareForeground() -> Int? {
        guard !hasEnteredForeground || !isForeground else { return nil }
        hasEnteredForeground = true
        isForeground = true
        foregroundGeneration &+= 1
        if client != nil { state = .connecting }
        startNetworkMonitoring()
        return foregroundGeneration
    }

    private func refreshForeground(lifecycle: Int) async {
        guard isForeground, foregroundGeneration == lifecycle else { return }
        await refresh()
        guard isForeground, foregroundGeneration == lifecycle else { return }
        await refreshOrganization()
    }

    public func leaveForeground() {
        isForeground = false
        foregroundGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskToken = nil
        isRefreshingSnapshot = false
        cancelPendingSynchronization()
        pendingReplayTask?.cancel()
        pendingReplayTask = nil
        pendingReplayToken = nil
        isReplayingPendingToggles = false
        cancelConnectionRetry()
        stopEventStream()
        #if os(iOS)
        networkMonitor?.cancel()
        networkMonitor = nil
        #endif
        lastNetworkPathAvailable = nil
    }

    private func startNetworkMonitoring() {
        #if os(iOS)
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        let generation = foregroundGeneration
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.foregroundGeneration == generation else { return }
                self.networkPathChanged(isAvailable: available)
            }
        }
        monitor.start(queue: DispatchQueue(label: "StudyRocket.network-path"))
        #endif
    }

    // A path is only a reason to probe. It never establishes HTTP availability.
    func networkPathChanged(isAvailable: Bool) {
        let previous = lastNetworkPathAvailable
        lastNetworkPathAvailable = isAvailable
        guard isForeground, previous == false, isAvailable,
              !automaticRefreshBlocked else { return }
        cancelConnectionRetry()
        Task { [weak self] in await self?.refresh() }
    }

    public func refresh() async { await refresh(isRetry: false) }

    /// Pull-to-refresh ends when authoritative reads finish. Queued writes keep
    /// their own supervised task and visible pending/synchronizing indicators.
    public func refreshVisibleContent() async {
        await refresh(isRetry: false, showsChecking: false, waitForPendingChanges: false)
    }

    private func refresh(isRetry: Bool, showsChecking: Bool = true, waitForPendingChanges: Bool = true) async {
        guard isForeground else { return }
        if let refreshTask {
            let joinedToken = refreshTaskToken
            await refreshTask.value
            if let joinedToken { finishSnapshotRefresh(token: joinedToken, isRetry: isRetry) }
            if waitForPendingChanges, let pendingSynchronizationTask { await pendingSynchronizationTask.value }
            return
        }
        if !isRetry { cancelConnectionRetry() }
        let token = UUID()
        let lifecycle = foregroundGeneration
        let endpoint = clientGeneration
        let previousState = state
        // Manual pulls use their native spinner and leave connection status
        // untouched until the authoritative read succeeds or fails.
        if showsChecking, client != nil, state != .online { state = .connecting }
        isRefreshingSnapshot = true
        let task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.isForeground,
                  lifecycle == self.foregroundGeneration,
                  endpoint == self.clientGeneration else { return }
            await self.performRefresh(lifecycle: lifecycle, previousState: previousState)
        }
        refreshTaskToken = token
        refreshTask = task
        await task.value
        finishSnapshotRefresh(token: token, isRetry: isRetry)
        if waitForPendingChanges, let pendingSynchronizationTask { await pendingSynchronizationTask.value }
    }

    private func finishSnapshotRefresh(token: UUID, isRetry: Bool) {
        guard refreshTaskToken == token else { return }
        refreshTask = nil
        refreshTaskToken = nil
        isRefreshingSnapshot = false
        if !isRetry, lastRefreshWasTransient { scheduleConnectionRetry() }
        if state == .online { startPendingSynchronization() }
    }

    private func startPendingSynchronization() {
        guard isForeground, state == .online, pendingSynchronizationTask == nil else { return }
        let token = UUID(), endpoint = clientGeneration, lifecycle = foregroundGeneration
        pendingSynchronizationToken = token
        pendingSynchronizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.pendingSynchronizationToken == token {
                    self.pendingSynchronizationTask = nil
                    self.pendingSynchronizationToken = nil
                }
            }
            await self.syncFacts()
            guard !Task.isCancelled, self.isForeground,
                  endpoint == self.clientGeneration, lifecycle == self.foregroundGeneration else { return }
            self.prepareLegacyPendingReviewIfNeeded()
            if self.legacyPendingToggleCount == 0 { await self.replayPendingToggles() }
        }
    }

    private func cancelPendingSynchronization() {
        pendingSynchronizationTask?.cancel()
        pendingSynchronizationTask = nil
        pendingSynchronizationToken = nil
    }

    private func cancelConnectionRetry() {
        connectionRetryTask?.cancel()
        connectionRetryTask = nil
        connectionRetryToken = nil
    }

    private func scheduleConnectionRetry() {
        guard isForeground, !automaticRefreshBlocked, connectionRetryTask == nil else { return }
        let token = UUID(), lifecycle = foregroundGeneration, endpoint = clientGeneration
        connectionRetryToken = token
        let delays = connectionRetryDelays
        connectionRetryTask = Task { [weak self] in
            for delay in delays {
                do { try await Task.sleep(for: delay) } catch { break }
                guard let self, !Task.isCancelled, self.isForeground,
                      lifecycle == self.foregroundGeneration, endpoint == self.clientGeneration,
                      !self.automaticRefreshBlocked else { break }
                await self.refresh(isRetry: true)
                if !self.lastRefreshWasTransient { break }
            }
            if let self, self.connectionRetryToken == token {
                self.connectionRetryTask = nil
                self.connectionRetryToken = nil
            }
        }
    }

    private func performRefresh(lifecycle: Int, previousState: MobileConnectionState) async {
        lastRefreshWasTransient = false
        guard let client else {
            if snapshot == nil { state = .unconfigured }
            return
        }
        var generation = clientGeneration
        func isCurrent() -> Bool {
            !Task.isCancelled && isForeground && lifecycle == foregroundGeneration && generation == clientGeneration
        }
        do {
            let health = try await client.health(timeoutInterval: 8)
            guard isCurrent() else { return }
            if let incomingRepositoryID = health.repositoryID,
               let activeRepositoryID,
               incomingRepositoryID != activeRepositoryID {
                try preserveCurrentQueue()
                stopEventStream()
                clientGeneration &+= 1
                generation = clientGeneration
                advanceRepositoryGeneration()
                clearRemoteHostState()
            }
            if activeRepositoryID != health.repositoryID {
                chatDraftStore.bind(repository: health.repositoryID)
                inputDraft = chatDraftStore.text
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
            guard health.repositoryBound else { throw MobileHostStateError.configurationUnavailable }
            let revisionBeforeRead = snapshot?.revision
            let value = try await client.snapshot(timeoutInterval: 12)
            guard isCurrent() else { return }
            // A queued write may have received a newer authoritative receipt
            // while this read was in flight. Never roll that receipt back.
            let canAdoptRead = snapshot?.revision == revisionBeforeRead
            if canAdoptRead { snapshot = value }
            state = .online
            automaticRefreshBlocked = false
            reconnectFailures = 0
            lastConnectionIssue = nil
            if canAdoptRead { saveCache(value) }
            startEventStream()
        } catch {
            guard isCurrent() else { return }
            if Self.isRequestCancellation(error) { state = previousState; return }
            let contextualized = MobileEndpointError.contextualized(error)
            lastConnectionIssue = contextualized.localizedDescription
            state = connectionFailureState(for: contextualized)
            automaticRefreshBlocked = isAuthenticationOrConfigurationFailure(contextualized)
            if automaticRefreshBlocked { stopEventStream() }
            if let remote = error as? StudyRocketRemoteError {
                lastRefreshWasTransient = remote.body.retryable && !automaticRefreshBlocked
            }
            if let urlError = error as? URLError {
                lastRefreshWasTransient = [.timedOut, .cannotFindHost, .cannotConnectToHost,
                    .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet,
                    .resourceUnavailable].contains(urlError.code)
            }
        }
    }

    private struct PendingCloudChat: Codable {
        let id: String
        let text: String
        var attachmentIDs: [String]? = nil
        var terminalReadOperationID: String? = nil
        let endpoint: URL?
        let repositoryID: String?
    }
    private var cloudChatsURL: URL { draftsURL.deletingLastPathComponent().appendingPathComponent("pending-cloud-chats.json") }
    private func persistedChatID(for text: String, attachmentIDs: [String] = [], requestedID: String? = nil) throws -> String {
        var entries = (try? JSONDecoder().decode([PendingCloudChat].self, from: Data(contentsOf: cloudChatsURL))) ?? []
        if let found = entries.first(where: { (requestedID == nil ? $0.text == text && ($0.attachmentIDs ?? []) == attachmentIDs : $0.id == requestedID) && $0.endpoint == clientEndpoint && $0.repositoryID == activeRepositoryID }) { return found.id }
        let entry = PendingCloudChat(id: requestedID ?? UUID().uuidString, text: text, attachmentIDs: attachmentIDs, endpoint: clientEndpoint, repositoryID: activeRepositoryID)
        entries.append(entry)
        try FileManager.default.createDirectory(at: cloudChatsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: cloudChatsURL, options: .atomic)
        return entry.id
    }
    private func terminalReadOperationID(for id: String) throws -> String {
        var entries = try JSONDecoder().decode([PendingCloudChat].self, from: Data(contentsOf: cloudChatsURL))
        guard let index = entries.firstIndex(where: { $0.id == id && $0.endpoint == clientEndpoint && $0.repositoryID == activeRepositoryID }) else { throw URLError(.cannotParseResponse) }
        if let value = entries[index].terminalReadOperationID { return value }
        let value = UUID().uuidString
        entries[index].terminalReadOperationID = value
        try JSONEncoder().encode(entries).write(to: cloudChatsURL, options: .atomic)
        return value
    }

    private func beginChatHistoryRequest() -> UInt64 {
        chatHistoryRequestSequence &+= 1
        return chatHistoryRequestSequence
    }

    private func completePersistedChat(id: String?) {
        guard let id, let data = try? Data(contentsOf: cloudChatsURL),
              let entries = try? JSONDecoder().decode([PendingCloudChat].self, from: data) else { return }
        let remaining = entries.filter { !($0.id == id && $0.endpoint == clientEndpoint && $0.repositoryID == activeRepositoryID) }
        guard remaining.count != entries.count else { return }
        try? JSONEncoder().encode(remaining).write(to: cloudChatsURL, options: .atomic)
    }

    public func sendDraft() async {
        guard !retryingChat else { return }
        let text = inputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = chatDraftStore.attachments
        guard attachments.isEmpty || chatDraftStore.ready else { chatDraftStore.issue = "请等待附件上传完成，或重试失败的附件。"; return }
        let attachmentIDs = attachments.compactMap(\.remoteID)
        if isChatBusy { await queueReplacement(text: text, attachmentIDs: attachmentIDs); return }
        if chatDraftStore.replacement != nil { await resumePendingReplacement(); return }
        // A saved operation without a terminal receipt is not a new message.
        if let data = try? Data(contentsOf: cloudChatsURL),
           let entries = try? JSONDecoder().decode([PendingCloudChat].self, from: data),
           let pending = entries.first(where: { $0.text == text && ($0.attachmentIDs ?? []) == attachmentIDs && $0.endpoint == clientEndpoint && $0.repositoryID == activeRepositoryID }) {
            lastFailedChatText = text
            let pendingID = "mobile-pending-" + pending.id
            if failedChatPendingID != pendingID { failedChatTurnID = nil; failedChatWasRejected = false }
            failedChatPendingID = pendingID
            await retryFailedChat()
            return
        }
        await sendChatText(text, attachmentIDs: attachmentIDs)
    }

    func isFailedChatMessage(_ message: ChatMessageDTO) -> Bool {
        guard message.role == "user", message.text == lastFailedChatText else { return false }
        if let failedChatTurnID { return message.turnID == failedChatTurnID }
        if let activeChatRequest, activeChatRequest.pendingID == failedChatPendingID,
           let turnID = activeChatRequest.turnID { return message.turnID == turnID }
        return message.id == failedChatPendingID
    }

    /// Explicit retry always reconciles the authoritative history before POST.
    /// Missing history is not evidence that an operation was never accepted.
    public func retryFailedChat() async {
        guard !retryingChat, let text = lastFailedChatText, let client else { return }
        let generation = clientGeneration
        let repository = repositoryGeneration
        let failedTurn = failedChatTurnID
        let rejected = failedChatWasRejected
        let rejectedPendingID = failedChatPendingID
        retryingChat = true
        defer { if generation == clientGeneration, repository == repositoryGeneration { retryingChat = false } }
        let historySequence = beginChatHistoryRequest()
        do {
            let history = try await client.chatHistory()
            guard generation == clientGeneration, repository == repositoryGeneration, historySequence >= appliedChatHistorySequence, !Task.isCancelled else { return }
            let pending = (try? Data(contentsOf: cloudChatsURL)).flatMap { try? JSONDecoder().decode([PendingCloudChat].self, from: $0) }?
                .first(where: { $0.text == text && $0.endpoint == clientEndpoint && $0.repositoryID == activeRepositoryID })
            // An unresolved operation wins over an older same-text failure.
            // Only a proven binding may translate a Host operation to its turn.
            let boundTurn = activeChatRequest.flatMap { request in
                pending?.id == request.operationID ? request.turnID : nil
            }
            let turnID = pending.map { boundTurn ?? $0.id } ?? failedTurn
            let confirmedRejection = pending.map { rejected && "mobile-pending-" + $0.id == rejectedPendingID } ?? false
            let terminal = history.terminalTurns?.last(where: { $0.turnID == turnID })
            let status = terminal?.status ?? history.messages.last(where: { $0.turnID == turnID })?.status
                ?? turnID.flatMap { chatTerminalReceipts[$0]?.status }
            mergeHistory(history, requestSequence: historySequence)
            if status == "completed" {
                completePersistedChat(id: pending?.id ?? turnID)
                lastFailedChatText = nil
                lastChatIssue = nil
                return
            }
            guard status == "failed" || status == "interrupted" || (confirmedRejection && status == nil) else {
                if let pending, health?.backend == "cloud" {
                    do {
                        let operation = try await client.operationStatus(id: pending.id)
                        guard generation == clientGeneration, repository == repositoryGeneration else { return }
                        if ["succeeded", "failed", "interrupted"].contains(operation.state), supportsTargetedInterrupt {
                            let readID = try terminalReadOperationID(for: pending.id)
                            let receipt = try await client.interruptChat(turnID: pending.id, operationID: readID)
                            guard generation == clientGeneration, repository == repositoryGeneration else { return }
                            if let terminal = receipt.terminal {
                                settleRecoveredChat(pending, terminal: terminal)
                                return // Failure remains an explicit second retry, never an automatic send.
                            }
                        }
                    }
                    catch {
                        guard generation == clientGeneration, repository == repositoryGeneration else { return }
                        if let remote = error as? StudyRocketRemoteError, remote.body.code == "operation_not_found" {
                            if activeChatRequest?.operationID == pending.id { finishChatActivity() }
                            guard !isChatBusy else { return }
                            chatMessages.removeAll { $0.id == "mobile-pending-" + pending.id }
                            await sendChatText(pending.text, clearComposer: false, requestedID: pending.id, attachmentIDs: pending.attachmentIDs ?? [])
                            return
                        }
                    }
                }
                guard generation == clientGeneration, repository == repositoryGeneration else { return }
                lastChatIssue = "正在核对原消息的远端状态，尚未确认结果；没有重复发送。"
                return
            }
            guard !isChatBusy else { return }
            completePersistedChat(id: pending?.id ?? turnID)
            if let pending { chatMessages.removeAll { $0.id == "mobile-pending-" + pending.id } }
            let attachmentIDs = pending?.attachmentIDs ?? history.messages.first(where: { $0.role == "user" && $0.turnID == turnID })?.attachments?.map(\.id) ?? failedChatAttachmentIDs
            await sendChatText(text, clearComposer: false, attachmentIDs: attachmentIDs)
        } catch {
            guard generation == clientGeneration, repository == repositoryGeneration, historySequence >= appliedChatHistorySequence, !Self.isRequestCancellation(error) else { return }
            lastChatIssue = "无法核对原消息的远端状态，未重复发送：" + error.localizedDescription
        }
    }

    private func settleRecoveredChat(_ pending: PendingCloudChat, terminal: ChatTurnTerminalDTO) {
        let pendingID = "mobile-pending-" + pending.id
        if let index = chatMessages.firstIndex(where: { $0.id == pendingID }) {
            let old = chatMessages[index]
            chatMessages[index] = ChatMessageDTO(id: old.id, role: old.role, text: old.text, date: old.date,
                turnID: pending.id, phase: old.phase, status: terminal.status, attachments: old.attachments)
        } else if terminal.status != "completed", !chatMessages.contains(where: { $0.role == "user" && $0.turnID == pending.id }) {
            chatMessages.append(ChatMessageDTO(id: pendingID, role: "user", text: pending.text, date: .now, turnID: pending.id, status: terminal.status))
        }
        applyTerminal(terminal)
        completePersistedChat(id: pending.id)
        if terminal.status == "completed" {
            if lastFailedChatText == pending.text { lastFailedChatText = nil; lastChatIssue = nil; lastChatIssueCode = nil }
        } else {
            failedChatTurnID = pending.id; failedChatPendingID = pendingID; failedChatWasRejected = false
            failedChatAttachmentIDs = pending.attachmentIDs ?? []
            lastFailedChatText = pending.text
            setChatIssue(code: terminal.issueCode, message: terminal.message ?? "原消息未完成，可以重试这条消息。")
        }
        chatRevision &+= 1
    }

    private func sendChatText(_ text: String, clearComposer: Bool = true, requestedID: String? = nil, attachmentIDs: [String] = []) async {
        guard !text.isEmpty || !attachmentIDs.isEmpty, let client else { return }
        guard isChatAvailable else { return }
        guard attachmentIDs.isEmpty || supportsChatAttachments else { lastChatIssue = "当前学业服务尚不支持附件，请更新服务后再发送；草稿已保留。"; return }
        guard !isChatBusy else { return }
        let generation = clientGeneration
        let requestID: String
        do { requestID = try persistedChatID(for: text, attachmentIDs: attachmentIDs, requestedID: requestedID) }
        catch { lastChatIssue = "无法持久保存发送草稿，请保留文字后重试。"; return }
        let historySequence = beginChatHistoryRequest()
        let pendingID = "mobile-pending-" + requestID
        activeChatRequest = ActiveMobileChatRequest(pendingID: pendingID, text: text, attachmentIDs: attachmentIDs,
            turnID: health?.backend == "cloud" ? requestID : nil,
            priorTurnIDs: Set(chatMessages.compactMap(\.turnID)))
        observedChatTurnID = nil
        isChatBusy = true
        chatProgress = .sending
        lastChatIssue = nil
        lastChatIssueCode = nil
        lastFailedChatText = nil
        failedChatTurnID = nil
        failedChatPendingID = nil
        failedChatWasRejected = false
        let attachmentMetadata = (chatDraftStore.attachments + (chatDraftStore.replacement?.attachments ?? [])).filter { attachmentIDs.contains($0.remoteID ?? "") }.compactMap(\.remoteMetadata)
        chatMessages.append(ChatMessageDTO(id: pendingID, role: "user", text: text, date: .now, status: "inProgress", attachments: attachmentMetadata.isEmpty ? nil : attachmentMetadata))
        chatRevision &+= 1
        do {
            let acceptedHistory = try await client.sendChat(text: text, clientRequestID: requestID, attachmentIDs: attachmentIDs)
            guard generation == clientGeneration,
                  activeChatRequest?.pendingID == pendingID else { return }
            if clearComposer && inputDraft.trimmingCharacters(in: .whitespacesAndNewlines) == text { inputDraft = "" }
            let sentItems = chatDraftStore.attachments + (chatDraftStore.replacement?.attachments ?? [])
            chatDraftStore.markSent(ids: sentItems.filter { attachmentIDs.contains($0.remoteID ?? "") }.map(\.id), frozen: chatDraftStore.replacement?.attachments ?? [])
            if chatDraftStore.replacement?.id == requestID {
                chatDraftStore.replacement = nil; try? chatDraftStore.save()
            }
            if let acceptedHistory {
                if !acceptedHistory.messages.isEmpty {
                    mergeHistory(acceptedHistory, requestSequence: historySequence)
                } else {
                    // An acceptance receipt is not an instruction to erase the
                    // visible conversation while authoritative history loads.
                    reconcileChatActivity(with: chatMessages, terminals: acceptedHistory.terminalTurns ?? [])
                }
            }
            if isChatBusy {
                if chatProgress != .responding { chatProgress = .thinking }
                startChatRecovery(generation: generation)
            }
        } catch {
            guard generation == clientGeneration,
                  activeChatRequest?.pendingID == pendingID else { return }
            failedChatPendingID = pendingID
            let rejected = (error as? StudyRocketRemoteError).map {
                ["codex_starting", "provider_auth_failed", "invalid_chat", "chat_busy"].contains($0.body.code)
            } ?? false
            if !rejected {
                // Cancellation does not tell us whether the server accepted the
                // send. Keep its original ID and resolve it through history only.
                chatProgress = .recovering
                if !Self.isRequestCancellation(error) {
                    lastFailedChatText = text
                    lastChatIssueCode = (error as? StudyRocketRemoteError)?.body.code
                    lastChatIssue = error.localizedDescription + "；发送回执未确认，正在核对远端状态。"
                }
                startChatRecovery(generation: generation)
                return
            }
            lastFailedChatText = text
            failedChatWasRejected = true
            if let index = chatMessages.firstIndex(where: { $0.id == pendingID }) {
                let pending = chatMessages[index]
                chatMessages[index] = ChatMessageDTO(id: pending.id, role: pending.role, text: pending.text, date: pending.date, turnID: pending.turnID, phase: pending.phase, status: "failed", attachments: pending.attachments)
                chatRevision &+= 1
            }
            if let remoteError = error as? StudyRocketRemoteError, remoteError.body.code == "codex_starting" {
                markChatUnavailable()
            } else {
                finishChatActivity(issue: error.localizedDescription, issueCode: (error as? StudyRocketRemoteError)?.body.code)
            }
        }
    }

    private func queueReplacement(text: String, attachmentIDs: [String]) async {
        guard supportsTargetedInterrupt else { lastChatIssue = "当前学业服务尚不支持定向停止，请等待回复结束后发送。"; return }
        guard attachmentIDs.isEmpty || supportsChatAttachments else { lastChatIssue = "当前学业服务尚不支持附件，草稿已保留。"; return }
        guard chatDraftStore.replacement == nil, !text.isEmpty || !attachmentIDs.isEmpty else { return }
        guard let target = activeChatRequest?.turnID ?? observedChatTurnID else {
            lastChatIssue = "正在核对当前回复，请稍后再次发送。"; await refreshChat(); return
        }
        var pending = MobilePendingReplacement(id: UUID().uuidString, text: text, attachmentIDs: attachmentIDs, oldTurnID: target)
        let frozenAttachments = chatDraftStore.attachments
        pending.attachments = frozenAttachments
        chatDraftStore.replacement = pending
        chatDraftStore.attachments = []
        do { try chatDraftStore.save(text: "") }
        catch {
            chatDraftStore.replacement = nil; chatDraftStore.attachments = frozenAttachments
            lastChatIssue = "新消息尚未保存，未停止当前回复。"; return
        }
        if inputDraft.trimmingCharacters(in: .whitespacesAndNewlines) == text { inputDraft = "" }
        await resumePendingReplacement()
    }

    func resumePendingReplacement() async {
        guard !resumingReplacement, var pending = chatDraftStore.replacement, let client else { return }
        guard supportsTargetedInterrupt, pending.attachmentIDs.isEmpty || supportsChatAttachments else { lastChatIssue = "当前学业服务需要更新，新消息已保留。"; return }
        // Older draft schemas omitted these identities. Migrate and persist
        // before any network request; never reuse the send ID for a stop/read.
        if pending.stopOperationID == nil || pending.terminalReadOperationID == nil {
            if pending.stopOperationID == nil { pending.stopOperationID = UUID().uuidString }
            if pending.terminalReadOperationID == nil { pending.terminalReadOperationID = UUID().uuidString }
            chatDraftStore.replacement = pending
            do { try chatDraftStore.save() }
            catch { lastChatIssue = "回复核对编号未能保存，未发送网络请求。"; return }
        }
        guard let stopOperationID = pending.stopOperationID, let terminalReadOperationID = pending.terminalReadOperationID else { return }
        resumingReplacement = true
        let generation = clientGeneration, repository = repositoryGeneration
        defer { resumingReplacement = false }
        do {
            if !pending.submitted && pending.oldTerminal == nil {
                // A typed terminal receipt remains authoritative even when the
                // target has fallen outside the bounded recent-history window.
                let receipt = try await client.interruptChat(turnID: pending.oldTurnID, operationID: stopOperationID)
                guard generation == clientGeneration, repository == repositoryGeneration, chatDraftStore.replacement?.id == pending.id else { return }
                if let terminal = receipt.terminal {
                    pending.oldTerminal = terminal
                    chatDraftStore.replacement = pending
                    try chatDraftStore.save()
                }
            }
            let historySequence = beginChatHistoryRequest()
            let history = try await client.chatHistory()
            guard generation == clientGeneration, repository == repositoryGeneration, historySequence >= appliedChatHistorySequence, chatDraftStore.replacement?.id == pending.id else { return }
            if pending.submitted {
                mergeHistory(history, requestSequence: historySequence)
                if history.messages.contains(where: { $0.turnID == pending.id }) || history.terminalTurns?.contains(where: { $0.turnID == pending.id }) == true {
                    chatDraftStore.markSent(ids: pending.attachments?.map(\.id) ?? [], frozen: pending.attachments ?? [])
                    chatDraftStore.replacement = nil; try chatDraftStore.save()
                    return
                }
                do {
                    let operation = try await client.operationStatus(id: pending.id)
                    guard generation == clientGeneration, repository == repositoryGeneration, chatDraftStore.replacement?.id == pending.id else { return }
                    if ["succeeded", "failed", "interrupted"].contains(operation.state) {
                        let receipt = try await client.interruptChat(turnID: pending.id, operationID: terminalReadOperationID)
                        guard generation == clientGeneration, repository == repositoryGeneration, chatDraftStore.replacement?.id == pending.id else { return }
                        if let terminal = receipt.terminal {
                            applyTerminal(terminal)
                            completePersistedChat(id: pending.id)
                            chatDraftStore.markSent(ids: pending.attachments?.map(\.id) ?? [], frozen: pending.attachments ?? [])
                            chatDraftStore.replacement = nil; try chatDraftStore.save()
                            if terminal.status == "failed" { lastFailedChatText = pending.text; failedChatTurnID = pending.id }
                            return
                        }
                    }
                    lastChatIssue = "新消息已到达服务，正在等待权威回复，未重复发送。"
                    return
                } catch {
                    guard let remote = error as? StudyRocketRemoteError, remote.body.code == "operation_not_found" else { throw error }
                    guard generation == clientGeneration, repository == repositoryGeneration,
                          chatDraftStore.replacement?.id == pending.id else { return }
                    // Only explicit absence from the operation journal permits
                    // reusing the exact frozen request after a crash before POST.
                    if activeChatRequest?.operationID == pending.id { finishChatActivity() }
                }
            }
            let status = pending.oldTerminal?.status ?? history.terminalTurns?.last(where: { $0.turnID == pending.oldTurnID })?.status
                ?? history.messages.last(where: { $0.turnID == pending.oldTurnID })?.status
            if let terminal = pending.oldTerminal { applyTerminal(terminal) }
            mergeHistory(history, requestSequence: historySequence)
            guard status.map(Self.isTerminalChatStatus) == true else {
                lastChatIssue = "正在等待上一条回复结束，新消息已保存。"; return
            }
            guard !isChatBusy, isChatAvailable else { return }
            var submitted = pending; submitted.submitted = true
            chatDraftStore.replacement = submitted
            try chatDraftStore.save()
            await sendChatText(pending.text, clearComposer: false, requestedID: pending.id, attachmentIDs: pending.attachmentIDs)
        } catch {
            guard generation == clientGeneration, repository == repositoryGeneration else { return }
            lastChatIssue = "暂未确认回复状态，新消息已保留：" + error.localizedDescription
        }
    }

    func uploadAttachment(_ original: MobileChatAttachment) async {
        guard supportsChatAttachments else { chatDraftStore.issue = "当前学业服务尚不支持附件，请更新服务后重试；附件已保存在本机。"; return }
        guard let client, !chatDraftStore.uploading.contains(original.id) else { return }
        var item = original
        if let metadata = item.remoteMetadata, metadata.expiresAt <= .now || [.failed, .expired, .removed].contains(metadata.state) {
            do { item = try chatDraftStore.renew(item) }
            catch { chatDraftStore.issue = error.localizedDescription; return }
        }
        let uploadItem = item
        let generation = clientGeneration, repository = repositoryGeneration
        chatDraftStore.uploading.insert(item.id); chatDraftStore.issue = nil
        defer { if generation == clientGeneration, repository == repositoryGeneration { chatDraftStore.uploading.remove(item.id) } }
        let transfer = ChatAttachmentTransfer { [weak self] path, data in
            let current = await MainActor.run { self?.clientGeneration == generation && self?.repositoryGeneration == repository }
            guard current else { throw CancellationError() }
            return try await client.attachmentJSON(path: path, body: data)
        }
        do {
            let file = chatDraftStore.url(for: item)
            let identity = try ChatAttachmentTransfer.fingerprint(file)
            let request = ChatAttachmentCreateRequest(id: item.id, filename: item.name, mimeType: item.mimeType, byteCount: identity.byteCount, sha256: identity.sha256)
            var status = try await transfer.upload(file: file, request: request) { [weak self] value in
                await MainActor.run {
                    guard let self, generation == self.clientGeneration, repository == self.repositoryGeneration else { return }
                    self.chatDraftStore.progress[uploadItem.id] = Double(value.uploadedBytes) / Double(max(1, value.byteCount))
                }
            }
            for _ in 0..<60 where status.state == .processing || status.state == .unknown {
                try await Task.sleep(for: .seconds(2))
                guard generation == clientGeneration, repository == repositoryGeneration else { return }
                status = try await transfer.status(id: item.id)
            }
            guard generation == clientGeneration, repository == repositoryGeneration else { return }
            if status.state == .ready { chatDraftStore.update(item.id, remoteID: status.id, metadata: status) }
            else { chatDraftStore.update(item.id, metadata: status, issue: status.issue ?? "附件尚未就绪，轻点重试以检查状态。") }
        } catch {
            guard generation == clientGeneration, repository == repositoryGeneration else { return }
            chatDraftStore.update(item.id, issue: error.localizedDescription)
        }
    }

    func previewAttachment(_ attachment: ChatAttachmentDTO) async throws -> URL {
        guard let client else { throw URLError(.notConnectedToInternet) }
        let generation = clientGeneration, repository = repositoryGeneration
        let destination = try chatDraftStore.previewDestination(filename: attachment.filename)
        let transfer = ChatAttachmentTransfer { [weak self] path, data in
            let current = await MainActor.run { self?.clientGeneration == generation && self?.repositoryGeneration == repository }
            guard current else { throw CancellationError() }
            return try await client.attachmentJSON(path: path, body: data)
        }
        try await transfer.download(attachment, to: destination)
        guard generation == clientGeneration, repository == repositoryGeneration else {
            try? FileManager.default.removeItem(at: destination); throw CancellationError()
        }
        try chatDraftStore.recordPreview(attachment, url: destination)
        return destination
    }

    func removeAttachment(_ item: MobileChatAttachment) {
        // An attachment frozen into the pending replacement remains available to
        // that request even if removed from the independently editable composer.
        chatDraftStore.remove(item.id)
        guard chatDraftStore.replacement?.attachmentIDs.contains(item.remoteID ?? item.id) != true, let client else { return }
        Task { _ = try? await ChatAttachmentTransfer { path, data in try await client.attachmentJSON(path: path, body: data) }.remove(id: item.id) }
    }

    public func interruptChat() async {
        guard supportsTargetedInterrupt else { lastChatIssue = "当前学业服务尚不支持定向停止，请更新服务。"; return }
        guard let client, isChatBusy else { return }
        let generation = clientGeneration
        let pendingID = activeChatRequest?.pendingID
        let observedTurnID = observedChatTurnID
        do {
            guard let target = activeChatRequest?.turnID ?? observedChatTurnID else {
                lastChatIssue = "正在核对当前回复的编号，暂未发送停止请求。"
                await refreshChat(); return
            }
            let receipt = try await client.interruptChat(turnID: target)
            guard generation == clientGeneration else { return }
            if let terminal = receipt.terminal { applyTerminal(terminal) }
        } catch {
            guard generation == clientGeneration, activeChatRequest?.pendingID == pendingID,
                  observedChatTurnID == observedTurnID else { return }
            if !Self.isRequestCancellation(error) {
                setChatIssue(code: (error as? StudyRocketRemoteError)?.body.code, message: error.localizedDescription)
            }
        }
        guard generation == clientGeneration, activeChatRequest?.pendingID == pendingID,
              observedChatTurnID == observedTurnID else { return }
        // Stop acknowledgement is not a turn terminal. Keep the original
        // operation until history proves interrupted/completed/failed.
        chatProgress = .recovering
        await refreshChat()
        if generation == clientGeneration, activeChatRequest?.pendingID == pendingID, isChatBusy {
            startChatRecovery(generation: generation)
        }
    }

    public func refreshConversation() async {
        if let conversationTask { await conversationTask.value; return }
        let token = UUID(), generation = clientGeneration
        conversationToken = token
        refreshingConversation = true
        conversationRefreshError = nil
        let task = Task { @MainActor in
            guard let client else { conversationRefreshError = "请先在“更多”连接 Mac。"; return }
            var historyTicket: UInt64?
            do {
                let latest = try await client.health()
                guard generation == clientGeneration else { return }
                guard latest.repositoryBound else { throw MobileHostStateError.configurationUnavailable }
                if latest.repositoryID != activeRepositoryID || snapshot == nil {
                    await refresh()
                    guard generation == clientGeneration, state == .online else { return }
                }
                health = latest
                state = .online
                lastConnectionIssue = nil
                if latest.chatIssueCode != "provider_auth_failed", lastChatIssueCode == "provider_auth_failed" {
                    lastChatIssueCode = nil; lastChatIssue = nil
                }
                startEventStream()
                guard isChatAvailable else { return }
                let historySequence = beginChatHistoryRequest()
                historyTicket = historySequence
                let history = try await client.chatHistory()
                guard generation == clientGeneration, historySequence >= appliedChatHistorySequence else { return }
                mergeHistory(history, requestSequence: historySequence)
                let pending = try await client.proposals()
                guard generation == clientGeneration else { return }
                proposals = pending.proposals
            } catch {
                guard generation == clientGeneration, historyTicket.map({ $0 >= appliedChatHistorySequence }) ?? true, !Self.isRequestCancellation(error) else { return }
                conversationRefreshError = "刷新失败：" + error.localizedDescription
                recordConnectionFailureIfNeeded(error)
            }
        }
        conversationTask = task
        await task.value
        if token == conversationToken { conversationTask = nil; refreshingConversation = false }
    }

    public func refreshChat() async {
        guard let client, canViewProposals else { return }
        let currentStreamGeneration = streamGeneration
        let endpointGeneration = clientGeneration
        let historySequence = beginChatHistoryRequest()
        do {
            let history = try await client.chatHistory()
            guard currentStreamGeneration == streamGeneration,
                  endpointGeneration == clientGeneration, historySequence >= appliedChatHistorySequence else { return }
            mergeHistory(history, requestSequence: historySequence)
        } catch {
            guard currentStreamGeneration == streamGeneration, endpointGeneration == clientGeneration, historySequence >= appliedChatHistorySequence,
                  !Self.isRequestCancellation(error) else { return }
            if let remoteError = error as? StudyRocketRemoteError, remoteError.body.code == "codex_starting" {
                markChatUnavailable()
            } else {
                setChatIssue(code: (error as? StudyRocketRemoteError)?.body.code, message: error.localizedDescription)
            }
            // 对话历史加载失败不清空已有内容，页面仍可保留当前草稿。
        }
    }

    public func startEventStream() {
        guard isForeground, !automaticRefreshBlocked, eventStreamsEnabled, eventsTask == nil, let client else { return }
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
                        if self.isAuthenticationOrConfigurationFailure(error) {
                            self.automaticRefreshBlocked = true
                            self.recordConnectionFailureIfNeeded(error)
                            self.stopEventStream()
                            return
                        }
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
        snapshotInvalidationTask?.cancel()
        snapshotInvalidationTask = nil
        snapshotInvalidationToken = nil
        pendingSnapshotInvalidation = nil
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
        guard isForeground, !automaticRefreshBlocked, !isEventRecoveryInFlight else { return }
        isEventRecoveryInFlight = true
        let streamGeneration = self.streamGeneration
        let endpointGeneration = clientGeneration
        Task { [weak self] in
            guard let self,
                  self.streamGeneration == streamGeneration,
                  self.clientGeneration == endpointGeneration else { return }
            await self.refresh(isRetry: false, showsChecking: false)
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
        guard isForeground, !automaticRefreshBlocked, reconnectFailures >= 3, !isEventProbeInFlight else { return }
        reconnectFailures = 0
        isEventProbeInFlight = true
        let streamGeneration = self.streamGeneration
        let endpointGeneration = clientGeneration
        Task { [weak self] in
            guard let self,
                  self.streamGeneration == streamGeneration,
                  self.clientGeneration == endpointGeneration else { return }
            await self.refresh(isRetry: false, showsChecking: false)
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
            prepareOrganizationPreview()
        } catch {
            guard generation == clientGeneration else { return }
            NSLog("StudyRocket Mobile proposal refresh failed: %@", error.localizedDescription)
        }
    }

    func consumeHostEvent(_ event: HostEventEnvelope) {
        if event.kind == "heartbeat" { return }
        if let eventSnapshot = event.snapshot {
            invalidateSnapshot(from: eventSnapshot)
        }

        switch event.kind {
        case "chat.ready", "chat.protocolReady":
            Task { [weak self] in await self?.refresh() }
        case "chat.started":
            // Legacy envelopes have no turn identity and may be replayed.
            // Only identified progress or authoritative history can mark busy.
            Task { [weak self] in await self?.refreshChat() }
        case "chat.completed", "chat.interrupted", "chat.failed":
            // Legacy envelopes have no operation identity. History, rather
            // than an anonymous terminal event, must settle the pending send.
            Task { [weak self] in await self?.refreshChat() }
        default: break
        }

        if let chat = event.chat { applyChatEvent(chat) }
    }

    /// Cloud SSE replays its durable event log from the reconnect cursor. Its
    /// snapshot payload describes the original event, not current authority.
    /// Keep processing chat/receipt events and the transport cursor normally;
    /// use snapshot timestamps only to suppress obsolete invalidations.
    private func invalidateSnapshot(from eventSnapshot: SnapshotResponse) {
        guard isForeground, !automaticRefreshBlocked,
              eventSnapshot.fetchedAt > (snapshot?.fetchedAt ?? .distantPast) else { return }
        pendingSnapshotInvalidation = max(pendingSnapshotInvalidation ?? .distantPast, eventSnapshot.fetchedAt)
        guard snapshotInvalidationTask == nil else { return }
        let token = UUID(), endpoint = clientGeneration, lifecycle = foregroundGeneration
        snapshotInvalidationToken = token
        snapshotInvalidationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.snapshotInvalidationToken == token {
                    self.snapshotInvalidationTask = nil
                    self.snapshotInvalidationToken = nil
                    self.pendingSnapshotInvalidation = nil
                }
            }
            // The first await may join a GET that started before the event.
            // Allow one followup for that signal, and retain genuinely newer
            // signals received during it. A repeated/future timestamp cannot
            // cause an unbounded sequence of authoritative reads.
            var attemptedTimestamp: Date?
            var attemptsForTimestamp = 0
            while true {
                guard !Task.isCancelled, self.isForeground,
                      endpoint == self.clientGeneration, lifecycle == self.foregroundGeneration,
                      let required = self.pendingSnapshotInvalidation,
                      required > (self.snapshot?.fetchedAt ?? .distantPast) else { return }
                if attemptedTimestamp != required { attemptedTimestamp = required; attemptsForTimestamp = 0 }
                guard attemptsForTimestamp < 2 else { return }
                attemptsForTimestamp += 1
                await self.refreshVisibleContent()
                guard self.state == .online else { return }
            }
        }
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
            if acceptChatProgress(turnID) {
                isChatBusy = true
                chatProgress = .responding
            }
            scheduleDeltaFlush()
        case "item_completed":
            guard let turnID = event.turnID, let itemID = event.itemID, let text = event.text else { return }
            let key = streamKey(turnID: turnID, itemID: itemID)
            pendingChatDeltas.removeValue(forKey: key)
            guard completedItemKeys.insert(key).inserted else { return }
            if acceptChatProgress(turnID) {
                isChatBusy = true
                chatProgress = .responding
            }
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
                guard let turnID = event.turnID, acceptChatProgress(turnID) else { return }
                isChatBusy = true
                if chatProgress != .responding { chatProgress = .thinking }
            case "completed", "interrupted", "failed":
                guard let turnID = event.turnID else {
                    Task { [weak self] in await self?.refreshChat() }
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

    @discardableResult
    private func adoptActiveChatTurn(_ turnID: String) -> Bool {
        guard var request = activeChatRequest,
              !request.priorTurnIDs.contains(turnID), !completedTurnIDs.contains(turnID) else { return false }
        if let bound = request.turnID { return bound == turnID }
        let matchedUser = chatMessages.contains { $0.role == "user" && $0.turnID == turnID && $0.text == request.text }
        guard turnID == request.operationID || matchedUser else { return false }
        request.turnID = turnID
        bindOrganizationTurn(requestID: request.operationID, turnID: turnID)
        activeChatRequest = request
        return true
    }

    private func acceptChatProgress(_ turnID: String) -> Bool {
        guard !completedTurnIDs.contains(turnID) else { return false }
        if activeChatRequest != nil { return adoptActiveChatTurn(turnID) }
        observedChatTurnID = turnID
        return true
    }

    private func finishChatActivity(issue: String? = nil, issueCode: String? = nil) {
        chatRecoveryTask?.cancel()
        chatRecoveryTask = nil
        activeChatRequest = nil
        observedChatTurnID = nil
        isChatBusy = false
        chatProgress = nil
        if let issue { setChatIssue(code: issueCode, message: issue) }
    }

    private func setChatIssue(code: String?, message: String?) {
        lastChatIssueCode = code
        if code == "provider_auth_failed" {
            lastChatIssue = health?.backend == "cloud" ? "云模型服务认证失败，请检查服务端凭据。输入和草稿已保留。" : "Codex 身份验证已失效。请在 Mac 上重新登录 Codex，然后重新打开 StudyRocket Host。"
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
        chatTerminalReceipts[terminal.turnID] = terminal
        settleOrganization(terminal: terminal)
        let newlyCompleted = completedTurnIDs.insert(terminal.turnID).inserted
        let matchesActive = activeChatRequest.map { $0.turnID == terminal.turnID || $0.operationID == terminal.turnID } ?? false
        let matchesObserved = activeChatRequest == nil && observedChatTurnID == terminal.turnID
        guard newlyCompleted || matchesActive || matchesObserved else { return }
        // Publish terminal presentation in the same event, without waiting for
        // another network round trip to switch the live text to rich Markdown.
        chatMessages = chatMessages.map { message in
            guard message.turnID == terminal.turnID else { return message }
            return ChatMessageDTO(id: message.id, role: message.role, text: message.text, date: message.date,
                turnID: message.turnID, phase: message.phase, status: terminal.status, attachments: message.attachments)
        }
        chatRevision &+= 1
        // A replayed terminal may settle only its own operation, never a
        // newer pending message that happens to be active on this device.
        completePersistedChat(id: terminal.turnID)
        let request = activeChatRequest
        let settlesActive = request.map { $0.turnID == terminal.turnID || $0.operationID == terminal.turnID } ?? false
        let settlesObserved = request == nil && (observedChatTurnID == nil || observedChatTurnID == terminal.turnID)
        if settlesActive || settlesObserved {
            if settlesActive { completePersistedChat(id: request?.operationID) }
            if terminal.status == "failed" {
                failedChatTurnID = terminal.turnID
                failedChatWasRejected = false
                failedChatAttachmentIDs = request?.attachmentIDs ?? chatMessages.last(where: { $0.role == "user" && $0.turnID == terminal.turnID })?.attachments?.map(\.id) ?? []
                lastFailedChatText = request?.text ?? chatMessages.last(where: { $0.role == "user" && $0.turnID == terminal.turnID })?.text
                finishChatActivity(issue: terminal.message ?? "学业对话未能完成，请重试这条消息。", issueCode: terminal.issueCode)
            } else {
                finishChatActivity()
                lastChatIssue = nil
                lastChatIssueCode = nil
                lastFailedChatText = nil
            }
        }
        Task { [weak self] in
            await self?.refreshChat()
            await self?.refreshProposals()
        }
    }

    private func historyTurnID(for request: ActiveMobileChatRequest, in history: [ChatMessageDTO]) -> String? {
        if let turnID = request.turnID { return turnID }
        if health?.backend == "cloud" { return request.operationID }
        return history.reversed().first(where: {
            $0.role == "user" && $0.text == request.text && !request.priorTurnIDs.contains($0.turnID ?? "")
        })?.turnID
    }

    private func reconcileChatActivity(with history: [ChatMessageDTO], terminals: [ChatTurnTerminalDTO]) {
        guard var request = activeChatRequest else {
            // History and SSE replay race on first connection. A terminal may
            // already be presentation-deduplicated while remote activity still
            // needs settlement. Never apply this branch to a local pending send.
            if let observed = observedChatTurnID {
                if let terminal = terminals.last(where: { $0.turnID == observed }) {
                    applyTerminal(terminal)
                } else if let status = history.last(where: {
                    $0.turnID == observed && $0.status.map(Self.isTerminalChatStatus) == true
                })?.status {
                    applyTerminal(ChatTurnTerminalDTO(turnID: observed, status: status))
                } else {
                    // A stale history page can omit a genuinely live SSE turn.
                    // Absence is not terminal evidence.
                    return
                }
            }
            if let running = history.last(where: {
                $0.status == "inProgress" && $0.turnID.map { !completedTurnIDs.contains($0) } == true
            }), let turnID = running.turnID {
                observedChatTurnID = turnID
                isChatBusy = true
                chatProgress = running.role == "assistant" ? .responding : .thinking
            } else if isChatBusy {
                finishChatActivity()
            }
            return
        }
        let matchedTurnID = historyTurnID(for: request, in: history)
        guard let turnID = matchedTurnID else {
            if isChatBusy, chatProgress == .sending { chatProgress = .thinking }
            return
        }
        request.turnID = turnID
        bindOrganizationTurn(requestID: request.operationID, turnID: turnID)
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
            guard !completedTurnIDs.contains(value.turnID) else { continue }
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

    private func mergeHistory(_ response: ChatHistoryResponse, requestSequence: UInt64) {
        guard requestSequence >= appliedChatHistorySequence else { return }
        appliedChatHistorySequence = requestSequence
        reconcileOrganizationHistory(response)
        let restoringConversation = chatMessages.isEmpty && activeChatRequest == nil
        let terminalStatuses = (response.terminalTurns ?? []).filter { Self.isTerminalChatStatus($0.status) }
            .reduce(into: [String: String]()) { $0[$1.turnID] = $1.status }
        let terminalIDs = Set(terminalStatuses.keys)
        completedTurnIDs.formUnion(terminalIDs)
        if !terminalIDs.isEmpty, let data = try? Data(contentsOf: cloudChatsURL),
           let entries = try? JSONDecoder().decode([PendingCloudChat].self, from: data) {
            let remaining = entries.filter { !($0.endpoint == clientEndpoint && $0.repositoryID == activeRepositoryID && terminalIDs.contains($0.id)) }
            if remaining.count != entries.count { try? JSONEncoder().encode(remaining).write(to: cloudChatsURL, options: .atomic) }
        }
        if !isChatBusy, inputDraft.isEmpty,
           let data = try? Data(contentsOf: cloudChatsURL),
           let entries = try? JSONDecoder().decode([PendingCloudChat].self, from: data),
           let unresolved = entries.first(where: { $0.endpoint == clientEndpoint && $0.repositoryID == activeRepositoryID && !isOrganizationRequest($0.id) }) {
            inputDraft = unresolved.text
        }
        let history = response.messages
        let activeHistoryTurnID = activeChatRequest.flatMap { historyTurnID(for: $0, in: history) }
        let streamMessages = chatMessages.filter { $0.id.hasPrefix("stream-") }
        let pendingMessages = chatMessages.filter { $0.id.hasPrefix("mobile-pending-") }
        var merged = history.map { message in
            let status = message.turnID.flatMap { terminalStatuses[$0] } ?? message.status
                ?? (message.turnID.map { completedTurnIDs.contains($0) } == true ? "completed" : nil)
            if let turnID = message.turnID {
                if (status == "completed" || status == "interrupted" || status == "failed"), turnID != activeHistoryTurnID {
                    completedTurnIDs.insert(turnID)
                }
                if let status, Self.isTerminalChatStatus(status) { completedItemKeys.insert(streamKey(turnID: turnID, itemID: message.id)) }
            }
            return ChatMessageDTO(id: message.id, role: message.role, text: message.text, date: message.date, turnID: message.turnID, phase: message.phase, status: status, attachments: message.attachments)
        }

        for message in streamMessages {
            guard let turnID = message.turnID, let historyMessage = history.first(where: { $0.turnID == turnID && $0.id == streamItemID(message.id, turnID: turnID) }) else {
                if let turnID = message.turnID, !completedTurnIDs.contains(turnID) { merged.append(message) }
                continue
            }
            if let index = merged.firstIndex(where: { $0.id == historyMessage.id }) {
                if historyMessage.status.map(Self.isTerminalChatStatus) != true, !completedTurnIDs.contains(turnID) {
                    merged[index] = ChatMessageDTO(id: message.id, role: message.role,
                        text: message.text.count >= historyMessage.text.count ? message.text : historyMessage.text,
                        date: message.date, turnID: turnID, phase: message.phase, status: "inProgress")
                } else {
                    merged[index] = ChatMessageDTO(id: message.id, role: historyMessage.role, text: historyMessage.text,
                        date: historyMessage.date, turnID: turnID, phase: historyMessage.phase ?? message.phase, status: historyMessage.status)
                }
            }
        }
        for message in pendingMessages {
            let operationID = String(message.id.dropFirst("mobile-pending-".count))
            let boundTurnID = activeChatRequest?.pendingID == message.id ? activeHistoryTurnID : nil
            let acknowledged = history.contains {
                $0.role == "user" && ($0.turnID == operationID || (boundTurnID != nil && $0.turnID == boundTurnID))
            }
            if !acknowledged { merged.append(message) }
        }
        let mergedKeys = Set(merged.map { ($0.turnID ?? "") + "|" + streamItemID($0.id, turnID: $0.turnID ?? "") })
        for message in chatMessages where !message.id.hasPrefix("stream-") && !message.id.hasPrefix("mobile-pending-") {
            let key = (message.turnID ?? "") + "|" + streamItemID(message.id, turnID: message.turnID ?? "")
            if !mergedKeys.contains(key) {
                merged.append(ChatMessageDTO(id: message.id, role: message.role, text: message.text, date: message.date,
                    turnID: message.turnID, phase: message.phase, status: message.turnID.flatMap { terminalStatuses[$0] } ?? message.status, attachments: message.attachments))
            }
        }
        let sorted = merged.sorted { $0.date < $1.date }
        if chatMessages != sorted { chatMessages = sorted; chatRevision &+= 1 }
        reconcileChatActivity(with: history, terminals: response.terminalTurns ?? [])
        if chatDraftStore.replacement != nil && !resumingReplacement { Task { await self.resumePendingReplacement() } }
        if restoringConversation, let user = sorted.last(where: { $0.role == "user" }), let turnID = user.turnID {
            let terminal = response.terminalTurns?.last(where: { $0.turnID == turnID })
            if (terminal?.status ?? user.status) == "failed" {
                failedChatTurnID = turnID
                lastFailedChatText = user.text
                setChatIssue(code: terminal?.issueCode, message: terminal?.message ?? "上一条消息未完成，可以核对状态后重试。")
            }
        }
    }

    private func streamKey(turnID: String, itemID: String) -> String { "\(turnID)|\(itemID)" }

    private func streamItemID(_ streamID: String, turnID: String) -> String {
        let prefix = "stream-\(turnID)-"
        return streamID.hasPrefix(prefix) ? String(streamID.dropFirst(prefix.count)) : streamID
    }

    @discardableResult
    public func applyProposals(ids: [String]? = nil, expectedRevision: String? = nil) async -> MobileProposalApplyOutcome {
        guard !isApplyingProposals else { return .busy }
        guard let client, let current = snapshot, let endpoint = clientEndpoint,
              let repositoryID = activeRepositoryID, canViewProposals else { return .unavailable }
        let generation = clientGeneration
        let repository = repositoryGeneration
        let selectedIDs = (ids ?? proposals.map(\.id)).sorted()
        guard !selectedIDs.isEmpty else { return .unavailable }
        isApplyingProposals = true
        defer { isApplyingProposals = false }
        var operation = loadProposalApplication()
        // Reconcile the saved operation before selecting a new revision or key.
        if let saved = operation, (saved.succeeded || saved.failure != nil), saved.proposalIDs != selectedIDs { operation = nil }
        if let saved = operation, saved.submitted {
            let outcome = await reconcileProposalApplication(saved)
            proposalApplyOutcome = outcome
            return outcome
        }
        if let expectedRevision, expectedRevision != current.revision { return .rejected("计划已变化，请补充要求并重新生成整理草案。") }
        guard Set(selectedIDs).isSubset(of: Set(proposals.map(\.id))) else { return .rejected("草案已变化，请刷新后重新查看差异。") }
        if let saved = operation, saved.proposalIDs == selectedIDs, saved.baseRevision != current.revision {
            return .rejected("原确认基线已变化，请重新生成草案；不会替换原操作编号重试。")
        }
        if operation?.proposalIDs != selectedIDs {
            operation = MobileProposalApplication(endpoint: endpoint, repositoryID: repositoryID,
                proposalIDs: selectedIDs, baseRevision: current.revision)
        }
        guard var operation else { return .unavailable }
        do {
            try saveProposalApplication(operation)
            let challenge = try await client.proposalChallenge()
            guard generation == clientGeneration, repository == repositoryGeneration else { return .unavailable }
            let authorization = try await MobileProposalAuthorization.evaluate(challenge: challenge)
            guard generation == clientGeneration, repository == repositoryGeneration else { return .unavailable }
            operation.submitted = true
            try saveProposalApplication(operation)
            let response = try await client.applyProposals(ids: operation.proposalIDs, authorization: authorization,
                baseRevision: operation.baseRevision, idempotencyKey: operation.id)
            guard generation == clientGeneration, repository == repositoryGeneration else { return .unavailable }
            operation.succeeded = true; operation.resultRevision = response.revision
            try saveProposalApplication(operation)
            proposals = response.remaining.proposals
            let outcome = MobileProposalApplyOutcome.applied(revision: response.revision)
            proposalApplyOutcome = outcome
            await refresh()
            return outcome
        } catch {
            guard generation == clientGeneration, repository == repositoryGeneration else { return .unavailable }
            // Business rejection is authoritative. Transport/cancellation after POST
            // is unknown and may only be resolved using the original operation ID.
            let rejection = (error as? StudyRocketRemoteError).map {
                ["conflict", "invalid_proposals", "planning_pair_required", "unauthorized", "revision_conflict", "proposal_conflict", "proposal_not_found", "invalid_proposal", "validation_failed", "authorization_failed", "invalid_authorization"].contains($0.body.code)
            } ?? false
            if !operation.submitted || rejection {
                operation.submitted = false
                try? saveProposalApplication(operation)
                let result = MobileProposalApplyOutcome.rejected(error.localizedDescription)
                proposalApplyOutcome = result; lastChatIssue = error.localizedDescription
                return result
            }
            let outcome = await reconcileProposalApplication(operation)
            proposalApplyOutcome = outcome
            return outcome
        }
    }

    @discardableResult
    public func saveWeek(_ plan: WeeklyPlanSnapshot, events: [OneOffEvent]? = nil, originalTimetable: String? = nil, baseRevision: String? = nil) async -> Bool {
        let normalizedPlan = WeeklyPlanTaskNormalizer.normalized(plan)
        let originalRevision = baseRevision ?? snapshot?.revision
        func retainDraft() {
            var drafts = loadPendingDrafts()
            drafts.week = normalizedPlan; drafts.events = events
            drafts.weekBaseRevision = originalRevision
            drafts.eventBaseHash = originalTimetable.map { PeriodCompletion.textHash(for: $0) }
            saveDrafts(drafts)
        }
        guard let client, let current = snapshot, state == .online, !isReplayingPendingToggles else {
            retainDraft()
            return false
        }
        let generation = clientGeneration
        do {
            let value = try await client.applyWeek(plan: normalizedPlan, baseRevision: originalRevision ?? current.revision, events: events, eventBaseHash: originalTimetable.map { PeriodCompletion.textHash(for: $0) })
            guard generation == clientGeneration else { return false }
            snapshot = value
            state = .online
            saveCache(value)
            var drafts = loadPendingDrafts(); drafts.week = nil; drafts.weekBaseRevision = nil; drafts.events = nil; drafts.eventBaseHash = nil; saveDrafts(drafts)
            return true
        } catch {
            guard generation == clientGeneration else { return false }
            retainDraft()
            recordConnectionFailureIfNeeded(error)
            pendingToggleSyncIssue = "计划未保存：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    public func saveEvents(_ events: [OneOffEvent], original: String) async -> Bool {
        guard let current = snapshot else { return false }
        let saved = await saveWeek(current.week, events: events, originalTimetable: original)
        if saved { _ = await document(for: "timetable") }
        return saved
    }

    public func assignUnassignedTask(
        sourceDayID: String,
        taskIndex: Int,
        text: String,
        targetDayID: String,
        targetPeriodID: String
    ) async {
        let editedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !editedText.isEmpty, let current = snapshot,
              let sourceIndex = current.week.days.firstIndex(where: { $0.id == sourceDayID }),
              let targetIndex = current.week.days.firstIndex(where: { $0.id == targetDayID }) else { return }

        let source = current.week.days[sourceIndex]
        if var graph = current.week.linkage {
            let tasks = PeriodTaskParser.tasks(from: source.unassigned)
            guard tasks.indices.contains(taskIndex), let assignment = graph.assignments.first(where: { $0.active && $0.date == sourceDayID && $0.periodID == "unassigned" && $0.legacyTaskID == tasks[taskIndex].id }) else { return }
            do {
                try graph.rename(assignment.taskID, text: editedText)
                try graph.reschedule(assignment.taskID, date: targetDayID, periodID: targetPeriodID)
                await saveWeek(graph.projected(current.week))
            } catch { pendingToggleSyncIssue = error.localizedDescription }
            return
        }
        var unassignedTasks = PeriodTaskParser.tasks(from: source.unassigned).map(\.text)
        guard unassignedTasks.indices.contains(taskIndex) else { return }
        unassignedTasks.remove(at: taskIndex)

        let days = current.week.days.enumerated().map { index, day -> DaySnapshot in
            var unassigned = day.unassigned
            var slots = day.slots
            if index == sourceIndex {
                unassigned = unassignedTasks.joined(separator: "\n")
            }
            if index == targetIndex,
               let periodIndex = slots.firstIndex(where: { $0.id == targetPeriodID }) {
                slots[periodIndex] = periodAppending(editedText, to: slots[periodIndex])
            }
            return DaySnapshot(id: day.id, dateLabel: day.dateLabel, slots: slots, unassigned: unassigned)
        }
        await saveWeek(replacingDays(in: current.week, with: days))
    }

    public func returnScheduledTaskToUnassigned(
        dayID: String,
        periodID: String,
        taskID: String
    ) async {
        guard let current = snapshot,
              let dayIndex = current.week.days.firstIndex(where: { $0.id == dayID }) else { return }

        let day = current.week.days[dayIndex]
        guard let periodIndex = day.slots.firstIndex(where: { $0.id == periodID }),
              let task = day.slots[periodIndex].tasks.first(where: { $0.id == taskID }) else { return }

        if var graph = current.week.linkage, let id = task.logicalTaskID {
            do { try graph.reschedule(id, date: dayID, periodID: "unassigned"); await saveWeek(graph.projected(current.week)) }
            catch { pendingToggleSyncIssue = error.localizedDescription }
            return
        }
        let days = current.week.days.enumerated().map { index, value -> DaySnapshot in
            guard index == dayIndex else { return value }
            var slots = value.slots
            slots[periodIndex] = periodRemoving(taskID, from: slots[periodIndex])
            let unassigned = (PeriodTaskParser.tasks(from: value.unassigned).map(\.text) + [task.text])
                .joined(separator: "\n")
            return DaySnapshot(id: value.id, dateLabel: value.dateLabel, slots: slots, unassigned: unassigned)
        }
        await saveWeek(replacingDays(in: current.week, with: days))
    }

    private func replacingDays(in plan: WeeklyPlanSnapshot, with days: [DaySnapshot]) -> WeeklyPlanSnapshot {
        WeeklyPlanSnapshot(
            days: days,
            bufferRules: plan.bufferRules,
            deliveries: plan.deliveries,
            historicalRows: plan.historicalRows,
            futureRows: plan.futureRows,
            linkage: plan.linkage
        )
    }

    private func periodAppending(_ text: String, to period: PeriodSnapshot) -> PeriodSnapshot {
        let taskTexts = period.tasks.map(\.text) + [text]
        let updatedTasks = PeriodTaskParser.tasks(from: taskTexts.joined(separator: "\n"))
        let completionByID = Dictionary(uniqueKeysWithValues: period.tasks.map { ($0.id, $0.isCompleted) })
        let tasks = updatedTasks.map {
            PeriodTaskSnapshot(id: $0.id, text: $0.text, isCompleted: completionByID[$0.id] ?? false)
        }
        return PeriodSnapshot(id: period.id, title: period.title, text: taskTexts.joined(separator: "\n"), tasks: tasks)
    }

    private func periodRemoving(_ taskID: String, from period: PeriodSnapshot) -> PeriodSnapshot {
        let remainingTasks = period.tasks.filter { $0.id != taskID }
        return PeriodSnapshot(
            id: period.id,
            title: period.title,
            text: remainingTasks.map(\.text).joined(separator: "\n"),
            tasks: remainingTasks
        )
    }

    func toggleDelivery(
        _ delivery: DeliverySnapshot,
        isCompleted: Bool,
        mutation: MobileDeliveryMutation,
        confirmedTaskIDs: [String]? = nil
    ) async -> MobileDeliveryToggleResult {
        guard mutation.deliveryID == delivery.id,
              mutation.repositoryGeneration == repositoryGeneration else {
            return .staleGeneration
        }
        if let completed = completedDeliveryMutations[mutation] { return completed }
        guard activeDeliveryMutations.insert(mutation).inserted else { return .staleGeneration }

        let result = await performDeliveryToggle(delivery, isCompleted: isCompleted, mutation: mutation, confirmedTaskIDs: confirmedTaskIDs)
        activeDeliveryMutations.remove(mutation)
        if mutation.repositoryGeneration == repositoryGeneration {
            completedDeliveryMutations[mutation] = result
        }
        return result
    }

    private func performDeliveryToggle(
        _ delivery: DeliverySnapshot,
        isCompleted desired: Bool,
        mutation: MobileDeliveryMutation,
        confirmedTaskIDs: [String]? = nil
    ) async -> MobileDeliveryToggleResult {
        if pendingDeliveryStates[deliveryQueueKey(delivery)] != nil {
            return .failed("此交付物已有待同步修改，请先取消或完成同步。")
        }
        lastConnectionIssue = nil
        guard let client, let current = snapshot, state == .online, !isReplayingPendingToggles else {
            var drafts = loadPendingDrafts()
            drafts.deliveries.removeAll { pendingDeliveryKey($0) == deliveryQueueKey(delivery) }
            drafts.deliveries.append(PendingDeliveryToggle(
                text: delivery.text,
                isCompleted: desired,
                idempotencyKey: mutation.token.uuidString,
                deliveryID: snapshot?.week.linkage == nil ? nil : delivery.id,
                confirmedTaskIDs: confirmedTaskIDs
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
                deliveryID: current.week.linkage == nil ? nil : delivery.id,
                confirmedTaskIDs: confirmedTaskIDs,
                timeoutInterval: 12
            )
            guard generation == clientGeneration,
                  requestRepositoryGeneration == repositoryGeneration else {
                return .staleGeneration
            }
            guard let authoritative = matchingDelivery(text: delivery.text, id: current.week.linkage == nil ? nil : delivery.id, in: value), authoritative.isCompleted == desired else {
                let message = "学业服务 返回的交付物状态未确认本次修改，已恢复原状态。"
                pendingToggleSyncIssue = message
                return .failed(message)
            }
            snapshot = value
            var drafts = loadPendingDrafts()
            drafts.deliveries.removeAll { pendingDeliveryKey($0) == deliveryQueueKey(delivery) }
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
                let message = "学业服务 未确认本次交付物修改，已恢复权威状态。"
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
        drafts.deliveries.removeAll { pendingDeliveryKey($0) == deliveryQueueKey(delivery) && $0.idempotencyKey != nil }
        saveDrafts(drafts)
        pendingToggleSyncIssue = nil
        refreshLegacyPendingReviewIfVisible()
    }

    public func effectiveDeliveryCompletion(_ delivery: DeliverySnapshot) -> Bool {
        pendingDeliveryStates[deliveryQueueKey(delivery)] ?? delivery.isCompleted
    }

    public func isDeliveryTogglePending(_ delivery: DeliverySnapshot) -> Bool {
        pendingDeliveryStates[deliveryQueueKey(delivery)] != nil
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
                idempotencyKey: idempotencyKey,
                logicalTaskID: task.logicalTaskID,
                assignmentID: task.assignmentID
            ))
            saveDrafts(drafts)
            return
        }

        let generation = clientGeneration
        let requestRepository = repositoryGeneration
        do {
            let value = try await client.togglePeriod(
                dayID: dayID,
                periodID: period.id,
                taskID: task.id,
                isCompleted: desired,
                baseRevision: current.revision,
                idempotencyKey: idempotencyKey,
                logicalTaskID: task.logicalTaskID,
                assignmentID: task.assignmentID,
                timeoutInterval: 12
            )
            guard generation == clientGeneration, requestRepository == repositoryGeneration else { return }
            snapshot = value
            pendingPeriodStates.removeValue(forKey: key)
            lastConnectionIssue = nil
            pendingToggleSyncIssue = nil
            state = .online
            saveCache(value)
        } catch {
            guard generation == clientGeneration, requestRepository == repositoryGeneration else { return }
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
                pendingToggleSyncIssue = "学业服务 未确认“\(task.text)”的完成状态，已恢复权威状态。"
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
            guard requiresReview(draft) else { return draft }
            let id = legacyDeliveryReviewID(draft)
            guard selectedIDs.contains(id) else { return nil }
            guard selectable.contains(id) else { return draft }
            return PendingDeliveryToggle(
                text: draft.text,
                isCompleted: draft.isCompleted,
                idempotencyKey: draft.idempotencyKey ?? UUID().uuidString,
                deliveryID: snapshot.week.linkage == nil ? nil : matchingDelivery(text: draft.text, id: draft.deliveryID, in: snapshot)?.id,
                confirmedTaskIDs: draft.confirmedTaskIDs
            )
        }
        drafts.periods = drafts.periods.compactMap { draft in
            guard requiresReview(draft) else { return draft }
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
        drafts.deliveries.removeAll(where: requiresReview)
        drafts.periods.removeAll(where: requiresReview)
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

    private func requiresReview(_ draft: PendingDeliveryToggle) -> Bool {
        if draft.idempotencyKey == nil { return true }
        guard let snapshot else { return false }
        guard let delivery = matchingDelivery(text: draft.text, id: draft.deliveryID, in: snapshot) else { return true }
        if draft.isCompleted, !delivery.isCompleted, let graph = snapshot.week.linkage {
            return Set(graph.pendingChildren(of: delivery.id).map(\.id)) != Set(draft.confirmedTaskIDs ?? [])
        }
        return false
    }
    private func requiresReview(_ draft: PendingPeriodToggle) -> Bool {
        if draft.isLegacy { return true }
        guard let snapshot, let graph = snapshot.week.linkage else { return false }
        let matches = graph.assignments.filter { a in
            if let id = draft.assignmentID { return a.id == id && (draft.logicalTaskID == nil || a.taskID == draft.logicalTaskID) }
            return a.date == draft.dayID && a.periodID == draft.periodID && a.legacyTaskID == draft.taskID
        }
        return matches.count != 1 || graph.tasks.first(where: { $0.id == matches.first?.taskID })?.cancelled != false
    }

    private func prepareLegacyPendingReviewIfNeeded(force: Bool = false) {
        let drafts = loadPendingDrafts()
        let hasLegacy = drafts.deliveries.contains(where: requiresReview) || drafts.periods.contains(where: requiresReview)
        legacyPendingToggleCount = drafts.deliveries.filter(requiresReview).count + drafts.periods.filter(requiresReview).count
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
        for draft in drafts.deliveries where requiresReview(draft) {
            let delivery = matchingDelivery(text: draft.text, id: draft.deliveryID, in: snapshot)
            let target = draft.isCompleted ? "标记为已完成" : "恢复为未完成"
            items.append(MobileLegacyPendingReviewItem(
                id: legacyDeliveryReviewID(draft),
                kind: .delivery,
                title: delivery?.text ?? draft.text,
                detail: delivery.map { [$0.dateLabel, target].compactMap { $0 }.joined(separator: " · ") }
                    ?? "任务已变化，无法自动同步",
                isCompleted: draft.isCompleted,
                canSync: delivery != nil && (snapshot.week.linkage?.pendingChildren(of: delivery!.id).isEmpty ?? true)
            ))
        }
        for draft in drafts.periods where requiresReview(draft) {
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

    func enqueueFact(_ fact: QuickFact) throws {
        try fact.validate()
        guard let activeRepositoryID else { throw FactError("请先连接一次 Mac，确认记录所属仓库。") }
        let next = factQueue + [QueuedFact(repositoryID: activeRepositoryID, endpoint: clientEndpoint, fact: fact)]
        try persistFacts(next)
    }

    private func persistFacts(_ next: [QueuedFact]) throws {
        if FileManager.default.fileExists(atPath: factsURL.path) {
            // Never overwrite an unreadable queue.
            _ = try JSONDecoder().decode([QueuedFact].self, from: Data(contentsOf: factsURL))
        }
        try FileManager.default.createDirectory(at: factsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: factsURL, options: .atomic)
        factQueue = next
    }

    func syncFacts() async {
        guard isForeground, !Task.isCancelled, factSyncToken == nil, let repo = activeRepositoryID, let client, state == .online else { return }
        let token = UUID(), generation = clientGeneration, lifecycle = foregroundGeneration
        factSyncToken = token
        defer { if factSyncToken == token { factSyncToken = nil } }
        while let fact = pendingFacts.first, let current = snapshot {
            guard isForeground, !Task.isCancelled, lifecycle == foregroundGeneration else { return }
            do {
                let value: SnapshotResponse
                do { value = try await client.appendFact(fact, repo: repo, revision: current.revision) }
                catch let error as StudyRocketRemoteError where error.body.code == "conflict" {
                    guard !Task.isCancelled, isForeground, lifecycle == foregroundGeneration, generation == clientGeneration else { return }
                    let latest = try await client.snapshot()
                    guard !Task.isCancelled, isForeground, lifecycle == foregroundGeneration, generation == clientGeneration else { return }
                    value = try await client.appendFact(fact, repo: repo, revision: latest.revision)
                }
                guard generation == clientGeneration else { return }
                // A 200 receipt for this signed, idempotent request confirms even an older month.
                try persistFacts(factQueue.filter { !($0.repositoryID == repo && $0.fact.id == fact.id) })
                // A confirmed receipt may dequeue its original operation, but
                // an old scene cannot replace the current scene's snapshot.
                guard !Task.isCancelled, isForeground, lifecycle == foregroundGeneration else { return }
                snapshot = value; saveCache(value); factSyncError = nil
            } catch {
                guard !Task.isCancelled, isForeground, lifecycle == foregroundGeneration, generation == clientGeneration else { return }
                factSyncError = error.localizedDescription
                return
            }
        }
    }

    public func saveDaily(_ entry: DailySnapshot) async {
        var drafts = loadPendingDrafts()
        // Re-editing an offline candidate never advances its original baseline.
        let originalRevision = drafts.daily != nil ? drafts.dailyBaseRevision : snapshot?.revision
        let operationID = drafts.daily == entry ? (drafts.dailyOperationID ?? UUID().uuidString) : UUID().uuidString
        drafts.daily = entry; drafts.dailyBaseRevision = originalRevision; drafts.dailyOperationID = operationID
        saveDrafts(drafts)
        guard loadPendingDrafts().dailyOperationID == operationID else { pendingToggleSyncIssue = "本机草稿未能持久保存，请保留输入后重试。"; return }
        guard let client, let originalRevision, state == .online, !isReplayingPendingToggles else { return }
        let generation = clientGeneration
        do {
            let value = try await client.saveDaily(entry: entry, baseRevision: originalRevision, idempotencyKey: operationID)
            guard generation == clientGeneration else { return }
            snapshot = value; state = .online; saveCache(value)
            var remaining = loadPendingDrafts()
            if remaining.dailyOperationID == operationID {
                remaining.daily = nil; remaining.dailyBaseRevision = nil; remaining.dailyOperationID = nil; saveDrafts(remaining)
            }
        } catch {
            guard generation == clientGeneration else { return }
            pendingToggleSyncIssue = "日结未提交：" + error.localizedDescription
            recordConnectionFailureIfNeeded(error)
        }
    }

    var pendingPlanComparison: String {
        let drafts = loadPendingDrafts()
        var text: [String] = []
        if let week = drafts.week {
            text.append("原周计划草稿\n" + migrationPretty(week))
            if let current = snapshot {
                text.append("当前云周计划\n" + migrationPretty(current.week))
                text.append(migrationDifference(current: migrationPretty(current.week), candidate: migrationPretty(week)))
            }
            text.append(drafts.weekBaseRevision == snapshot?.revision && drafts.weekBaseRevision != nil ? "周计划原基线仍匹配" : "周计划原基线缺失/已变化，不可直接提交；请手动合并")
        }
        if let daily = drafts.daily {
            text.append("原日结草稿\n" + migrationPretty(daily))
            if let current = snapshot {
                text.append("当前云日结\n" + migrationPretty(current.daily))
                text.append(migrationDifference(current: migrationPretty(current.daily), candidate: migrationPretty(daily)))
            }
            text.append(drafts.dailyBaseRevision == snapshot?.revision && drafts.dailyBaseRevision != nil ? "日结原基线仍匹配" : "日结原基线缺失/已变化，不可直接提交；请手动合并")
        }
        return text.joined(separator: "\n\n")
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
                let drafts = loadPendingDrafts()
                guard let originalRevision = drafts.weekBaseRevision, originalRevision == latest.revision else {
                    pendingToggleSyncIssue = "计划草稿基于旧版本，请在周计划中对照最新内容重新确认保存；草稿已保留。"
                    return
                }
                let value = try await client.applyWeek(plan: week, baseRevision: originalRevision, events: drafts.events, eventBaseHash: drafts.eventBaseHash)
                guard generation == clientGeneration else { return }
                snapshot = value
                pendingWeekDraft = nil
                saveCache(value)
                var remaining = loadPendingDrafts(); remaining.week = nil; remaining.weekBaseRevision = nil; remaining.events = nil; remaining.eventBaseHash = nil; saveDrafts(remaining)
            }
            if let daily = pendingDailyDraft {
                let drafts = loadPendingDrafts()
                guard let originalRevision = drafts.dailyBaseRevision, let operationID = drafts.dailyOperationID else {
                    pendingToggleSyncIssue = "旧日结缺少原始基线，只能对照处理；草稿继续保留。"
                    return
                }
                let value = try await client.saveDaily(entry: daily, baseRevision: originalRevision, idempotencyKey: operationID)
                guard generation == clientGeneration else { return }
                snapshot = value
                saveCache(value)
                var remaining = loadPendingDrafts(); remaining.daily = nil; remaining.dailyBaseRevision = nil; remaining.dailyOperationID = nil; saveDrafts(remaining)
            }
            prepareLegacyPendingReviewIfNeeded()
            if legacyPendingToggleCount == 0 {
                await replayPendingToggles()
            }
        } catch {
            guard generation == clientGeneration else { return }
            pendingToggleSyncIssue = "草稿未提交：" + error.localizedDescription
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
        let token = UUID()
        pendingReplayToken = token
        pendingReplayTask = task
        isReplayingPendingToggles = true
        await task.value
        guard pendingReplayToken == token, generation == clientGeneration,
              requestRepositoryGeneration == repositoryGeneration else { return }
        pendingReplayTask = nil
        pendingReplayToken = nil
        isReplayingPendingToggles = false
    }

    private func performPendingToggleReplay(generation: Int, repositoryGeneration: UInt64) async {
        guard let client else { return }
        pendingToggleSyncIssue = nil

        while !Task.isCancelled {
            let drafts = loadPendingDrafts()
            guard let draft = drafts.deliveries.first(where: { $0.idempotencyKey != nil }) else { break }
            guard !Task.isCancelled, isForeground, generation == clientGeneration,
                  repositoryGeneration == self.repositoryGeneration,
                  let latest = snapshot else { return }
            guard let delivery = matchingDelivery(text: draft.text, id: draft.deliveryID, in: latest) else {
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
                    deliveryID: draft.deliveryID,
                    confirmedTaskIDs: draft.confirmedTaskIDs,
                    timeoutInterval: 12
                )
                guard !Task.isCancelled, isForeground, generation == clientGeneration,
                      repositoryGeneration == self.repositoryGeneration else { return }
                guard matchingDelivery(text: draft.text, id: draft.deliveryID, in: value)?.isCompleted == draft.isCompleted else {
                    snapshot = value
                    state = .online
                    saveCache(value)
                    pendingToggleSyncIssue = "学业服务 未确认一个交付物的目标状态，自动同步已暂停。"
                    return
                }
                snapshot = value
                state = .online
                lastConnectionIssue = nil
                saveCache(value)
                removePendingDeliveryDraft(draft)
            } catch {
                guard !Task.isCancelled, isForeground, generation == clientGeneration,
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
                    pendingToggleSyncIssue = "计划已在服务端变化，交付物同步未完成。请重新加载后重试。"
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
            guard !Task.isCancelled, isForeground, generation == clientGeneration,
                  repositoryGeneration == self.repositoryGeneration,
                  let latest = snapshot else { return }
            if let graph = latest.week.linkage {
                let candidates = graph.assignments.filter {
                    if let id = draft.assignmentID { return $0.id == id && (draft.logicalTaskID == nil || $0.taskID == draft.logicalTaskID) }
                    return $0.date == draft.dayID && $0.periodID == draft.periodID && $0.legacyTaskID == taskID
                }
                guard candidates.count == 1, let assignment = candidates.first,
                      let linked = graph.tasks.first(where: { $0.id == assignment.taskID }), !linked.cancelled else {
                    pendingToggleSyncIssue = "待同步任务的关联已变化，请逐项检查；本机操作已保留。"
                    return
                }
                if linked.isCompleted == draft.isCompleted { removePendingPeriodDraft(draft); continue }
                do {
                    let value = try await client.togglePeriod(dayID: assignment.date, periodID: assignment.periodID, taskID: assignment.legacyTaskID,
                        isCompleted: draft.isCompleted, baseRevision: latest.revision, idempotencyKey: draft.idempotencyKey!,
                        logicalTaskID: linked.id, assignmentID: assignment.id, timeoutInterval: 12)
                    guard !Task.isCancelled, isForeground, generation == clientGeneration, repositoryGeneration == self.repositoryGeneration else { return }
                    snapshot = value; saveCache(value)
                    guard value.week.linkage?.tasks.first(where: { $0.id == linked.id })?.isCompleted == draft.isCompleted else {
                        pendingToggleSyncIssue = "服务端未确认任务完成状态，本机操作已保留。"; return
                    }
                    removePendingPeriodDraft(draft); continue
                } catch {
                    guard !Task.isCancelled, isForeground, generation == clientGeneration, repositoryGeneration == self.repositoryGeneration else { return }
                    pendingToggleSyncIssue = "任务补交未完成：\(error.localizedDescription)"; return
                }
            }
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
                guard !Task.isCancelled, isForeground, generation == clientGeneration,
                      repositoryGeneration == self.repositoryGeneration else { return }
                guard let updated = matchingPeriod(dayID: draft.dayID, periodID: draft.periodID, in: value),
                      updated.period.tasks.first(where: { $0.id == taskID })?.isCompleted == draft.isCompleted else {
                    snapshot = value
                    state = .online
                    saveCache(value)
                    pendingToggleSyncIssue = "学业服务 未确认一个时段任务的目标状态，自动同步已暂停。"
                    return
                }
                snapshot = value
                state = .online
                lastConnectionIssue = nil
                saveCache(value)
                removePendingPeriodDraft(draft)
            } catch {
                guard !Task.isCancelled, isForeground, generation == clientGeneration,
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
                    pendingToggleSyncIssue = "计划已在服务端变化，时段同步未完成。请重新加载后重试。"
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

    private func pendingDeliveryKey(_ draft: PendingDeliveryToggle) -> String {
        if let id = draft.deliveryID { return id }
        if let snapshot, snapshot.week.linkage != nil, let value = matchingDelivery(text: draft.text, in: snapshot) { return value.id }
        return draft.text
    }

    private func deliveryQueueKey(_ delivery: DeliverySnapshot) -> String { snapshot?.week.linkage == nil ? delivery.text : delivery.id }

    private func matchingDelivery(text: String, id: String? = nil, in snapshot: SnapshotResponse) -> DeliverySnapshot? {
        if let id, let graph = snapshot.week.linkage,
           let delivery = graph.deliveries.first(where: { $0.id == id && !$0.cancelled }) {
            return DeliverySnapshot(id: id, text: delivery.text, isCompleted: graph.isCompleted(delivery))
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = snapshot.week.deliveries.filter {
            id == nil ? $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalized : $0.id == id
        }
        return matches.count == 1 ? matches.first : nil
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
        // Scheduled-row IDs are stable UI identities, not ISO day IDs. Match
        // deferred rows by their date labels so queued historical operations
        // remain addressable after the rolling seven-day window advances.
        for row in snapshot.week.historicalRows + snapshot.week.futureRows {
            guard scheduledRow(row, matchesDayID: dayID),
                  let period = row.slots.first(where: { $0.id == periodID }) else {
                continue
            }
            return (row.dateLabel, period)
        }
        return nil
    }

    private func scheduledRow(_ row: ScheduledRowSnapshot, matchesDayID dayID: String) -> Bool {
        let target = dayID.split(separator: "-").compactMap { Int($0) }
        guard target.count == 3 else { return false }
        let values = row.dateLabel.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard values.count == 2 || values.count == 3 else { return false }
        guard values.suffix(2).elementsEqual(target.suffix(2)) else { return false }
        return values.count == 2 || values[0] == target[0]
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
              !Task.isCancelled, isForeground, generation == clientGeneration else { return nil }
        snapshot = value
        state = .online
        lastConnectionIssue = nil
        saveCache(value)
        return (value, matchingDelivery(text: delivery.text, id: snapshot?.week.linkage == nil ? nil : delivery.id, in: value)?.isCompleted == isCompleted)
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
              !Task.isCancelled, isForeground, generation == clientGeneration else { return nil }
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
        guard !Self.isRequestCancellation(error) else { return }
        let contextualized = MobileEndpointError.contextualized(error)
        guard isTransportOrConnectionFailure(contextualized) else { return }
        lastConnectionIssue = contextualized.localizedDescription
        state = connectionFailureState(for: contextualized)
    }

    private static func isRequestCancellation(_ error: Error) -> Bool {
        // A terminal SSE event cancels the history recovery task while its URL
        // request may still be in flight. Neither form is a server turn failure.
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
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
        pendingReplayToken = nil
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
        cancelConnectionRetry()
        automaticRefreshBlocked = false
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskToken = nil
        isRefreshingSnapshot = false
        cancelPendingSynchronization()
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
        chatTerminalReceipts.removeAll()
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

    func replaceClient(with newClient: StudyRocketRemoteClient, endpoint: URL, persistEndpoint: Bool, incomingRepositoryID: String? = nil) throws {
        cancelConnectionRetry()
        automaticRefreshBlocked = false
        let sameRepository = incomingRepositoryID != nil && incomingRepositoryID == activeRepositoryID
        let sameService = Self.sameEndpoint(clientEndpoint, endpoint) && (incomingRepositoryID == nil || sameRepository)
        let preserveActive = sameRepository || sameService
        if !preserveActive { try preserveCurrentQueue() }
        // Same stable repository moved to another endpoint: retain operation IDs and
        // CAS revisions, but rebind fact transport only after authenticated pairing.
        if sameRepository && !Self.sameEndpoint(clientEndpoint, endpoint) {
            let rebound = factQueue.map { item in
                item.repositoryID == incomingRepositoryID && (item.endpoint == nil || Self.sameEndpoint(item.endpoint, clientEndpoint ?? endpoint))
                    ? QueuedFact(repositoryID: item.repositoryID, endpoint: endpoint, fact: item.fact) : item
            }
            try persistFacts(rebound)
            if let data = try? Data(contentsOf: cloudChatsURL) {
                let entries = try JSONDecoder().decode([PendingCloudChat].self, from: data)
                let reboundChats = entries.map { item in
                    item.repositoryID == incomingRepositoryID && (item.endpoint == nil || Self.sameEndpoint(item.endpoint, clientEndpoint ?? endpoint))
                        ? PendingCloudChat(id: item.id, text: item.text, attachmentIDs: item.attachmentIDs, terminalReadOperationID: item.terminalReadOperationID, endpoint: endpoint, repositoryID: item.repositoryID) : item
                }
                try JSONEncoder().encode(reboundChats).write(to: cloudChatsURL, options: .atomic)
            }
        }
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskToken = nil
        isRefreshingSnapshot = false
        cancelPendingSynchronization()
        stopEventStream()
        clientGeneration &+= 1
        advanceRepositoryGeneration()
        client = newClient
        clientEndpoint = endpoint
        if persistEndpoint {
            UserDefaults.standard.set(endpoint.absoluteString, forKey: endpointKey)
        }
        if !preserveActive { clearRemoteHostState() }
        state = .connecting
    }

    private func advanceRepositoryGeneration() {
        cancelPendingSynchronization()
        conversationToken = UUID(); conversationTask?.cancel(); conversationTask = nil
        refreshingConversation = false; conversationRefreshError = nil
        lastChatIssue = nil; lastChatIssueCode = nil; lastFailedChatText = nil
        retryingChat = false; failedChatTurnID = nil; failedChatPendingID = nil; failedChatWasRejected = false
        factSyncToken = nil; factSyncError = nil
        pendingReplayTask?.cancel()
        pendingReplayTask = nil
        pendingReplayToken = nil
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
        archivedHistory = []; archivedHistoryCursor = nil; archivedHistoryLoaded = false
        archivedHistoryLoading = false; archivedHistoryError = nil
        chatRevision &+= 1
        proposals = []
        documentDetails = [:]
        chatTerminalReceipts.removeAll()
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
        chatDraftStore.bind(repository: nil)
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
        pendingDeliveryStates = Dictionary(value.deliveries.map { (pendingDeliveryKey($0), $0.isCompleted) }, uniquingKeysWith: { _, latest in latest })
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
            periods: existing.periods,
            events: existing.events,
            eventBaseHash: existing.eventBaseHash,
            weekBaseRevision: existing.weekBaseRevision,
            dailyBaseRevision: existing.dailyBaseRevision, dailyOperationID: existing.dailyOperationID
        )
        pendingWeekDraft = drafts.week
        pendingDailyDraft = drafts.daily
        pendingDeliveryCount = drafts.deliveries.count
        pendingDeliveryStates = Dictionary(drafts.deliveries.map { (pendingDeliveryKey($0), $0.isCompleted) }, uniquingKeysWith: { _, latest in latest })
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

    func currentWeekDeliveries(at date: Date = .now) -> [DeliverySnapshot] {
        guard let snapshot else { return [] }
        if let graph = snapshot.week.linkage { return graph.projected(snapshot.week, now: date).deliveries }
        guard WeeklyDeliveryRollover.weekStart(snapshot.fetchedAt) < WeeklyDeliveryRollover.weekStart(date) else {
            return snapshot.week.deliveries
        }
        return snapshot.week.deliveries.filter { !$0.isCompleted || isDeliveryTogglePending($0) }
    }

    func isEmptyPlanDay(_ day: DaySnapshot) -> Bool {
        func hasTasks(_ value: DaySnapshot) -> Bool {
            value.slots.contains { !$0.tasks.isEmpty || !PeriodTaskParser.tasks(from: $0.text).isEmpty }
                || !PeriodTaskParser.tasks(from: value.unassigned).isEmpty
        }
        let draft = pendingWeekDraft?.days.first { $0.id == day.id }
        return !hasTasks(day) && !(draft.map(hasTasks) ?? false)
            && !pendingPeriodStates.keys.contains { $0.hasPrefix(day.id + "|") }
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
                chatIssueCode: current.chatIssueCode,
                backend: current.backend, capabilities: current.capabilities
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
    case tlsFailure

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            if let selfCheckPort = Self.selfCheckSimulatorLoopbackHTTPPort {
                return "Host 地址必须是无账号、查询参数和子路径的完整 HTTPS 地址；本机模拟器调试可使用 http://localhost:43817，SelfCheck 运行可使用 http://localhost:\(selfCheckPort)。"
            }
            if Self.simulatorLoopbackHTTPEnabled {
                return "Host 地址必须是无账号、查询参数和子路径的完整 HTTPS 地址；仅本机模拟器调试可使用 http://localhost:43817。"
            }
            return "Host 地址必须是无账号、查询参数和子路径的完整 HTTPS 地址。"
        case .tlsFailure: return "安全连接失败，请检查服务证书、网络和系统时间；待提交草稿已保留。"
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
            return MobileEndpointError.tlsFailure
        default:
            return error
        }
    }

    static func accepts(
        _ url: URL,
        allowSimulatorLoopbackHTTP: Bool = simulatorLoopbackHTTPEnabled,
        selfCheckSimulatorLoopbackPort: Int? = selfCheckSimulatorLoopbackHTTPPort
    ) -> Bool {
        let isSimpleHostAddress = url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
            && url.query == nil
            && url.fragment == nil
            && (url.path.isEmpty || url.path == "/")
        guard isSimpleHostAddress else { return false }

        if url.scheme?.lowercased() == "https" { return true }

        guard url.scheme?.lowercased() == "http",
              url.host?.lowercased() == "localhost" else {
            return false
        }

        // The production Debug fixture retains its explicit 43817 opt-in.
        if allowSimulatorLoopbackHTTP,
           url.port == nil || url.port == Int(StudyRocketAPI.defaultHostPort) {
            return true
        }

        // A second local Host is reserved for the isolated SelfCheck app.
        // It is unavailable on devices and cannot reuse the production port.
        guard let selfCheckSimulatorLoopbackPort else { return false }
        return url.port == selfCheckSimulatorLoopbackPort
    }

    private static var simulatorLoopbackHTTPEnabled: Bool {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--studyrocket-simulator-loopback-http")
        #else
        return false
        #endif
    }

    private static var selfCheckSimulatorLoopbackHTTPPort: Int? {
        #if targetEnvironment(simulator)
        return selfCheckLoopbackPort(
            arguments: ProcessInfo.processInfo.arguments,
            isSelfCheckRuntime: Bundle.main.bundleIdentifier == "com.skyfrost.ncustudyrocket.mobile.selfcheck"
        )
        #else
        return nil
        #endif
    }

    static func selfCheckLoopbackPort(arguments: [String], isSelfCheckRuntime: Bool) -> Int? {
        guard isSelfCheckRuntime,
              arguments.contains("--studyrocket-self-check") else {
            return nil
        }

        let portFlagIndices = arguments.indices.filter { arguments[$0] == "--self-check-port" }
        guard portFlagIndices.count == 1,
              let portFlagIndex = portFlagIndices.first else {
            return nil
        }
        let portValueIndex = arguments.index(after: portFlagIndex)
        guard portValueIndex < arguments.endIndex,
              let port = Int(arguments[portValueIndex]),
              (1_024...65_535).contains(port),
              port != Int(StudyRocketAPI.defaultHostPort) else {
            return nil
        }
        return port
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
            return "学业服务 协议版本不兼容（Host: \(received)，手机: \(StudyRocketAPI.version)），请同时更新两端。"
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
    private var lastEventID: String?

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
        request.timeoutInterval = 12
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

    public func health(timeoutInterval: TimeInterval? = nil) async throws -> HealthResponse {
        let value = try await get("/v1/health", timeoutInterval: timeoutInterval, as: HealthResponse.self)
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

    public func attachmentJSON(path: String, body: Data) async throws -> Data {
        guard path.hasPrefix("/v1/attachments/") else { throw URLError(.badURL) }
        var request = URLRequest(url: URL(string: path, relativeTo: endpoint)!.absoluteURL)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try authenticate(&request)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return data
    }

    public func sendChat(text: String, clientRequestID: String = UUID().uuidString, attachmentIDs: [String] = []) async throws -> ChatHistoryResponse? {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/chat/send"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SendChatRequest(text: text, clientRequestID: clientRequestID, attachmentIDs: attachmentIDs.isEmpty ? nil : attachmentIDs))
        try authenticate(&request)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try? JSONDecoder().decode(ChatHistoryResponse.self, from: data)
    }

    public func cloudVersions(after: Int = 0) async throws -> CloudVersionPage {
        try await get("/v1/versions?after=\(after)&limit=50", as: CloudVersionPage.self)
    }
    public func cloudVersion(id: String, path: String) async throws -> CloudFileContent {
        try await post("/v1/versions/read", body: CloudVersionReadRequest(id: id, path: path), as: CloudFileContent.self)
    }

    public func archivedHistory(after: Int = 0) async throws -> CloudHistoryPage {
        try await get("/v1/history?after=\(after)&limit=100", as: CloudHistoryPage.self)
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
                    if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
                    try authenticate(&request)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw StudyRocketRemoteError(body: APIErrorBody(code: "events_unavailable", message: "学业服务 事件连接失败。", retryable: true))
                    }
                    var candidateEventID = lastEventID
                    for try await line in bytes.lines {
                        if line.hasPrefix("id: ") { candidateEventID = String(line.dropFirst(4)); continue }
                        guard line.hasPrefix("data: ") else { continue }
                        let data = Data(line.dropFirst(6).utf8)
                        if let event = try? JSONDecoder().decode(HostEventEnvelope.self, from: data) {
                            continuation.yield(event)
                            lastEventID = candidateEventID
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

    public func interruptChat(turnID: String, operationID: String = UUID().uuidString) async throws -> ChatInterruptResponse {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/chat/interrupt"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(InterruptRequest(turnID: turnID, operationID: operationID))
        try authenticate(&request)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let receipt = try JSONDecoder().decode(ChatInterruptResponse.self, from: data)
        guard receipt.targetTurnID == turnID, receipt.operationID == operationID,
              receipt.terminal.map({ $0.turnID == turnID && ["completed", "failed", "interrupted"].contains($0.status) && $0.status == receipt.status }) ?? !["completed", "failed", "interrupted"].contains(receipt.status) else {
            throw StudyRocketRemoteError(body: APIErrorBody(code: "invalid_interrupt_receipt", message: "停止回执与目标回复不匹配，未继续发送。"))
        }
        return receipt
    }

    public func proposals() async throws -> ProposalListResponse {
        try await get("/v1/proposals", as: ProposalListResponse.self)
    }

    public func proposalChallenge() async throws -> ProposalAuthorizationChallenge {
        try await get("/v1/proposals/challenge", as: ProposalAuthorizationChallenge.self)
    }

    public func applyProposals(ids: [String], authorization: String, baseRevision: String, idempotencyKey: String = UUID().uuidString) async throws -> ProposalApplyResponse {
        try await post("/v1/proposals/apply", body: ProposalApplyRequest(proposalIDs: ids, authorization: authorization, metadata: WriteMetadata(baseRevision: baseRevision, idempotencyKey: idempotencyKey)), as: ProposalApplyResponse.self)
    }

    public func operationStatus(id: String) async throws -> CloudOperationStatus {
        let value = try await get("/v1/operations/\(id)", as: CloudOperationStatus.self)
        guard value.id == id else { throw StudyRocketRemoteError(body: APIErrorBody(code: "invalid_operation_receipt", message: "操作回执编号不匹配，未继续发送。")) }
        return value
    }

    public func applyWeek(plan: WeeklyPlanSnapshot, baseRevision: String, events: [OneOffEvent]? = nil, eventBaseHash: String? = nil) async throws -> SnapshotResponse {
        try await post("/v1/week", body: PlanWriteRequest(plan: plan, metadata: WriteMetadata(baseRevision: baseRevision), events: events, eventBaseHash: eventBaseHash), as: SnapshotResponse.self)
    }

    public func toggleDelivery(
        text: String,
        isCompleted: Bool,
        baseRevision: String,
        idempotencyKey: String,
        deliveryID: String? = nil,
        confirmedTaskIDs: [String]? = nil,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> SnapshotResponse {
        try await post(
            "/v1/deliveries/toggle",
            body: DeliveryToggleRequest(
                text: text,
                isCompleted: isCompleted,
                metadata: WriteMetadata(baseRevision: baseRevision, idempotencyKey: idempotencyKey),
                deliveryID: deliveryID,
                confirmedTaskIDs: confirmedTaskIDs
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
        logicalTaskID: String? = nil,
        assignmentID: String? = nil,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> SnapshotResponse {
        try await post(
            "/v1/periods/toggle",
            body: PeriodCompletionToggleRequest(
                dayID: dayID,
                periodID: periodID,
                taskID: taskID,
                isCompleted: isCompleted,
                metadata: WriteMetadata(baseRevision: baseRevision, idempotencyKey: idempotencyKey),
                logicalTaskID: logicalTaskID,
                assignmentID: assignmentID
            ),
            timeoutInterval: timeoutInterval,
            as: SnapshotResponse.self
        )
    }

    public func appendFact(_ fact: QuickFact, repo: String, revision: String) async throws -> SnapshotResponse {
        try await post("/v1/facts", body: FactWriteRequest(entry: fact, metadata: WriteMetadata(baseRevision: revision, idempotencyKey: fact.id.uuidString), repositoryID: repo), as: SnapshotResponse.self)
    }

    public func saveDaily(entry: DailySnapshot, baseRevision: String, idempotencyKey: String = UUID().uuidString) async throws -> SnapshotResponse {
        try await post("/v1/daily", body: DailyWriteRequest(entry: entry, metadata: WriteMetadata(baseRevision: baseRevision, idempotencyKey: idempotencyKey)), as: SnapshotResponse.self)
    }

    private func get<T: Decodable>(_ path: String, timeoutInterval: TimeInterval? = nil, as type: T.Type) async throws -> T {
        var request = URLRequest(url: URL(string: path, relativeTo: endpoint)!.absoluteURL)
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
        var request = URLRequest(url: URL(string: path, relativeTo: endpoint)!.absoluteURL)
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
            throw StudyRocketRemoteError(body: APIErrorBody(code: "http_error", message: "学业服务 暂时不可用。", retryable: true))
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
        let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "确认将选定学业草案写入正式云仓库")
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


struct MobileQueueMigrationItem: Identifiable {
    let id: String
    let title: String
    let original: String
    let current: String
    let reason: String
    let canSubmit: Bool
}

extension MobileSession {
    private var migrationReceiptsURL: URL { queueArchiveURL.appendingPathComponent("receipts.json") }
    private func migrationReceipts() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: migrationReceiptsURL))) ?? [:]
    }
    private func migrationReceiptKey(_ archive: PreservedQueue, _ item: String) -> String { archive.id.uuidString + "/" + item }
    private func migrationMatches(_ archive: PreservedQueue) -> Bool {
        guard isCloudService, let old = archive.repositoryID, let current = activeRepositoryID else { return false }
        return old == current || old == health?.legacyRepositoryID
    }
    /// Completion fields are the only allowed difference. Every task ID, text,
    /// assignment, date and linked child remains part of this content fingerprint.
    private func migrationFingerprint(_ week: WeeklyPlanSnapshot) -> Data? {
        func strip(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                return dict.filter { !["isCompleted", "completedAt", "completionSource", "completionOperationID"].contains($0.key) }.mapValues(strip)
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        guard let data = try? JSONEncoder().encode(week), let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return try? JSONSerialization.data(withJSONObject: strip(object), options: [.sortedKeys])
    }
    private func migrationBaseMatches(_ archive: PreservedQueue, _ current: SnapshotResponse) -> Bool {
        guard let data = archive.cachedSnapshot,
              let base = try? JSONDecoder().decode(SnapshotResponse.self, from: data),
              let hash = migrationFingerprint(base.week) else { return false }
        return hash == migrationFingerprint(current.week)
    }
    private func migrationDrafts(_ archive: PreservedQueue) -> MobilePendingDrafts? {
        archive.drafts.flatMap { try? JSONDecoder().decode(MobilePendingDrafts.self, from: $0) }
    }
    private func migrationFacts(_ archive: PreservedQueue) -> [QueuedFact] {
        (archive.facts.flatMap { try? JSONDecoder().decode([QueuedFact].self, from: $0) } ?? []).filter { $0.repositoryID == archive.repositoryID }
    }
    private func migrationDifference(current: String, candidate: String) -> String {
        let difference = candidate.components(separatedBy: "\n").difference(from: current.components(separatedBy: "\n"))
        let lines = difference.map { change -> String in
            switch change {
            case .remove(_, let line, _): return "- " + line
            case .insert(_, let line, _): return "+ " + line
            }
        }
        return lines.isEmpty ? "内容相同" : "差异（- 当前云内容 / + 原草稿）\n" + lines.joined(separator: "\n")
    }
    private func migrationPretty<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "无法读取，原始归档仍保留"
    }
    func queueMigrationItems(_ archive: PreservedQueue) -> [MobileQueueMigrationItem] {
        let mapped = migrationMatches(archive)
        let ready = mapped && state == .online && snapshot != nil
        let sameBase = snapshot.map { migrationBaseMatches(archive, $0) } ?? false
        let receipts = migrationReceipts()
        var items: [MobileQueueMigrationItem] = []
        func append(_ id: String, _ title: String, _ original: String, _ current: String, _ valid: Bool, _ detail: String) {
            let done = receipts[migrationReceiptKey(archive, id)] == activeRepositoryID && activeRepositoryID != nil
            items.append(.init(id: id, title: title, original: original, current: current,
                reason: done ? "云端已确认；原始归档继续保留" : !mapped ? "仓库身份未匹配，保留待审核" : detail,
                canSubmit: ready && valid && !done))
        }
        for queued in migrationFacts(archive) {
            let fact = queued.fact
            let existing = snapshot?.recentFacts?.first { $0.id == fact.id }
            let valid = existing == nil || existing == fact
            append("fact:" + fact.id.uuidString, "事实 · " + fact.date, fact.text + "\nUUID: " + fact.id.uuidString,
                existing?.text ?? "近期记录中未找到；提交时服务端仍会检查全部历史中的原 UUID",
                valid, valid ? "确认后以原 UUID 提交；同编号不同内容会停止并保留" : "同 UUID 内容不一致，禁止提交")
        }
        if let drafts = migrationDrafts(archive) {
            for (index, draft) in drafts.deliveries.enumerated() {
                let current = snapshot?.week.deliveries.first { $0.id == draft.deliveryID }
                let stable = draft.deliveryID != nil && current?.text == draft.text && draft.idempotencyKey != nil
                append("delivery:\(index)", "交付物 · " + draft.text,
                    "目标：" + (draft.isCompleted ? "完成" : "未完成") + "\nID: " + (draft.deliveryID ?? "缺失"),
                    current.map { $0.text + ($0.isCompleted ? "（已完成）" : "（未完成）") } ?? "当前没有唯一匹配项",
                    stable && sameBase, stable && sameBase ? "稳定 ID 与原缓存内容一致；确认后提交原目标状态" : "原缓存内容、稳定 ID 或操作编号不足/已变化；请保留并在当前计划重新核对")
            }
            for (index, draft) in drafts.periods.enumerated() {
                let graph = snapshot?.week.linkage
                let task = graph?.tasks.first { $0.id == draft.logicalTaskID }
                let assignment = graph?.assignments.first { $0.id == draft.assignmentID && $0.taskID == draft.logicalTaskID && $0.active }
                let plain = snapshot.flatMap { matchingPeriod(dayID: draft.dayID, periodID: draft.periodID, in: $0) }?.period.tasks.filter { $0.id == draft.taskID }
                let originalSnapshot = archive.cachedSnapshot.flatMap { try? JSONDecoder().decode(SnapshotResponse.self, from: $0) }
                let originalTask = originalSnapshot.flatMap { matchingPeriod(dayID: draft.dayID, periodID: draft.periodID, in: $0) }?.period.tasks.first { $0.id == draft.taskID }
                let linkedMatch = task != nil && task?.cancelled == false && assignment != nil
                let plainMatch = graph == nil && plain?.count == 1 && originalTask != nil
                let stable = (linkedMatch || plainMatch) && draft.taskID != nil && draft.idempotencyKey != nil
                append("period:\(index)", "时段任务 · " + (originalTask?.text ?? task?.text ?? draft.dayID + " " + draft.periodID),
                    (originalTask?.text ?? "原文字见缓存/归档") + "\n目标：" + (draft.isCompleted ? "完成" : "未完成") + "\n任务 ID: " + (draft.logicalTaskID ?? draft.taskID ?? "缺失"),
                    task.map { $0.text + ($0.isCompleted ? "（已完成）" : "（未完成）") } ?? plain?.first.map { $0.text + ($0.isCompleted ? "（已完成）" : "（未完成）") } ?? "当前没有稳定任务匹配",
                    stable && sameBase, stable && sameBase ? "任务、安排 ID 与原缓存内容一致；确认后提交原目标状态" : "缺少可证明的原缓存/关联 ID 或内容已变化，保留待审")
            }
            if let week = drafts.week { append("week", "整份周计划草稿", migrationPretty(week), snapshot.map { migrationPretty($0.week) } ?? "服务尚不可用", false, "旧 revision 不可复用。此处只作对照，请在当前计划中手动合并后保存；原稿保留") }
            if let daily = drafts.daily { append("daily", "旧每日行为账草稿", migrationPretty(daily), snapshot.map { migrationPretty($0.daily) } ?? "服务尚不可用", false, "原始基线不明，只作对照，请核对日期后在当前行为账处理") }
            if let events = drafts.events { append("events", "旧活动草稿", migrationPretty(events), "请在当前课表对照", false, "原始课表基线不可证明，保留待审") }
        }
        if !archive.input.isEmpty { append("input", "未发送文字", archive.input, "未自动发送", false, "可复制到学业对话继续处理") }
        if let data = archive.chats, let chats = try? JSONDecoder().decode([PendingCloudChat].self, from: data) {
            for chat in chats { append("chat:" + chat.id, "结果未确认的旧对话", chat.text, "请求 ID: " + chat.id, false, "请先查完整文字历史，避免重复发送已完成回合") }
        }
        return items
    }
    /// A reviewed migration is a new, explicitly confirmed CAS against the shown
    /// cloud state. It never relabels a whole legacy draft's revision.
    func submitQueueMigrationItem(_ archive: PreservedQueue, itemID: String) async throws {
        guard let client, let repo = activeRepositoryID, let preview = snapshot,
              queueMigrationItems(archive).contains(where: { $0.id == itemID && $0.canSubmit }) else { throw FactError("该项目尚不能安全迁移，请核对原仓库和内容。") }
        let generation = clientGeneration
        let repositoryGeneration = self.repositoryGeneration
        let latest = try await client.snapshot()
        guard generation == clientGeneration, repositoryGeneration == self.repositoryGeneration else { throw FactError("连接已变化，原稿仍保留。") }
        snapshot = latest; saveCache(latest)
        guard latest.revision == preview.revision,
              queueMigrationItems(archive).contains(where: { $0.id == itemID && $0.canSubmit }) else { throw FactError("云内容已更新，请查看最新对照后重新确认。") }
        let result: SnapshotResponse
        if itemID.hasPrefix("fact:"), let fact = migrationFacts(archive).map(\.fact).first(where: { "fact:" + $0.id.uuidString == itemID }) {
            result = try await client.appendFact(fact, repo: repo, revision: latest.revision)
        } else if itemID.hasPrefix("delivery:"), let index = Int(itemID.dropFirst(9)), let drafts = migrationDrafts(archive), drafts.deliveries.indices.contains(index) {
            let draft = drafts.deliveries[index]
            result = try await client.toggleDelivery(text: draft.text, isCompleted: draft.isCompleted, baseRevision: latest.revision,
                idempotencyKey: draft.idempotencyKey!, deliveryID: draft.deliveryID, confirmedTaskIDs: draft.confirmedTaskIDs)
            guard result.week.deliveries.first(where: { $0.id == draft.deliveryID })?.isCompleted == draft.isCompleted else { throw FactError("服务端未确认目标状态，原稿保留。") }
        } else if itemID.hasPrefix("period:"), let index = Int(itemID.dropFirst(7)), let drafts = migrationDrafts(archive), drafts.periods.indices.contains(index) {
            let draft = drafts.periods[index]
            let assignment = latest.week.linkage?.assignments.first(where: { $0.id == draft.assignmentID })
            result = try await client.togglePeriod(dayID: assignment?.date ?? draft.dayID, periodID: assignment?.periodID ?? draft.periodID, taskID: assignment?.legacyTaskID ?? draft.taskID!,
                isCompleted: draft.isCompleted, baseRevision: latest.revision, idempotencyKey: draft.idempotencyKey!, logicalTaskID: draft.logicalTaskID, assignmentID: draft.assignmentID)
            let confirmed = draft.logicalTaskID.flatMap { id in result.week.linkage?.tasks.first { $0.id == id }?.isCompleted }
                ?? matchingPeriod(dayID: draft.dayID, periodID: draft.periodID, in: result)?.period.tasks.first { $0.id == draft.taskID }?.isCompleted
            guard confirmed == draft.isCompleted else { throw FactError("服务端未确认目标状态，原稿保留。") }
        } else { throw FactError("此草稿仅供对照，不会覆盖云内容。") }
        guard generation == clientGeneration, repositoryGeneration == self.repositoryGeneration else { throw FactError("连接已变化，请重新核对云端回执。") }
        snapshot = result; saveCache(result)
        var receipts = migrationReceipts(); receipts[migrationReceiptKey(archive, itemID)] = repo
        try JSONEncoder().encode(receipts).write(to: migrationReceiptsURL, options: .atomic)
        objectWillChange.send()
    }
}

// MARK: - Plan organization continuity and proposal receipts
extension MobileSession {
    private func organizationStorageURL(endpoint: URL, repository: String, name: String) -> URL {
        let scope = PeriodCompletion.textHash(for: endpoint.absoluteString + "|" + repository)
        return cacheURL.deletingLastPathComponent().appendingPathComponent("\(name)-\(scope).json")
    }
    var currentOrganization: MobileOrganizationWorkflow? {
        guard let organization, organization.endpoint == clientEndpoint,
              organization.repositoryID == activeRepositoryID else { return nil }
        return organization
    }
    var organizationProposals: [ProposalDTO] { currentOrganization?.proposals(from: proposals) ?? [] }
    var organizationIsRunning: Bool {
        guard isChatBusy, let round = currentOrganization?.latestRound else { return false }
        return activeChatRequest?.operationID == round.requestID || (round.turnID != nil && observedChatTurnID == round.turnID)
    }
    var canStartOrganization: Bool {
        isChatAvailable && !isChatBusy && !organizationStarting && pendingWeekDraft == nil
    }
    private func loadOrganization() {
        guard let endpoint = clientEndpoint, let repository = activeRepositoryID else { organization = nil; return }
        if currentOrganization != nil { return }
        let url = organizationStorageURL(endpoint: endpoint, repository: repository, name: "organization")
        organization = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(MobileOrganizationWorkflow.self, from: $0) }
    }
    private func storeOrganization(_ value: MobileOrganizationWorkflow) throws {
        let url = organizationStorageURL(endpoint: value.endpoint, repository: value.repositoryID, name: "organization")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        organization = value
    }
    private func updateOrganization(_ update: (inout MobileOrganizationWorkflow) -> Void) {
        guard var value = currentOrganization else { return }
        update(&value)
        do { try storeOrganization(value) }
        catch { lastChatIssue = "整理进度未能保存在本机，请保留当前页面。" }
    }
    func setOrganizationClarification(_ text: String) {
        updateOrganization { $0.clarificationDraft = text }
    }
    private func isOrganizationRequest(_ id: String) -> Bool {
        loadOrganization()
        return currentOrganization?.rounds.contains(where: { $0.requestID == id }) == true
    }
    /// Starts directly without borrowing or replacing the chat composer's draft.
    func startOrganization() async {
        loadOrganization()
        if let existing = currentOrganization, existing.phase != .applied {
            await refreshOrganization()
            return
        }
        guard canStartOrganization, let endpoint = clientEndpoint, let repository = activeRepositoryID else { return }
        organizationStarting = true
        defer { organizationStarting = false }
        do {
            try storeOrganization(MobileOrganizationWorkflow(endpoint: endpoint, repositoryID: repository))
            await sendOrganizationRound(MobileOrganizationWorkflow.prompt)
        } catch { lastChatIssue = "无法保存整理请求，未发送。" }
    }
    func sendOrganizationClarification() async {
        guard let workflow = currentOrganization,
              workflow.phase == .clarification || workflow.phase == .ready || workflow.phase == .failed,
              !workflow.clarificationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = "继续当前周计划整理。我的补充：\n" + workflow.clarificationDraft + "\n请仍保留原任务文字、日期、时段、ID、完成状态和历史；不要重新排期。本轮如信息充分，请提交完整的可确认草案。"
        await sendOrganizationRound(text)
    }
    private func sendOrganizationRound(_ text: String) async {
        guard !isChatBusy, isChatAvailable, pendingWeekDraft == nil, var workflow = currentOrganization else { return }
        let id = UUID().uuidString
        workflow.rounds.append(.init(requestID: id, turnID: isCloudService ? id : nil,
            prompt: text, startedAt: .now, priorTurnIDs: chatMessages.compactMap(\.turnID)))
        workflow.phase = .requesting; workflow.issue = nil
        workflow.previewRevision = nil; workflow.previewProposalIDs = nil
        do { try storeOrganization(workflow) }
        catch { lastChatIssue = "无法保存整理请求，未发送。"; return }
        await sendChatText(text, clearComposer: false, requestedID: id)
        guard currentOrganization?.latestRound?.requestID == id else { return }
        if failedChatWasRejected || (activeChatRequest == nil && currentOrganization?.latestRound?.status == "inProgress" && lastChatIssue != nil) {
            updateOrganization { $0.phase = .failed; $0.issue = lastChatIssue ?? "本轮未发送，请稍后重试。"; $0.rounds[$0.rounds.count - 1].status = "failed" }
        } else {
            updateOrganization { $0.clarificationDraft = "" }
        }
    }
    private func bindOrganizationTurn(requestID: String, turnID: String) {
        loadOrganization()
        guard currentOrganization?.latestRound?.requestID == requestID else { return }
        updateOrganization { $0.rounds[$0.rounds.count - 1].turnID = turnID }
    }
    private func settleOrganization(terminal: ChatTurnTerminalDTO) {
        loadOrganization()
        guard let round = currentOrganization?.latestRound,
              round.turnID == terminal.turnID || round.requestID == terminal.turnID else { return }
        updateOrganization { workflow in
            let index = workflow.rounds.count - 1
            workflow.rounds[index].turnID = terminal.turnID
            workflow.rounds[index].status = terminal.status
            // Never turn an already confirmed receipt back into a draft on SSE replay.
            guard workflow.phase != .applied && workflow.phase != .applying && workflow.phase != .receiptUnknown else { return }
            workflow.phase = terminal.status == "completed" ? .clarification : .failed
            workflow.issue = terminal.status == "completed" ? nil : (terminal.message ?? "本轮整理未完成，可在这里补充后重新发起。")
        }
    }
    private func reconcileOrganizationHistory(_ history: ChatHistoryResponse) {
        loadOrganization()
        guard let round = currentOrganization?.latestRound else { return }
        var turnID = round.turnID
        if turnID == nil {
            let candidates = history.messages.filter {
                $0.role == "user" && $0.text == round.prompt && $0.date >= round.startedAt.addingTimeInterval(-2)
                    && !round.priorTurnIDs.contains($0.turnID ?? "") && $0.turnID != nil
            }
            let ids = Set(candidates.compactMap(\.turnID))
            if ids.count == 1, let id = ids.first { turnID = id; bindOrganizationTurn(requestID: round.requestID, turnID: id) }
        }
        guard let turnID else { return }
        let replies = history.messages.filter { $0.turnID == turnID && $0.role == "assistant" }.map(\.text).joined(separator: "\n\n")
        if !replies.isEmpty { updateOrganization { $0.rounds[$0.rounds.count - 1].reply = replies } }
        if let terminal = history.terminalTurns?.last(where: { $0.turnID == turnID }) {
            settleOrganization(terminal: terminal)
        } else if let status = history.messages.last(where: { $0.turnID == turnID })?.status, Self.isTerminalChatStatus(status) {
            settleOrganization(terminal: .init(turnID: turnID, status: status))
        }
    }
    private func prepareOrganizationPreview() {
        loadOrganization()
        guard let workflow = currentOrganization, workflow.latestRound?.status == "completed",
              workflow.phase == .clarification || workflow.phase == .ready else { return }
        let ids = organizationProposals.map(\.id).sorted()
        guard !ids.isEmpty else { return }
        updateOrganization {
            if $0.previewProposalIDs != ids { $0.previewProposalIDs = ids; $0.previewRevision = snapshot?.revision }
            $0.phase = .ready
        }
    }
    /// Called after foreground recovery and on reopening the sheet. No POST here.
    func refreshOrganization() async {
        loadOrganization()
        if currentOrganization?.phase == .applying, !isApplyingProposals, loadProposalApplication()?.submitted != true {
            updateOrganization { $0.phase = .ready; $0.issue = "上次确认尚未提交，请重新确认。" }
        }
        if let operation = loadProposalApplication(), operation.submitted {
            let generation = clientGeneration, repository = repositoryGeneration
            let workflowID = currentOrganization?.id
            let outcome = await reconcileProposalApplication(operation)
            guard generation == clientGeneration, repository == repositoryGeneration, currentOrganization?.id == workflowID else { return }
            proposalApplyOutcome = outcome
            if let workflow = currentOrganization,
               !Set(operation.proposalIDs).isDisjoint(with: Set(workflow.proposals(from: proposals).map(\.id)))
                || currentOrganization?.phase == .receiptUnknown || currentOrganization?.phase == .applying {
                updateOrganization { value in
                    switch outcome {
                    case .applied: value.phase = .applied; value.issue = nil
                    case .retryAvailable: value.phase = .ready; value.issue = "服务端尚无这次确认的记录，可重新确认；会保留原编号和原基线。"
                    case .rejected(let message): value.phase = .failed; value.issue = message
                    default: value.phase = .receiptUnknown; value.issue = "确认回执尚未取得，正在核对原操作；不会重复写入。"
                    }
                }
            }
        }
        prepareOrganizationPreview()
    }
    func confirmOrganization() async {
        guard pendingWeekDraft == nil, let workflow = currentOrganization,
              workflow.latestRound?.status == "completed",
              workflow.phase == .ready || workflow.phase == .clarification || workflow.phase == .receiptUnknown else { return }
        let ids = organizationProposals.map(\.id)
        guard !ids.isEmpty || workflow.phase == .receiptUnknown else { return }
        if workflow.phase == .receiptUnknown { await refreshOrganization(); return }
        guard let revision = workflow.previewRevision, ids.sorted() == workflow.previewProposalIDs else {
            updateOrganization { $0.issue = "草案已变化，请刷新并重新查看差异。" }; return
        }
        do { try MobileOrganizationValidation.validate(organizationProposals) }
        catch { updateOrganization { $0.issue = "草案改变了原任务文字、时间、身份或完成记录。请在这里要求 AI 保留这些内容后重新整理。" }; return }
        updateOrganization { $0.phase = .applying; $0.issue = nil }
        let result = await applyProposals(ids: ids, expectedRevision: revision)
        guard currentOrganization?.id == workflow.id else { return }
        updateOrganization { value in
            switch result {
            case .applied: value.phase = .applied; value.issue = nil
            case .receiptUnknown: value.phase = .receiptUnknown; value.issue = "确认回执尚未取得，请核对原操作。"
            case .retryAvailable: value.phase = .ready; value.issue = "服务端尚无这次确认的记录，可重新确认；会保留原编号和原基线。"
            case .rejected(let message): value.phase = .ready; value.issue = message
            case .busy: value.phase = .ready
            case .unavailable: value.phase = .ready; value.issue = "当前暂不可确认，草案已保留。"
            }
        }
    }
    private func loadProposalApplication() -> MobileProposalApplication? {
        guard let endpoint = clientEndpoint, let repository = activeRepositoryID else { return nil }
        let url = organizationStorageURL(endpoint: endpoint, repository: repository, name: "proposal-application")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(MobileProposalApplication.self, from: $0) }
    }
    private func saveProposalApplication(_ operation: MobileProposalApplication) throws {
        let url = organizationStorageURL(endpoint: operation.endpoint, repository: operation.repositoryID, name: "proposal-application")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(operation).write(to: url, options: .atomic)
    }
    private func reconcileProposalApplication(_ operation: MobileProposalApplication) async -> MobileProposalApplyOutcome {
        guard operation.endpoint == clientEndpoint, operation.repositoryID == activeRepositoryID else { return .unavailable }
        if operation.succeeded, let revision = operation.resultRevision { return .applied(revision: revision) }
        if let failure = operation.failure { return .rejected(failure) }
        guard let client, isCloudService else { return .receiptUnknown }
        let generation = clientGeneration, repository = repositoryGeneration
        do {
            let status = try await client.operationStatus(id: operation.id)
            guard generation == clientGeneration, repository == repositoryGeneration else { return .unavailable }
            guard status.id == operation.id else { return .receiptUnknown }
            if ["failed", "rolled_back", "rejected"].contains(status.state) {
                var saved = operation; saved.failure = status.message ?? "原确认操作未成功，请重新整理草案后确认。"
                try saveProposalApplication(saved)
                return .rejected(saved.failure!)
            }
            guard status.state == "succeeded", let revision = status.revision else { return .receiptUnknown }
            var saved = operation; saved.succeeded = true; saved.resultRevision = revision
            try saveProposalApplication(saved)
            await refreshProposals()
            await refresh()
            return .applied(revision: revision)
        } catch {
            guard generation == clientGeneration, repository == repositoryGeneration else { return .unavailable }
            if let remote = error as? StudyRocketRemoteError, remote.body.code == "operation_not_found" {
                // The preceding POST task has finished. A fresh Face ID confirmation
                // may replay this exact intent with its original idempotency key.
                var saved = operation; saved.submitted = false
                do { try saveProposalApplication(saved); return .retryAvailable }
                catch { return .receiptUnknown }
            }
            return .receiptUnknown
        }
    }
}

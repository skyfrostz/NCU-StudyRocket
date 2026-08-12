public struct ChatTurnReducer {
    public enum MessagePhase: String, Equatable {
        case commentary
        case finalAnswer = "final_answer"
        case unknown
    }

    public enum TurnStatus: Equatable {
        case completed
        case interrupted
        case failed
    }

    public struct CompletedMessage: Equatable {
        public let itemID: String
        public let text: String
        public let phase: MessagePhase

        public init(itemID: String, text: String, phase: MessagePhase) {
            self.itemID = itemID
            self.text = text
            self.phase = phase
        }
    }

    public enum Event: Equatable {
        case error(message: String, willRetry: Bool)
        case agentMessageDelta(itemID: String, delta: String)
        case agentMessageCompleted(itemID: String, text: String, phase: MessagePhase?)
        case turnCompleted(status: TurnStatus, errorMessage: String?)
    }

    public enum Action: Equatable {
        case retrying(String)
        case streamChanged(itemID: String, text: String)
        case messageCompleted(CompletedMessage)
        case turnCompleted
        case turnInterrupted
        case turnFailed(String)
    }

    public private(set) var streams: [String: String] = [:]
    private var completedItemIDs: Set<String> = []
    public private(set) var isTerminal = false

    public init() {}

    public mutating func reduce(_ event: Event) -> [Action] {
        guard !isTerminal else { return [] }

        switch event {
        case .error(let message, true):
            return [.retrying(message)]

        case .error(let message, false):
            isTerminal = true
            streams.removeAll()
            return [.turnFailed(message)]

        case .agentMessageDelta(let itemID, let delta):
            guard !completedItemIDs.contains(itemID) else { return [] }
            streams[itemID, default: ""] += delta
            return [.streamChanged(itemID: itemID, text: streams[itemID] ?? "")]

        case .agentMessageCompleted(let itemID, let text, let phase):
            guard completedItemIDs.insert(itemID).inserted else { return [] }
            streams.removeValue(forKey: itemID)
            return [.messageCompleted(CompletedMessage(
                itemID: itemID,
                text: text,
                phase: phase ?? .unknown
            ))]

        case .turnCompleted(.completed, _):
            isTerminal = true
            streams.removeAll()
            return [.turnCompleted]

        case .turnCompleted(.interrupted, _):
            isTerminal = true
            streams.removeAll()
            return [.turnInterrupted]

        case .turnCompleted(.failed, let errorMessage):
            isTerminal = true
            streams.removeAll()
            return [.turnFailed(errorMessage ?? "Codex 回合失败。")]
        }
    }
}

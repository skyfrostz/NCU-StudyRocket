public enum ChatHistoryLoadState: Equatable {
    case loading
    case loaded
    case failed(String)
}

/// Keeps the last usable history while a refresh is loading or has failed.
public struct ChatHistoryLoadCoordinator<Value: Equatable>: Equatable {
    public private(set) var value: Value
    public private(set) var state: ChatHistoryLoadState = .loading
    public private(set) var revision = 0

    public init(initialValue: Value) {
        value = initialValue
    }

    @discardableResult
    public mutating func beginLoading() -> Bool {
        guard state != .loading else { return false }
        state = .loading
        return true
    }

    @discardableResult
    public mutating func replace(_ value: Value) -> Bool {
        let changed = self.value != value || state != .loaded
        self.value = value
        state = .loaded
        if changed { revision &+= 1 }
        return changed
    }

    @discardableResult
    public mutating func fail(_ message: String) -> Bool {
        let next = ChatHistoryLoadState.failed(message)
        guard state != next else { return false }
        state = next
        return true
    }
}

/// Coalesces scroll requests with the same target and animation mode.
public struct ChatScrollCoordinator: Equatable {
    public struct Request: Equatable {
        public let target: String
        public let force: Bool

        public init(target: String, force: Bool) {
            self.target = target
            self.force = force
        }
    }

    public private(set) var pending: Request?

    public init() {}

    @discardableResult
    public mutating func enqueue(target: String, force: Bool) -> Bool {
        let next = Request(target: target, force: force)
        guard pending != next else { return false }
        pending = next
        return true
    }

    public mutating func reset() {
        pending = nil
    }
}

/// Accumulates deltas by item ID and ignores events after authoritative completion.
public struct ChatStreamAccumulator: Equatable {
    public private(set) var streams: [String: String] = [:]
    public private(set) var completedItemIDs: Set<String> = []

    public init() {}

    @discardableResult
    public mutating func append(itemID: String, delta: String) -> String? {
        guard !completedItemIDs.contains(itemID) else { return nil }
        streams[itemID, default: ""] += delta
        return streams[itemID]
    }

    @discardableResult
    public mutating func complete(itemID: String, text: String) -> String? {
        guard completedItemIDs.insert(itemID).inserted else { return nil }
        streams.removeValue(forKey: itemID)
        return text
    }

    public mutating func reset() {
        streams.removeAll()
        completedItemIDs.removeAll()
    }
}

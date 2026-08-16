import Foundation

public enum ChatHistoryLoadState: Equatable {
    case loading
    case loaded
    case failed(String)
}

/// Keeps the last usable history while a refresh is loading or has failed.
public struct ChatHistoryLoadCoordinator<Value: Equatable>: Equatable {
    public private(set) var value: Value
    public private(set) var state: ChatHistoryLoadState = .loading

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
    public struct Request: Identifiable, Equatable {
        public let id: UUID
        public let target: String
        public let force: Bool

        public init(id: UUID = UUID(), target: String, force: Bool) {
            self.id = id
            self.target = target
            self.force = force
        }

        public static func == (lhs: Request, rhs: Request) -> Bool {
            // Identity is consumed by the view; target/mode equality is what
            // lets repeated layout updates coalesce.
            lhs.target == rhs.target && lhs.force == rhs.force
        }
    }

    public private(set) var pending: Request?

    public init() {}

    @discardableResult
    public mutating func enqueue(target: String, force: Bool, id: UUID = UUID()) -> Bool {
        let next = Request(id: id, target: target, force: force)
        guard pending != next else { return false }
        pending = next
        return true
    }

    /// Consume only the request currently being displayed. A stale callback
    /// must never clear a newer request.
    @discardableResult
    public mutating func consume(id: UUID) -> Request? {
        guard let pending, pending.id == id else { return nil }
        self.pending = nil
        return pending
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

    /// Drop only transient text after a terminal history reconciliation. Keep
    /// completion tombstones long enough to reject late SSE deltas.
    public mutating func clearStreams() {
        streams.removeAll()
    }
}

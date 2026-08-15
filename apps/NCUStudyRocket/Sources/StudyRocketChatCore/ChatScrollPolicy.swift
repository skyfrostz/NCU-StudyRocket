public struct ChatScrollPolicy: Equatable {
    public private(set) var isNearBottom: Bool

    public init(isNearBottom: Bool = true) {
        self.isNearBottom = isNearBottom
    }

    @discardableResult
    public mutating func update(isNearBottom: Bool) -> Bool {
        guard self.isNearBottom != isNearBottom else { return false }
        self.isNearBottom = isNearBottom
        return true
    }

    @discardableResult
    public mutating func forceToBottom() -> Bool {
        guard !isNearBottom else { return false }
        isNearBottom = true
        return true
    }

    public func shouldFollowIncrementalChanges() -> Bool {
        isNearBottom
    }
}

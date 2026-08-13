public struct ChatScrollPolicy: Equatable {
    public private(set) var isNearBottom: Bool

    public init(isNearBottom: Bool = true) {
        self.isNearBottom = isNearBottom
    }

    public mutating func update(isNearBottom: Bool) {
        self.isNearBottom = isNearBottom
    }

    public mutating func forceToBottom() {
        isNearBottom = true
    }

    public func shouldFollowIncrementalChanges() -> Bool {
        isNearBottom
    }
}

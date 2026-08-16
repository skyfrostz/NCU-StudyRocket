import Foundation

public struct ChatScrollPolicy: Equatable {
    public static let enterThreshold: CGFloat = 48
    public static let leaveThreshold: CGFloat = 120

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

    /// Apply the 48/120pt hysteresis used by the native scroll observer.
    /// When following, the user must move past 120pt to leave; once detached,
    /// returning within 48pt is enough to resume following.
    @discardableResult
    public mutating func update(distanceFromBottom: CGFloat) -> Bool {
        let threshold = isNearBottom ? Self.leaveThreshold : Self.enterThreshold
        return update(isNearBottom: distanceFromBottom <= threshold)
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

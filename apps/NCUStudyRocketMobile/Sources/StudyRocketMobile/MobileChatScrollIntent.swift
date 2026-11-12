/// A refresh may navigate only while the user's navigation intent is unchanged.
/// Automatic refreshes update data without establishing a new scroll intent.
struct MobileChatScrollIntent: Equatable {
    private(set) var version = 0

    mutating func noteNavigation() { version &+= 1 }

    func shouldNavigateAfterRefresh(startedAt version: Int, explicit: Bool, succeeded: Bool) -> Bool {
        explicit && succeeded && version == self.version
    }
}

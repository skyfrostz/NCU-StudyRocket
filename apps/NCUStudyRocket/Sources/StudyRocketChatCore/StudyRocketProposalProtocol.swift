public enum StudyRocketDynamicToolContract {
    public static let namespace = "studyrocket"
    public static let proposalTool = "propose_changes"
    public static let skillProposalTool = "propose_skill_update"

    public static func accepts(namespace: String?, tool: String) -> Bool {
        namespace == Self.namespace && [proposalTool, skillProposalTool].contains(tool)
    }

    public static func routedTurnID(eventThreadID: String?, currentThreadID: String?, activeTurnID: String?) -> String? {
        guard eventThreadID == currentThreadID else { return nil }
        return activeTurnID
    }
}

public enum StudyRocketThreadProtocol {
    public static let currentVersion = 2

    public static func requiresMigration(storedThreadID: String?, storedVersion: Int) -> Bool {
        guard let storedThreadID, !storedThreadID.isEmpty else { return false }
        return storedVersion < currentVersion
    }
}

import Foundation
import StudyRocketShared

public enum StudyRocketDynamicToolContract {
    public static let namespace = "studyrocket"
    public static let proposalTool = "propose_changes"
    public static let skillProposalTool = "propose_skill_update"

    /// The declaration is shared by the Mac client and the optional Host so a
    /// resumed fixed thread never receives a subtly different namespace shape.
    public static let declaration: [[String: Any]] = [[
        "type": "namespace",
        "name": namespace,
        "description": "StudyRocket 应用的只读草案工具。调用只会建立待确认的差异，绝不直接写文件。",
        "tools": [
            [
                "type": "function",
                "name": proposalTool,
                "description": "提出对学业 Markdown 的修改草案。应用会展示差异并等待用户确认。",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "仓库内 Markdown 相对路径"],
                        "content": ["type": "string", "description": "完整候选文件正文"],
                        "reason": ["type": "string", "description": "修改理由"]
                    ],
                    "required": ["path", "content", "reason"]
                ]
            ],
            [
                "type": "function",
                "name": skillProposalTool,
                "description": "仅在周复盘有稳定证据时提出现有 Skill 的修改草案；用户必须确认。",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "content": ["type": "string"],
                        "reason": ["type": "string"]
                    ],
                    "required": ["path", "content", "reason"]
                ]
            ]
        ]
    ]]

    public static var declarationIsValid: Bool {
        guard let namespace = declaration.first,
              namespace["type"] as? String == "namespace",
              namespace["name"] as? String == Self.namespace,
              let tools = namespace["tools"] as? [[String: Any]] else { return false }
        let names = Set(tools.compactMap { $0["name"] as? String })
        return names == [proposalTool, skillProposalTool]
    }

    public static func accepts(namespace: String?, tool: String) -> Bool {
        normalizedCall(namespace: namespace, tool: tool) != nil
    }

    /// Recent app-server builds emit canonical namespace calls, while an older
    /// persisted StudyRocket thread can emit the legacy flat function name
    /// (`studyrocket_propose_changes`) with `namespace: null`.  Normalize both
    /// wire shapes before the app applies its strict path and confirmation
    /// checks; no arbitrary namespace is accepted.
    public static func normalizedCall(namespace: String?, tool: String) -> (namespace: String, tool: String)? {
        if namespace == Self.namespace, [proposalTool, skillProposalTool].contains(tool) {
            return (Self.namespace, tool)
        }
        guard namespace == nil else { return nil }
        return tool == "studyrocket_\(proposalTool)" ? (Self.namespace, proposalTool) : nil
    }

    public static func routedTurnID(eventThreadID: String?, currentThreadID: String?, activeTurnID: String?) -> String? {
        guard eventThreadID == currentThreadID else { return nil }
        return activeTurnID
    }
}

public enum StudyRocketThreadProtocol {
    public static let currentVersion = StudyRocketAPI.academicTaskProtocolVersion
    /// Only used as a one-time migration source for the pre-descriptor Host.
    public static let legacyHostThreadID = "019ff539-bc1a-7b73-9a29-6340b47690e0"

    public static func requiresMigration(storedThreadID: String?, storedVersion: Int) -> Bool {
        guard let storedThreadID, !storedThreadID.isEmpty else { return false }
        return storedVersion < currentVersion
    }

    /// A compatible descriptor can still refer to a thread whose rollout was
    /// never persisted, for example when its previous owner exited just after
    /// `thread/start`. Recreate only this precise app-server failure; auth and
    /// other protocol errors must remain visible to the user.
    public static func requiresRecreationForMissingRollout(errorMessage: String?) -> Bool {
        errorMessage?.localizedCaseInsensitiveContains("no rollout found for thread id") == true
    }
}

import Foundation

public enum StudyRocketDynamicToolContract {
    public static let namespace = "studyrocket"
    public static let proposalTool = "propose_changes"
    public static let skillProposalTool = "propose_skill_update"

    public static func accepts(namespace: String?, tool: String) -> Bool {
        namespace == Self.namespace && [proposalTool, skillProposalTool].contains(tool)
    }
}

public struct StudyRocketProposalPayload: Equatable {
    public let path: String
    public let content: String
    public let reason: String

    public init(path: String, content: String, reason: String) {
        self.path = path
        self.content = content
        self.reason = reason
    }
}

public struct StudyRocketProposalExtraction: Equatable {
    public let visibleText: String
    public let proposals: [StudyRocketProposalPayload]
    public let invalidBlockCount: Int

    public init(visibleText: String, proposals: [StudyRocketProposalPayload], invalidBlockCount: Int) {
        self.visibleText = visibleText
        self.proposals = proposals
        self.invalidBlockCount = invalidBlockCount
    }
}

public enum StudyRocketProposalProtocol {
    private static let fencePattern = #"```studyrocket-proposal[ \t]*\n([\s\S]*?)\n```"#

    public static func extract(from text: String) -> StudyRocketProposalExtraction {
        guard let expression = try? NSRegularExpression(pattern: fencePattern) else {
            return StudyRocketProposalExtraction(visibleText: text, proposals: [], invalidBlockCount: 0)
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: range)
        guard !matches.isEmpty else {
            return StudyRocketProposalExtraction(visibleText: text, proposals: [], invalidBlockCount: 0)
        }

        var proposals: [StudyRocketProposalPayload] = []
        var invalidBlockCount = 0
        for match in matches {
            guard match.numberOfRanges > 1,
                  let jsonRange = Range(match.range(at: 1), in: text),
                  let data = String(text[jsonRange]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = object["path"] as? String,
                  let content = object["content"] as? String,
                  let reason = object["reason"] as? String else {
                invalidBlockCount += 1
                continue
            }
            proposals.append(StudyRocketProposalPayload(path: path, content: content, reason: reason))
        }

        var visibleText = expression.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        while visibleText.contains("\n\n\n") {
            visibleText = visibleText.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        visibleText = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        return StudyRocketProposalExtraction(
            visibleText: visibleText,
            proposals: proposals,
            invalidBlockCount: invalidBlockCount
        )
    }
}

import Foundation
import StudyRocketShared

/// Local continuity state only. Markdown and proposal content remain server-owned.
struct MobileOrganizationWorkflow: Codable, Equatable {
    struct Round: Codable, Equatable {
        var requestID: String
        var turnID: String?
        var prompt: String
        var startedAt: Date
        var priorTurnIDs: [String]
        var status: String = "inProgress"
        var reply: String = ""
    }
    enum Phase: String, Codable { case requesting, clarification, ready, applying, receiptUnknown, applied, failed }
    var id: String = UUID().uuidString
    var endpoint: URL
    var repositoryID: String
    var rounds: [Round] = []
    var phase: Phase = .requesting
    var clarificationDraft: String = ""
    var issue: String?
    var previewRevision: String?
    var previewProposalIDs: [String]?
    var latestRound: Round? { rounds.last }
    var latestCompletedTurnID: String? {
        guard latestRound?.status == "completed" else { return nil }
        return latestRound?.turnID
    }
    func proposals(from proposals: [ProposalDTO]) -> [ProposalDTO] {
        guard let turnID = latestCompletedTurnID,
              phase != .applied && phase != .requesting && phase != .failed else { return [] }
        return proposals.filter { $0.turnID == turnID }
    }
    static let prompt = "请读取当前周计划、课表和我的偏好，整理独立任务、交付物及其关联。只整理结构和明确的关联，不重新排期，不移动日期或时段，不改写用户任务原文；保留任务 ID、已有完成状态、历史和管理边界。同一时段的独立事项分别保留；条件缓冲和截止提醒关联原任务，明确的到场活动进入课表但保留原日期时间。不凭相似文字合并任务、自动完成或推断关联。任务联动未启用时生成可预览的启用草案；已启用时整理现有关联。不确定的关联先向我澄清，等待回答后再生成本轮完整草案。只能通过正式 studyrocket.propose_changes 入口提交，先展示差异，由我确认后保存。"
}

struct MobileProposalApplication: Codable, Equatable {
    let id: String
    let endpoint: URL
    let repositoryID: String
    let proposalIDs: [String]
    let baseRevision: String
    var submitted = false
    var succeeded = false
    var resultRevision: String?
    var failure: String?
    init(endpoint: URL, repositoryID: String, proposalIDs: [String], baseRevision: String) {
        id = UUID().uuidString
        self.endpoint = endpoint
        self.repositoryID = repositoryID
        self.proposalIDs = proposalIDs.sorted()
        self.baseRevision = baseRevision
    }
    func matches(ids: [String], revision: String) -> Bool {
        proposalIDs == ids.sorted() && baseRevision == revision
    }
}

public enum MobileProposalApplyOutcome: Equatable, Sendable {
    case applied(revision: String)
    case receiptUnknown
    case retryAvailable
    case rejected(String)
    case busy
    case unavailable
}

/// Narrower than general editing: organization may classify/link but not rename,
/// complete, cancel or reschedule existing identified work.
enum MobileOrganizationValidation {
    static func validate(_ proposals: [ProposalDTO]) throws {
        for proposal in proposals {
            guard ["工作台/下周计划.md", StudyRocketTimetableParser.sourceFile].contains(proposal.relativePath), proposal.kind != "skill" else { throw TaskLinkageError.changed }
            try PlanningProposalValidation.validateManagedBoundaries(path: proposal.relativePath, original: proposal.originalContent, proposed: proposal.proposedContent)
            if proposal.relativePath == "工作台/下周计划.md", let old = try TaskLinkageMarkdown.read(proposal.originalContent) {
                guard let next = try TaskLinkageMarkdown.read(proposal.proposedContent) else { throw TaskLinkageError.changed }
                try PlanningProposalValidation.preserveHistory(from: old, in: next)
                for task in old.tasks {
                    guard let other = next.tasks.first(where: { $0.id == task.id }),
                          task.text == other.text, task.dueAt == other.dueAt, task.cancelled == other.cancelled else { throw TaskLinkageError.changed }
                }
                for delivery in old.deliveries {
                    guard let other = next.deliveries.first(where: { $0.id == delivery.id }),
                          delivery.text == other.text, delivery.cancelled == other.cancelled else { throw TaskLinkageError.changed }
                }
                for assignment in old.assignments {
                    guard next.assignments.contains(assignment) else { throw TaskLinkageError.changed }
                }
            }
            if proposal.relativePath == StudyRocketTimetableParser.sourceFile {
                let old = try OneOffSchedule.read(proposal.originalContent)
                let next = try OneOffSchedule.read(proposal.proposedContent)
                guard old.allSatisfy(next.contains) else { throw TaskLinkageError.changed }
            }
        }
    }
}

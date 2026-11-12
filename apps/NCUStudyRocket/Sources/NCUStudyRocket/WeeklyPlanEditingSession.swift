import Foundation
import SwiftUI

/// An in-memory editing session owned above sidebar navigation. Markdown and
/// its original hash remain authoritative; no draft is silently rebased.
@MainActor
final class WeeklyPlanEditingSession: ObservableObject {
    @Published var plan = WeeklyPlan()
    @Published var activeEditor: WeeklyRowEditorState?
    @Published var cellDrafts: [String: WeeklyCellDraft] = [:]
    @Published private(set) var isSaving = false
    @Published var status: String?
    private(set) var root: URL?
    private var savedPlan: WeeklyPlan?
    var original = ""
    var loadedHash = ""
    var originalDeliveries: [UUID: String] = [:]
    var originalRules: [UUID: (BufferRuleCategory, String)] = [:]

    var hasUnsavedChanges: Bool {
        guard let savedPlan else { return false }
        if let activeEditor, activeEditor.isNew || activeEditor.draftText != activeEditor.originalText { return true }
        if cellDrafts.values.contains(where: { $0.text != $0.originalText }) { return true }
        return !Self.sameContent(plan, savedPlan) || plan.isMigratedPreview
    }

    func install(root: URL, original: String, loadedHash: String, plan: WeeklyPlan) {
        self.root = root
        self.original = original
        self.loadedHash = loadedHash
        self.plan = plan
        self.savedPlan = plan
        originalDeliveries = Dictionary(uniqueKeysWithValues: plan.deliveries.map { ($0.id, $0.text) })
        originalRules = Dictionary(uniqueKeysWithValues: plan.bufferRules.map { ($0.id, ($0.category, $0.text)) })
    }

    /// Collecting is synchronous and never writes. Both the top Save button
    /// and inline Done call this before entering the one persistence path.
    func collectActiveEditor() throws {
        // Build a candidate first so one invalid target cannot partially
        // consume other text drafts.
        var candidate = plan
        for draft in cellDrafts.values {
            guard candidate.cells.indices.contains(draft.row), candidate.cells[draft.row].indices.contains(draft.column) else { throw EditingError.missingRow }
            candidate.cells[draft.row][draft.column] = draft.text
        }
        if let editor = activeEditor { switch editor.kind {
        case .delivery(let id):
            guard let index = candidate.deliveries.firstIndex(where: { $0.id == id }) else { throw EditingError.missingRow }
            candidate.deliveries[index].text = editor.draftText
        case .bufferRule(let id):
            guard let index = candidate.bufferRules.firstIndex(where: { $0.id == id }) else { throw EditingError.missingRow }
            candidate.bufferRules[index].text = editor.draftText
        } }
        plan = candidate
        activeEditor = nil
        cellDrafts = [:]
    }

    func beginSaving() -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        status = "正在保存…"
        return true
    }

    func finishSaving() { isSaving = false }

    func acknowledgeSaved(_ submitted: WeeklyPlan, source: String, hash: String) {
        savedPlan = submitted
        original = source
        loadedHash = hash
        originalDeliveries = Dictionary(uniqueKeysWithValues: submitted.deliveries.map { ($0.id, $0.text) })
        originalRules = Dictionary(uniqueKeysWithValues: submitted.bufferRules.map { ($0.id, ($0.category, $0.text)) })
    }

    static func sameContent(_ lhs: WeeklyPlan, _ rhs: WeeklyPlan) -> Bool {
        lhs.format == rhs.format && lhs.cells == rhs.cells && lhs.datedRows == rhs.datedRows &&
        lhs.dayDateLabels == rhs.dayDateLabels && lhs.unassignedByDay == rhs.unassignedByDay &&
        lhs.dayCompletion == rhs.dayCompletion && lhs.periodCompletion == rhs.periodCompletion &&
        lhs.periodTaskCompletion == rhs.periodTaskCompletion && lhs.historicalRows == rhs.historicalRows &&
        lhs.futureRows == rhs.futureRows && lhs.deliveries == rhs.deliveries &&
        lhs.buffer == rhs.buffer && lhs.bufferRules == rhs.bufferRules && lhs.linkage == rhs.linkage
    }

    private enum EditingError: LocalizedError {
        case missingRow
        var errorDescription: String? { "正在编辑的项目已变化，文字草稿仍保留，请检查后重试。" }
    }
}

struct WeeklyCellDraft {
    let row: Int
    let column: Int
    let originalText: String
    var text: String
}

struct WeeklyRowEditorState: Identifiable, Equatable {
    enum Kind: Equatable {
        case delivery(UUID)
        case bufferRule(UUID)
    }

    let kind: Kind
    let originalText: String
    var draftText: String
    let isNew: Bool

    init(kind: Kind, originalText: String, draftText: String? = nil, isNew: Bool = false) {
        self.kind = kind
        self.originalText = originalText
        self.draftText = draftText ?? originalText
        self.isNew = isNew
    }

    var id: String {
        switch kind {
        case .delivery(let id): "delivery-\(id.uuidString)"
        case .bufferRule(let id): "buffer-\(id.uuidString)"
        }
    }
}

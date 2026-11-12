import Foundation
import StudyRocketShared

@main
struct WeeklyPlanEditingChecks {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("weekly-editor-checks-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("工作台"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = "工作台/下周计划.md"
        let source = """
        # 临时计划
        保留边界外说明。
        <!-- studyrocket:weekly:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        | --- | --- | --- | --- | --- | --- |
        | \(PlanningDate.key(.now)) | 例题 |  |  |  | [ ] |
        <!-- studyrocket:weekly:end -->
        ## 交付物清单
        <!-- studyrocket:deliveries:start -->
        - [ ] 原交付物
        <!-- studyrocket:deliveries:end -->
        ## 缓冲与降级
        <!-- studyrocket:buffer:start -->
        - 原缓冲
        <!-- studyrocket:buffer:end -->
        ## 外部说明
        末尾说明保持不变。
        """
        try Data(source.utf8).write(to: root.appendingPathComponent(file))
        let repo = MarkdownRepository(root: root, backupRoot: root.appendingPathComponent("backups"))
        let session = WeeklyPlanEditingSession()
        session.install(root: root, original: source, loadedHash: repo.hash(source), plan: MarkdownParser.weekly(source))
        let id = session.plan.deliveries[0].id
        session.activeEditor = WeeklyRowEditorState(kind: .delivery(id), originalText: "原交付物", draftText: "原交付物 · 顶部保存必须包含的后缀")
        precondition(session.hasUnsavedChanges)
        // Navigation cancellation does not transfer or clear view-local text;
        // the parent-owned session remains the same source for a recreated page.
        let retainedSession = session
        precondition(retainedSession.activeEditor?.draftText.hasSuffix("后缀") == true)
        precondition(tryRead(repo, file) == source)

        try session.collectActiveEditor()
        precondition(session.activeEditor == nil && session.plan.deliveries[0].text.hasSuffix("后缀"))
        precondition(session.beginSaving())
        precondition(!session.beginSaving(), "The same session must not start a second concurrent save")
        let submitted = session.plan
        let proposed = MarkdownParser.replaceWeekly(session.original, with: submitted)
        _ = try await repo.save(proposed, relative: file, loadedHash: session.loadedHash, recordHistory: false)
        session.acknowledgeSaved(submitted, source: proposed, hash: repo.hash(proposed))
        session.finishSaving()
        let persisted = try repo.read(file)
        precondition(persisted.contains("顶部保存必须包含的后缀"))
        precondition(persisted.contains("保留边界外说明。") && persisted.contains("末尾说明保持不变。"))
        precondition(!session.hasUnsavedChanges)

        // Inline Done uses the same collector; buffer edits must participate in
        // dirty detection even though sharedSnapshot() omits bufferRules.
        if let rule = session.plan.bufferRules.first {
            session.activeEditor = WeeklyRowEditorState(kind: .bufferRule(rule.id), originalText: rule.text, draftText: "缓冲修改已保留")
            try session.collectActiveEditor()
            precondition(session.hasUnsavedChanges)
            precondition(session.plan.bufferRules.first?.text == "缓冲修改已保留")
        } else { preconditionFailure("Fixture did not contain a buffer row") }

        // Dismissing a time-slot popover preserves the draft outside the sheet.
        session.cellDrafts["morning-0"] = WeeklyCellDraft(row: 0, column: 0, originalText: session.plan.cells[0][0], text: "弹层关闭后仍保留的文字")
        precondition(session.hasUnsavedChanges)
        try session.collectActiveEditor()
        precondition(session.plan.cells[0][0] == "弹层关闭后仍保留的文字")

        // An external edit must reject the stale hash and leave the candidate
        // and its original base hash available for review, never silently rebase.
        let originalHash = session.loadedHash
        let external = persisted + "\n外部修改\n"
        try Data(external.utf8).write(to: root.appendingPathComponent(file))
        do {
            _ = try await repo.save(MarkdownParser.replaceWeekly(session.original, with: session.plan), relative: file,
                                    loadedHash: session.loadedHash, recordHistory: false)
            preconditionFailure("Stale fixture must fail CAS")
        } catch MarkdownError.conflict { }
        precondition(session.loadedHash == originalHash && session.hasUnsavedChanges)
        precondition(session.plan.cells[0][0] == "弹层关闭后仍保留的文字")
        precondition(tryRead(repo, file) == external)

        let document = MarkdownDocumentModel(root: root)
        document.load(file)
        document.text += "\n资料草稿\n"
        try Data((external + "\n另一个外部修改\n").utf8).write(to: root.appendingPathComponent(file))
        let documentSaved = await document.save()
        precondition(!documentSaved)
        precondition(!document.isSaving && document.isDirty && document.text.hasSuffix("资料草稿\n"))
        print("Weekly editor checks passed: collected header/inline drafts, one saving gate, retained navigation/popover drafts, buffer dirtiness, exact source preservation, stale CAS and document failure retention")
    }

    private static func tryRead(_ repo: MarkdownRepository, _ file: String) -> String { try! repo.read(file) }
}

import SwiftUI
import MarkdownUI
import StudyRocketShared

struct MobileOrganizationSheet: View {
    @ObservedObject var session: MobileSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("整理任务结构与关联，保留原文字、日期时段、任务身份和完成记录。")
                        .foregroundStyle(.secondary)
                    if session.pendingWeekDraft != nil {
                        Label("请先处理尚未保存的周计划草稿，再开始整理或确认。", systemImage: "exclamationmark.triangle")
                    }
                    if let workflow = session.currentOrganization {
                        status(workflow)
                        if let issue = workflow.issue { Text(issue).foregroundStyle(.secondary).textSelection(.enabled) }
                        if let round = workflow.latestRound {
                            let live = session.chatMessages.filter { $0.turnID == round.turnID && $0.role == "assistant" }.map(\.text).joined(separator: "\n\n")
                            let reply = live.isEmpty ? round.reply : live
                            if !reply.isEmpty { Markdown(reply).textSelection(.enabled) }
                        }
                        ForEach(session.organizationProposals) { proposal in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(proposal.relativePath).font(.headline)
                                Text(proposal.reason).foregroundStyle(.secondary)
                                StudyProposalDiffView(original: proposal.originalContent, proposed: proposal.proposedContent,
                        renderMarkdown: { AnyView(MobileProposalMarkdownPreview(source: $0)) })
                            }
                        }
                        if workflow.phase == .ready || workflow.phase == .clarification {
                            if !session.organizationProposals.isEmpty {
                                Button("确认并保存") { Task { await session.confirmOrganization() } }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.large)
                                    .disabled(session.isApplyingProposals || session.pendingWeekDraft != nil || !session.canApplyProposals)
                                Text("通过 Face ID 确认后，只保存本轮已完成回复的草案。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if workflow.phase == .clarification || workflow.phase == .ready || workflow.phase == .failed {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("补充或回答 AI 的问题", text: Binding(
                                    get: { session.currentOrganization?.clarificationDraft ?? "" },
                                    set: { session.setOrganizationClarification($0) }), axis: .vertical)
                                    .lineLimit(2...8).textFieldStyle(.roundedBorder)
                                Button("发送补充") { Task { await session.sendOrganizationClarification() } }
                                    .disabled(session.isChatBusy || !session.isChatAvailable || session.pendingWeekDraft != nil || workflow.clarificationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        if workflow.phase == .receiptUnknown {
                            Button("核对确认结果") { Task { await session.refreshOrganization() } }
                                .disabled(session.isApplyingProposals)
                        }
                        if workflow.phase == .applied {
                            Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
                        }
                    } else {
                        Text(session.lastChatIssue ?? "连接学业服务后即可开始整理。")
                    }
                }
                .padding()
            }
            .navigationTitle("AI 整理")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await session.refreshChat()
                            await session.refreshProposals()
                            await session.refreshOrganization()
                        }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("刷新整理进度")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            await session.refreshChat()
            await session.refreshProposals()
            await session.refreshOrganization()
        }
    }

    @ViewBuilder private func status(_ workflow: MobileOrganizationWorkflow) -> some View {
        switch workflow.phase {
        case .requesting:
            if session.organizationIsRunning {
                HStack { ProgressView(); Text("正在整理，可关闭后继续查看") }
            } else {
                Label("整理进度待核对，刷新后继续查看", systemImage: "clock")
            }
        case .clarification:
            Text(session.organizationProposals.isEmpty ? "查看回复并补充信息" : "待确认修改").font(.headline)
        case .ready: Text("待确认修改").font(.headline)
        case .applying: HStack { ProgressView(); Text("正在确认") }
        case .receiptUnknown: Label("正在核对保存结果", systemImage: "arrow.triangle.2.circlepath")
        case .applied: Label(session.state == .online ? "整理已保存" : "已保存，计划刷新中", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Label("本轮未完成", systemImage: "exclamationmark.circle")
        }
    }
}

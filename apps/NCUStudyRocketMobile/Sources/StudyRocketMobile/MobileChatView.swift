import Foundation
import SwiftUI
import StudyRocketShared
import MarkdownUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct MobileChatView: View {
  @ObservedObject var session: MobileSession
  @State private var userScrolling = false
  @State private var readingOlder = false
  @State private var replacement: String?
  @State private var showJumpToLatest = false
  @State private var latestScrollRequest = 0
  #if os(iOS)
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
  #endif
  @State private var scrollIntent = MobileChatScrollIntent()
  @FocusState private var isComposerFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if session.state != .online {
          MobileStatusBanner(session: session)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MobileTheme.pageInset)
            .padding(.vertical, 4)
        }
        if let message = session.conversationRefreshError ?? session.chatUnavailableMessage ?? session.lastChatIssue {
          VStack(alignment: .leading, spacing: 8) {
            MobileInlineNotice(
              text: message, symbol: "bubble.left.and.exclamationmark", tint: .orange)
            HStack(spacing: 10) {
            if session.conversationRefreshError != nil || session.chatUnavailableMessage != nil {
              StudyButton(session.conversationRefreshError != nil ? "重试" : "重新检查") { Task { await refreshLatest() } }
                .disabled(session.refreshingConversation)
            }
            if let failed = session.lastFailedChatText {
              StudyButton("恢复到输入框") { proposeDraft(failed) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            }
          }
          .padding(.horizontal, MobileTheme.pageInset)
        }
        GeometryReader { container in
          ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
              ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                  if session.chatMessages.isEmpty {
                    MobileEmptyState(
                      title: session.chatUnavailableMessage == nil ? "还没有学业对话" : "学业对话尚未就绪",
                      message: session.chatUnavailableMessage ?? "可以从下方输入课程问题、今日事实或计划调整。",
                      symbol: "bubble.left.and.bubble.right",
                      actionTitle: nil,
                      action: nil
                    )
                    .frame(minHeight: max(260, container.size.height - 36))
                  } else {
                    ForEach(MobileChatTurn.group(session.chatMessages)) { turn in
                      MobileChatTurnView(
                        turn: turn,
                        contentWidth: max(1, container.size.width - 2 * MobileTheme.pageInset),
                        proposals: session.canViewProposals
                          ? session.proposals.filter { $0.turnID == turn.id } : [],
                        session: session
                      )
                      .id(turn.id)
                    }
                  }
                  if session.isChatBusy {
                    MobileChatActivityIndicator(progress: session.chatProgress ?? .thinking)
                      .id("chat-activity")
                  }
                  let unassigned =
                    session.canViewProposals
                    ? session.proposals.filter { proposal in
                      !session.chatMessages.contains { $0.turnID == proposal.turnID }
                    } : []
                  if !unassigned.isEmpty {
                    MobileProposalPanel(session: session, proposals: unassigned)
                  }
                  Color.clear.frame(height: 1).id("chat-bottom")
                    #if !os(iOS)
                      .background(
                        GeometryReader { marker in
                          Color.clear.preference(
                            key: MobileChatBottomPreference.self,
                            value: marker.frame(in: .named("mobile-chat-scroll")).minY)
                        }
                      )
                    #endif
                }
                .frame(width: max(1, container.size.width - 2 * MobileTheme.pageInset), alignment: .leading)
                .padding(.horizontal, MobileTheme.pageInset)
                .padding(.vertical, 14)
              }
              .background(.background)
              .refreshable { await refreshLatest() }
              #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                .scrollPosition($scrollPosition)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(userScrolling || readingOlder ? nil : .bottom, for: .sizeChanges)
                .onScrollPhaseChange { previous, phase in
                  // Only a real drag establishes a new user navigation intent.
                  // Deceleration and programmatic edge positioning must not
                  // invalidate the refresh that requested that positioning.
                  if phase == .interacting && previous != .interacting { scrollIntent.noteNavigation() }
                  userScrolling = phase == .interacting || phase == .decelerating || phase == .tracking
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                  max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
                } action: { _, distance in
                  guard userScrolling || readingOlder else { return }
                  readingOlder = distance > (readingOlder ? 48 : 120)
                  showJumpToLatest = readingOlder
                }
              #else
                .coordinateSpace(name: "mobile-chat-scroll")
                .onPreferenceChange(MobileChatBottomPreference.self) { bottomY in
                  let wasReadingOlder = readingOlder
                  readingOlder = bottomY > container.size.height + 72
                  if readingOlder && !wasReadingOlder { scrollIntent.noteNavigation() }
                  if !readingOlder { showJumpToLatest = false }
                }
              #endif
              .simultaneousGesture(TapGesture().onEnded { isComposerFocused = false })
              .onChange(of: session.chatRevision) { _, _ in
                if readingOlder { showJumpToLatest = true }
                #if !os(iOS)
                  if !readingOlder { latestScrollRequest &+= 1 }
                #endif
              }
              #if !os(iOS)
                .task(id: latestScrollRequest) {
                  await Task.yield()
                  guard !Task.isCancelled, !readingOlder else { return }
                  proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
              #endif
              .task { await refreshLatest(explicit: false) }
              if showJumpToLatest {
                Button {
                  withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    requestLatest()
                  }
                } label: {
                  Image(systemName: "arrow.down")
                    .studyTypography(.headline, weight: .semibold)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                .padding(14)
                .accessibilityLabel("回到最新消息")
              }
            }
          }
        }
        MobileChatComposer(session: session, store: session.chatDraftStore, focus: $isComposerFocused) {
          requestLatest()
          Task { await session.sendDraft() }
        }

      }
      .navigationTitle("学业对话")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Menu {
            StudyLabel(session.state == .online ? "已连接学业服务" : "学业服务未连接", systemImage: session.state == .online ? "checkmark.circle" : "wifi.slash")
            StudyButton("本周总结") { proposeDraft("本周总结：请基于我实际保存的记录和交付物，帮我总结本周。") }
            StudyButton("排下周") { proposeDraft("排下周：请先询问我可投入的时间、固定安排和本周遗留交付物。") }
          } label: {
            Image(systemName: "bolt.circle")
          }
          .accessibilityLabel("对话快捷操作与连接状态")
        }
        ToolbarItem(placement: .primaryAction) {
          Button { Task { await refreshLatest() } } label: {
            if session.refreshingConversation { ProgressView().controlSize(.small) }
            else { StudyLabel("刷新", systemImage: "arrow.clockwise") }
          }.accessibilityLabel("刷新").disabled(session.refreshingConversation)
        }
      }
      .alert("替换输入框中的草稿？", isPresented: Binding(get: { replacement != nil }, set: { if !$0 { replacement = nil } })) {
        StudyButton("替换") { if let replacement { session.inputDraft = replacement }; replacement = nil; isComposerFocused = true }
        StudyButton("保留当前草稿", role: .cancel) { replacement = nil }
      }
      .onChange(of: session.repositoryGeneration) { _, _ in replacement = nil; readingOlder = false; showJumpToLatest = false }
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            StudyButton("完成") { isComposerFocused = false }
          }
        }
      #endif
      .onDisappear { isComposerFocused = false }
    }
  }
  private func requestLatest() {
    scrollIntent.noteNavigation()
    readingOlder = false
    userScrolling = false
    showJumpToLatest = false
    #if os(iOS)
      scrollPosition.scrollTo(edge: .bottom)
    #else
      latestScrollRequest &+= 1
    #endif
  }

  private func refreshLatest(explicit: Bool = true) async {
    // Explicit refresh means "show latest" immediately; the edge binding
    // then follows the authoritative result unless the user starts a new drag.
    if explicit { requestLatest() }
    let startedAt = scrollIntent.version
    await session.refreshConversation()
    guard !Task.isCancelled,
      scrollIntent.shouldNavigateAfterRefresh(startedAt: startedAt, explicit: explicit,
        succeeded: session.conversationRefreshError == nil && session.isChatAvailable) else { return }
    requestLatest()
  }

  private func proposeDraft(_ value: String) {
    if !session.inputDraft.isEmpty && session.inputDraft != value { replacement = value }
    else { session.inputDraft = value; isComposerFocused = true }
  }
}

private struct MobileChatBottomPreference: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MobileProposalPanel: View {
  @ObservedObject var session: MobileSession
  let proposals: [ProposalDTO]
  @State private var reviewing = false
  var body: some View {
    Button { reviewing = true } label: {
      HStack(spacing: 12) {
        Image(systemName: "doc.text").font(.title3)
        VStack(alignment: .leading, spacing: 4) {
          Text("待确认修改").font(.headline)
          Text("\(proposals.count) 份草案 · 查看变更").font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
      }.padding(16).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
    }.buttonStyle(.plain)
    .sheet(isPresented: $reviewing) {
      NavigationStack {
        ScrollView { MobileProposalReview(session: session, proposals: proposals).padding() }
          .navigationTitle("确认修改")
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { reviewing = false } } }
      }
      #if os(iOS)
      .presentationDetents([.large]).presentationDragIndicator(.visible)
      #endif
    }
  }
}

private struct MobileProposalReview: View {
  @ObservedObject var session: MobileSession
  let proposals: [ProposalDTO]
  @State private var selectedIDs: Set<String> = []

  var body: some View {
    MobileSurface {
      VStack(alignment: .leading, spacing: 10) {
        MobileSectionHeading(
          title: "待确认修改", detail: "\(proposals.count) 份", icon: "doc.badge.gearshape")
        ForEach(proposals) { proposal in
          MobileProposalRow(proposal: proposal, isSelected: selectedIDs.contains(proposal.id)) {
            if selectedIDs.contains(proposal.id) {
              selectedIDs.remove(proposal.id)
            } else {
              selectedIDs.insert(proposal.id)
            }
          }
        }
        StudyButton("Face ID 确认并应用") {
          Task { await session.applyProposals(ids: Array(selectedIDs)) }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(selectedIDs.isEmpty || !session.canApplyProposals)
        Text("确认前不会写入正式仓库。")
          .studyTypography(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .onAppear { selectedIDs = Set(proposals.map(\.id)) }
    .onChange(of: proposals.map(\.id)) { _, ids in selectedIDs = Set(ids) }
  }
}

private struct MobileProposalRow: View {
  let proposal: ProposalDTO
  let isSelected: Bool
  let toggle: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Button(action: toggle) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        isSelected ? "取消选择 \(proposal.relativePath)" : "选择 \(proposal.relativePath)")
      DisclosureGroup(proposal.relativePath) {
        Text(proposal.reason).studyTypography(.footnote).foregroundStyle(.secondary)
        StudyProposalDiffView(original: proposal.originalContent, proposed: proposal.proposedContent,
                        renderMarkdown: { AnyView(MobileProposalMarkdownPreview(source: $0)) })
      }
    }
  }
}

private struct MobileChatMessage: View, Equatable {
  let message: ChatMessageDTO
  let contentWidth: CGFloat
  @State private var selecting = false
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.message == rhs.message && lhs.contentWidth == rhs.contentWidth }

  var body: some View {
    content
      .contextMenu {
        Button("复制", systemImage: "doc.on.doc") {
          #if os(iOS)
          UIPasteboard.general.string = message.text
          #else
          NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string)
          #endif
        }
        Button("选择文本", systemImage: "text.cursor") { selecting = true }
      }
      .sheet(isPresented: $selecting) {
        NavigationStack {
          ScrollView { Text(message.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            .navigationTitle("选择文本")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { selecting = false } } }
        }
      }
  }
  @ViewBuilder private var content: some View {
    if message.role == "user" {
      HStack {
        Spacer(minLength: 54)
        Text(message.text)
          .studyChatTypography()
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .foregroundStyle(.primary)
          .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        Group {
          if message.status == "inProgress" {
            // No Markdown parser or per-token animation while the server is
            // appending. The final event immediately restores rich formatting.
            Text(message.text)
              .studyChatTypography()
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            MobileMarkdownView(text: message.text, availableWidth: contentWidth)
          }
        }
        .transaction { $0.animation = nil }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct MobileChatActivityIndicator: View {
  let progress: MobileChatProgress

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      MobileBrandMark(size: 26)
        .padding(.top, 3)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(progress.title)
            .studyTypography(.subheadline, weight: .medium)
        }
        Text(progress.detail)
          .studyTypography(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.primary.opacity(0.08)))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(progress.title)
    .accessibilityHint(progress.detail)
  }
}

/// MarkdownUI's default table layout measures itself against the narrowest
/// available width on iPhone.  Keep normal prose flexible, but give a table a
/// stable column width inside a native horizontal scroller so it never forces
/// every character into its own line or overlaps the next message.
struct MobileMarkdownView: View {
  let text: String
  let availableWidth: CGFloat
  @ScaledMetric(relativeTo: .body) private var minimumTableColumnWidth: CGFloat = 144

  private var blocks: [StudyRocketMarkdownBlock] {
    StudyRocketMarkdownParser.blocks(from: text)
  }

  @ViewBuilder
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .prose(let value):
          markdown(value)
        case .table(let value, let columns):
          let sizing = MobileTableSizing(columns: columns, availableWidth: availableWidth,
                                         preferredColumnWidth: minimumTableColumnWidth)
          if sizing.scrollsHorizontally {
            VStack(alignment: .leading, spacing: 6) {
              Text("左右滑动查看完整表格")
                .studyTypography(.caption)
                .foregroundStyle(.secondary)
              ScrollView(.horizontal, showsIndicators: true) {
                markdown(value, tableCellWidth: sizing.cellWidth)
                  .frame(width: sizing.width, alignment: .leading)
              }
              .scrollIndicators(.visible)
            }
          } else {
            markdown(value, tableCellWidth: sizing.cellWidth)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func markdownHeading(_ configuration: BlockConfiguration, size: CGFloat) -> some View {
    let source = configuration.content.renderMarkdown()
    return Group {
      if MobileMarkdownLeaf.requiresImageRenderer(source) {
        configuration.label
      } else {
        MobileMarkdownLeaf(source: source, size: size, heading: true)
      }
    }
    .accessibilityAddTraits(.isHeader)
    .markdownMargin(top: .em(1), bottom: .em(0.5))
  }

  private func markdown(_ value: String, tableCellWidth: CGFloat? = nil) -> some View {
    Markdown(value)
      .markdownTheme(.basic)
      .markdownBlockStyle(\.paragraph) { configuration in
        let source = configuration.content.renderMarkdown()
        Group {
          if MobileMarkdownLeaf.requiresImageRenderer(source) {
            configuration.label
          } else {
            MobileMarkdownLeaf(source: source)
          }
        }
        .markdownMargin(top: .zero, bottom: .em(1))
      }
      .markdownBlockStyle(\.heading1) { markdownHeading($0, size: 24) }
      .markdownBlockStyle(\.heading2) { markdownHeading($0, size: 21) }
      .markdownBlockStyle(\.heading3) { markdownHeading($0, size: 19) }
      .markdownBlockStyle(\.heading4) { markdownHeading($0, size: 17) }
      .markdownBlockStyle(\.heading5) { markdownHeading($0, size: 17) }
      .markdownBlockStyle(\.heading6) { markdownHeading($0, size: 17) }
      .markdownBlockStyle(\.tableCell) { configuration in
        let source = configuration.content.renderMarkdown()
        Group {
          if MobileMarkdownLeaf.requiresImageRenderer(source) {
            configuration.label
          } else {
            MobileMarkdownLeaf(source: source, bold: configuration.row == 0)
          }
        }
        .frame(width: tableCellWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8).padding(.vertical, 6)
      }
      .markdownTextStyle {
        FontSize(17)
        ForegroundColor(.primary)
      }
      .studyChatTypography()
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MobileChatTurn: Identifiable {
  let id: String
  var user: ChatMessageDTO?
  var finalAnswers: [ChatMessageDTO]
  var process: [ChatMessageDTO]

  static func group(_ messages: [ChatMessageDTO]) -> [MobileChatTurn] {
    var ordered: [String] = []
    var buckets: [String: [ChatMessageDTO]] = [:]
    for message in messages {
      // Cloud turn IDs are the persisted client operation IDs. Keep the
      // optimistic user row in that same group when history acknowledges it.
      let pendingPrefix = "mobile-pending-"
      let localID = message.id.hasPrefix(pendingPrefix)
        ? String(message.id.dropFirst(pendingPrefix.count)) : message.id
      let key = message.turnID ?? localID
      if buckets[key] == nil { ordered.append(key) }
      buckets[key, default: []].append(message)
    }
    return ordered.compactMap { key in
      let items = buckets[key] ?? []
      let user = items.first { $0.role == "user" }
      let assistant = items.filter { $0.role == "assistant" }
      var final = assistant.filter { $0.phase == "final_answer" }
      var process = assistant.filter { $0.phase == "commentary" }
      let unknown = assistant.filter { $0.phase != "final_answer" && $0.phase != "commentary" }
      if final.isEmpty, let last = unknown.last {
        final = [last]
        process.append(contentsOf: unknown.dropLast())
      } else {
        process.append(contentsOf: unknown)
      }
      return MobileChatTurn(id: key, user: user, finalAnswers: final, process: process)
    }
  }
}

private struct MobileChatTurnView: View {
  let turn: MobileChatTurn
  let contentWidth: CGFloat
  let proposals: [ProposalDTO]
  @ObservedObject var session: MobileSession

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let user = turn.user {
        VStack(alignment: .trailing, spacing: 8) {
          if let attachments = user.attachments, !attachments.isEmpty {
            MobileSentAttachments(attachments: attachments, session: session)
          }
          if !user.text.isEmpty { MobileChatMessage(message: user, contentWidth: contentWidth).equatable() }
          if session.isFailedChatMessage(user) {
            StudyButton(session.retryingChat ? "正在核对远端状态…" : "重试这条消息") {
              Task { await session.retryFailedChat() }
            }
            .buttonStyle(.bordered)
            .disabled(session.retryingChat)
            .accessibilityHint("先核对原消息结果，确认失败后才重新发送")
          }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
      ForEach(turn.finalAnswers) { answer in
        MobileChatMessage(message: answer, contentWidth: contentWidth).equatable()
      }
      if !turn.process.isEmpty {
        MobileProcessDisclosure(messages: turn.process)
      }
      if !proposals.isEmpty {
        MobileProposalPanel(session: session, proposals: proposals)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MobileProcessDisclosure: View {
  let messages: [ChatMessageDTO]
  @State private var isExpanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { isExpanded.toggle() }
      } label: {
        StudyLabel(
          isExpanded ? "收起过程（\(messages.count)）" : "查看过程（\(messages.count)）",
          systemImage: isExpanded ? "chevron.down" : "chevron.right"
        )
        .studyTypography(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint(isExpanded ? "隐藏本轮过程消息" : "显示本轮过程消息")
      if isExpanded {
        ForEach(messages) { message in
          Text(message.text)
            .studyChatTypography(size: 15)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .padding(.horizontal, 12)
    .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.primary.opacity(0.08)))
  }
}

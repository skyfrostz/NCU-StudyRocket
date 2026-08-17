import Foundation
import SwiftUI
import StudyRocketShared
import MarkdownUI

public struct StudyRocketMobileRoot: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: MobileSession
    @State private var selectedTab = 0
    #if os(iOS)
    @StateObject private var reminders = MobileReminderScheduler.shared
    #endif

    public init(session: MobileSession = MobileSession()) {
        _session = StateObject(wrappedValue: session)
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            MobileHomeView(session: session) { selectedTab = $0 }
                .tabItem { Label("首页", systemImage: "house") }
                .tag(0)
            MobileChatView(session: session)
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(1)
            MobilePlanView(session: session) { selectedTab = $0 }
                .tabItem { Label("计划", systemImage: "calendar.badge.clock") }
                .tag(2)
            MobileDailyView(session: session)
                .tabItem { Label("复盘", systemImage: "checkmark.circle.fill") }
                .tag(3)
            MobileMoreView(session: session)
                .tabItem { Label("更多", systemImage: "ellipsis.circle") }
                .tag(4)
        }
        .tint(MobileTheme.brand)
        #if os(iOS)
        .task {
            await reminders.configure()
            await session.refresh()
            session.startEventStream()
        }
        .onChange(of: reminders.pendingRoute) { _, route in
            guard let route else { return }
            selectedTab = 1
            session.inputDraft = route.prompt
            _ = reminders.takePendingRoute()
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await session.refresh() }
            case .background, .inactive:
                session.stopEventStream()
            @unknown default:
                break
            }
        }
    }
}

private struct MobileStatusBanner: View {
    @ObservedObject var session: MobileSession

    var body: some View {
        MobileConnectionPill(state: session.state)
    }
}

private struct MobileHomeView: View {
    @ObservedObject var session: MobileSession
    let onNavigate: (Int) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if session.snapshot?.home == nil, session.savedEndpoint == nil {
                    unconfiguredContent
                } else {
                    homeContent
                }
            }
                .background(MobileTheme.groupedBackground)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
    }

    private var unconfiguredContent: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 18) {
                homeHeader
                quickActions

                Spacer(minLength: 0)

                MobileUnframedConnectionPrompt {
                    onNavigate(4)
                }
                .frame(maxWidth: .infinity)

                Spacer(minLength: 0)
            }
            .padding(MobileTheme.pageInset)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }

    private var homeContent: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    homeHeader
                    if let home = session.snapshot?.home {
                        MobileSurface {
                            VStack(alignment: .leading, spacing: 12) {
                                MobileSectionHeading(title: "现在先做什么", detail: "\(home.completedDeliveries)/\(home.totalDeliveries) 项交付物", icon: "scope")
                                if let firstOpenTask = home.firstOpenTask, !firstOpenTask.isEmpty {
                                    Text(firstOpenTask)
                                        .font(.system(.title3, design: .rounded, weight: .semibold))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Button { onNavigate(1) } label: {
                                        Label("和学业助理确认下一步", systemImage: "arrow.right")
                                            .font(.subheadline.weight(.medium))
                                    }
                                    .buttonStyle(.borderless)
                                } else {
                                    MobileInlineNotice(text: "今日尚未安排首要任务，可在周计划中补充。", symbol: "calendar.badge.plus")
                                }
                            }
                        }

                        MobileSurface {
                            VStack(alignment: .leading, spacing: 14) {
                                MobileSectionHeading(title: "今日安排", detail: "上午 · 中午 · 晚上", icon: "point.3.connected.trianglepath.dotted")
                                let todayDayID = todayDayID(for: home)
                                MobileTodayChecklist(
                                    periods: home.periods,
                                    canToggle: todayDayID != nil,
                                    completion: { period in
                                        guard let todayDayID else { return period.isCompleted }
                                        return session.effectivePeriodCompletion(dayID: todayDayID, period: period)
                                    },
                                    isPending: { period in
                                        guard let todayDayID else { return false }
                                        return session.isPeriodTogglePending(dayID: todayDayID, period: period)
                                    },
                                    onToggle: { period in
                                        guard let todayDayID else { return }
                                        Task { await session.togglePeriod(dayID: todayDayID, period: period) }
                                    }
                                )
                            }
                        }

                        MobileSurface {
                            VStack(alignment: .leading, spacing: 10) {
                                MobileSectionHeading(title: "本周交付物", detail: "不含今日安排", icon: "checklist")
                                MobileDeliveryOverview(
                                    deliveries: home.visibleDeliveries,
                                    completed: home.completedDeliveries,
                                    total: home.totalDeliveries
                                )
                            }
                        }
                    } else {
                        MobileSurface {
                            VStack(alignment: .leading, spacing: 14) {
                                MobileInlineNotice(text: "暂时无法连接 Mac Host。确认 Host 已启动、Tailscale 已连接并已启用 Serve。", symbol: "wifi.exclamationmark", tint: .orange)
                                HStack {
                                    Button("刷新") { Task { await session.refresh() } }
                                    Button("检查连接设置") { onNavigate(4) }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    quickActions
                }
                .padding(MobileTheme.pageInset)
                .safeAreaPadding(.bottom, 8)
            }
            .refreshable { await session.refresh() }
    }

    private var homeHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            MobileBrandMark(size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("NCU StudyRocket")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 8) {
                        homeDateLabel
                        MobileStatusBanner(session: session)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        homeDateLabel
                        MobileStatusBanner(session: session)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var homeDateLabel: some View {
        Text(session.snapshot?.home.dateLabel ?? "你的学习工作台")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var quickActions: some View {
        HStack(spacing: 8) {
            MobileQuickAction(title: "学业对话", symbol: "bubble.left.and.bubble.right", action: { onNavigate(1) })
            MobileQuickAction(title: "周计划", symbol: "calendar", action: { onNavigate(2) })
            MobileQuickAction(title: "写日结", symbol: "checkmark.circle", action: { onNavigate(3) })
        }
    }

    private func todayDayID(for home: HomeSnapshot) -> String? {
        guard let days = session.snapshot?.week.days else { return nil }
        if let exact = days.first(where: { $0.dateLabel == home.dateLabel }) { return exact.id }
        return days.first(where: { $0.id == Self.todayIDFormatter.string(from: .now) })?.id
    }

    private static let todayIDFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct MobileUnframedConnectionPrompt: View {
    let startConnection: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "desktopcomputer.and.arrow.down")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text("连接 Mac Host")
                .font(.system(.title2, design: .rounded, weight: .bold))
            Text("首次使用需要填写 Mac 的私有 HTTPS 地址，并输入 Host 窗口中的一次性配对码。")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("开始连接", action: startConnection)
                .buttonStyle(.borderedProminent)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 340)
    }
}

private struct MobileQuickAction: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.headline)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(MobileTheme.brand)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(MobileTheme.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct MobileChatView: View {
    @ObservedObject var session: MobileSession
    @State private var showJumpToLatest = false
    @FocusState private var isComposerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    MobileStatusBanner(session: session)
                    Spacer()
                    Menu {
                        Button("今天复盘") {
                            isComposerFocused = false
                            session.inputDraft = "今天复盘：请先询问我已完成的交付物、净学习时长、睡眠、运动和明日第一任务。"
                        }
                        Button("本周总结") {
                            isComposerFocused = false
                            session.inputDraft = "本周总结：请先向我收集本周已完成的具体交付物、未完成原因和下周约束。"
                        }
                        Button("排下周") {
                            isComposerFocused = false
                            session.inputDraft = "排下周：请先询问我可投入的时间、固定安排和本周遗留交付物。"
                        }
                    } label: {
                        Image(systemName: "bolt.circle")
                    }
                    .accessibilityLabel("快捷报告")
                }
                .padding(.horizontal, MobileTheme.pageInset)
                .padding(.vertical, 8)
                GeometryReader { container in
                    ScrollViewReader { proxy in
                        ZStack(alignment: .bottomTrailing) {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 16) {
                                    if session.chatMessages.isEmpty {
                                        MobileEmptyState(
                                            title: "还没有学业对话",
                                            message: "可以从下方输入课程问题、今日事实或计划调整。",
                                            symbol: "bubble.left.and.bubble.right",
                                            actionTitle: nil,
                                            action: nil
                                        )
                                        .frame(minHeight: max(260, container.size.height - 36))
                                    } else {
                                        ForEach(MobileChatTurn.group(session.chatMessages)) { turn in
                                            MobileChatTurnView(
                                                turn: turn,
                                                proposals: session.proposals.filter { $0.turnID == turn.id },
                                                session: session
                                            )
                                            .id(turn.id)
                                        }
                                    }
                                    let unassigned = session.proposals.filter { proposal in
                                        !session.chatMessages.contains { $0.turnID == proposal.turnID }
                                    }
                                    if !unassigned.isEmpty {
                                        MobileProposalPanel(session: session, proposals: unassigned)
                                    }
                                    Color.clear.frame(height: 1).id("chat-bottom")
                                        .background(
                                            GeometryReader { marker in
                                                Color.clear.preference(key: MobileChatBottomPreference.self, value: marker.frame(in: .named("mobile-chat-scroll")).minY)
                                            }
                                        )
                                }
                                .padding(.horizontal, MobileTheme.pageInset)
                                .padding(.vertical, 18)
                            }
                            .background(MobileTheme.groupedBackground)
                            #if os(iOS)
                            .scrollDismissesKeyboard(.interactively)
                            #endif
                            .coordinateSpace(name: "mobile-chat-scroll")
                            .onPreferenceChange(MobileChatBottomPreference.self) { bottomY in
                                showJumpToLatest = bottomY > container.size.height + 72
                            }
                            .onChange(of: session.chatRevision) { _, _ in
                                guard !showJumpToLatest else { return }
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                                }
                            }
                            .task {
                                await session.refreshChat()
                                await session.refreshProposals()
                                await Task.yield()
                                proxy.scrollTo("chat-bottom", anchor: .bottom)
                            }
                            if showJumpToLatest {
                                Button {
                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                                    }
                                    showJumpToLatest = false
                                } label: {
                                    Image(systemName: "arrow.down")
                                        .font(.headline.weight(.semibold))
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
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("输入学业问题或今日事实", text: $session.inputDraft, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($isComposerFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.primary.opacity(0.12)))
                    Button {
                        isComposerFocused = false
                        Task {
                            if session.isChatBusy { await session.interruptChat() }
                            else { await session.sendDraft() }
                        }
                    } label: {
                        Image(systemName: session.isChatBusy ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 31, weight: .semibold))
                    }
                    .disabled(!session.isChatBusy && session.inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(session.isChatBusy ? "停止对话" : "发送")
                }
                .padding(.horizontal, MobileTheme.pageInset)
                .padding(.vertical, 12)
                .safeAreaPadding(.bottom, 4)
                .background(.bar)
            }
            .navigationTitle("学业对话")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { isComposerFocused = false }
                }
            }
            #endif
            .onDisappear { isComposerFocused = false }
        }
    }
}

private struct MobileChatBottomPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MobileProposalPanel: View {
    @ObservedObject var session: MobileSession
    let proposals: [ProposalDTO]
    @State private var selectedIDs: Set<String> = []

    var body: some View {
        MobileSurface {
            VStack(alignment: .leading, spacing: 10) {
                MobileSectionHeading(title: "待确认修改", detail: "\(proposals.count) 份", icon: "doc.badge.gearshape")
            ForEach(proposals) { proposal in
                MobileProposalRow(proposal: proposal, isSelected: selectedIDs.contains(proposal.id)) {
                    if selectedIDs.contains(proposal.id) { selectedIDs.remove(proposal.id) }
                    else { selectedIDs.insert(proposal.id) }
                }
            }
            Button("Face ID 确认并应用") {
                Task { await session.applyProposals(ids: Array(selectedIDs)) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedIDs.isEmpty)
            Text("确认前不会写入 Mac 仓库。")
                .font(.caption)
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "取消选择 \(proposal.relativePath)" : "选择 \(proposal.relativePath)")
            DisclosureGroup(proposal.relativePath) {
                Text(proposal.reason).font(.footnote).foregroundStyle(.secondary)
                Text(proposal.proposedContent)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct MobileChatMessage: View {
    let message: ChatMessageDTO

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 54)
                Text(message.text)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(MobileTheme.brand, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            HStack(alignment: .top, spacing: 10) {
                MobileBrandMark(size: 26)
                    .padding(.top, 4)
                MobileMarkdownView(text: message.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// MarkdownUI's default table layout measures itself against the narrowest
/// available width on iPhone.  Keep normal prose flexible, but give a table a
/// stable column width inside a native horizontal scroller so it never forces
/// every character into its own line or overlaps the next message.
private struct MobileMarkdownView: View {
    let text: String
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text("左右滑动查看完整表格")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHint("横向滚动可查看表格的全部列")
                        ScrollView(.horizontal, showsIndicators: true) {
                            markdown(value)
                                .frame(minWidth: CGFloat(columns) * minimumTableColumnWidth, alignment: .leading)
                        }
                        .scrollIndicators(.visible)
                    }
                }
            }
        }
    }

    private func markdown(_ value: String) -> some View {
        Markdown(value)
            .markdownTheme(.basic)
            .markdownTextStyle {
                FontSize(15)
                ForegroundColor(.primary)
            }
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
            let key = message.turnID ?? message.id
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
    let proposals: [ProposalDTO]
    @ObservedObject var session: MobileSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let user = turn.user { MobileChatMessage(message: user) }
            ForEach(turn.finalAnswers) { answer in
                MobileChatMessage(message: answer)
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
                Label(isExpanded ? "收起过程（\(messages.count)）" : "查看过程（\(messages.count)）", systemImage: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "隐藏本轮过程消息" : "显示本轮过程消息")
            if isExpanded {
                ForEach(messages) { message in
                    Text(message.text)
                        .font(.footnote)
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

private enum MobilePlanFocus: Hashable {
    case slot(dayID: String, index: Int)
    case delivery(String)
    case buffer(String)
}

private struct MobilePlanView: View {
    @ObservedObject var session: MobileSession
    let onNavigate: (Int) -> Void
    @State private var selectedDayID = ""
    @State private var drafts: [String: [String]] = [:]
    @State private var deliveryDrafts: [String: String] = [:]
    @State private var bufferDrafts: [String: String] = [:]
    @State private var editableWeek: WeeklyPlanSnapshot?
    @State private var loadedRevision = ""
    @State private var incomingRevision: String?
    @State private var isSaving = false
    @State private var saveMessage: String?
    @State private var editorNotice: String?
    @FocusState private var focusedField: MobilePlanFocus?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if incomingRevision != nil {
                        MobileSurface {
                            VStack(alignment: .leading, spacing: 10) {
                                MobileInlineNotice(
                                    text: "Mac 端的周计划已更新，当前编辑仍保留，不会自动覆盖。",
                                    symbol: "arrow.triangle.2.circlepath",
                                    tint: .orange
                                )
                                Button("放弃当前编辑并重新载入") {
                                    focusedField = nil
                                    loadLatestSnapshot()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    if let week = editableWeek ?? session.snapshot?.week, !week.days.isEmpty {
                        let days = week.days
                        MobileSurface {
                            VStack(alignment: .leading, spacing: 14) {
                                MobileSectionHeading(title: "每日时段", detail: "点击切换日期", icon: "calendar")
                                Picker("日期", selection: $selectedDayID) {
                                    ForEach(days) { day in
                                        Text(day.dateLabel).tag(day.id)
                                    }
                                }
                                .pickerStyle(.menu)
                                if let day = days.first(where: { $0.id == selectedDayID }) ?? days.first {
                                    Text(day.dateLabel).font(.system(.title3, design: .rounded, weight: .semibold))
                                    ForEach(Array(day.slots.enumerated()), id: \.element.id) { index, slot in
                                        VStack(alignment: .leading, spacing: 7) {
                                            Label(slot.title, systemImage: slotSymbol(for: index))
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            TextEditor(text: binding(for: day, index: index))
                                                .font(.subheadline)
                                                .scrollContentBackground(.hidden)
                                                .padding(8)
                                                .frame(minHeight: 86)
                                                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                                .focused($focusedField, equals: .slot(dayID: day.id, index: index))
                                        }
                                    }
                                    Button("保存周计划") {
                                        guard incomingRevision == nil else { return }
                                        focusedField = nil
                                        editorNotice = nil
                                        let updated = updatedDays(from: days)
                                        let deliveries = week.deliveries.map { delivery in
                                            DeliverySnapshot(id: delivery.id, text: deliveryDrafts[delivery.id] ?? delivery.text, isCompleted: delivery.isCompleted, dateLabel: delivery.dateLabel)
                                        }
                                        let buffers = week.bufferRules.map { rule in
                                            BufferRuleSnapshot(id: rule.id, category: rule.category, text: bufferDrafts[rule.id] ?? rule.text)
                                        }
                                        let plan = WeeklyPlanSnapshot(days: updated, bufferRules: buffers, deliveries: deliveries, historicalRows: week.historicalRows, futureRows: week.futureRows)
                                        isSaving = true
                                        Task {
                                            await session.saveWeek(plan)
                                            if session.state == .online { loadLatestSnapshot() }
                                            saveMessage = session.state == .online ? "已提交保存。" : "已保存到本机草稿，联网后可比较并提交。"
                                            isSaving = false
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(incomingRevision != nil || isSaving)
                                    if let saveMessage { MobileInlineNotice(text: saveMessage, symbol: "checkmark.circle", tint: session.state == .online ? .teal : .orange) }
                                }
                            }
                        }
                        if !week.deliveries.isEmpty {
                            MobileSurface {
                                VStack(alignment: .leading, spacing: 12) {
                                MobileSectionHeading(title: "本周交付物", icon: "checklist")
                                if let editorNotice {
                                    MobileInlineNotice(text: editorNotice, symbol: "square.and.arrow.down", tint: .orange)
                                }
                                ForEach(week.deliveries) { delivery in
                                    let deliveryTextChanged = (deliveryDrafts[delivery.id] ?? delivery.text) != delivery.text
                                    VStack(alignment: .leading, spacing: 8) {
                                        Button {
                                            focusedField = nil
                                            guard !deliveryTextChanged else {
                                                editorNotice = "交付物正文已修改，请先保存周计划，再切换完成状态。"
                                                return
                                            }
                                            Task { await session.toggleDelivery(delivery) }
                                        } label: {
                                            Label(delivery.isCompleted ? "已完成" : "未完成", systemImage: delivery.isCompleted ? "checkmark.circle.fill" : "circle")
                                                .font(.caption)
                                                .foregroundStyle(delivery.isCompleted ? .teal : .secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(incomingRevision != nil || isSaving)
                                        TextEditor(text: binding(for: delivery))
                                            .font(.subheadline)
                                            .scrollContentBackground(.hidden)
                                            .padding(8)
                                            .frame(minHeight: 54, maxHeight: 120)
                                            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            .focused($focusedField, equals: .delivery(delivery.id))
                                    }
                                }
                                }
                            }
                        }
                        if !week.bufferRules.isEmpty {
                            MobileSurface {
                                VStack(alignment: .leading, spacing: 12) {
                                MobileSectionHeading(title: "缓冲与降级", icon: "shield")
                                ForEach(week.bufferRules) { rule in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(rule.category == "collision" ? "撞车降级" : rule.category == "minimum" ? "最低底线" : "日常缓冲")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(rule.category == "minimum" ? .red : rule.category == "collision" ? .orange : MobileTheme.rail)
                                        TextEditor(text: binding(for: rule))
                                            .font(.subheadline)
                                            .scrollContentBackground(.hidden)
                                            .padding(8)
                                            .frame(minHeight: 54, maxHeight: 120)
                                            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            .focused($focusedField, equals: .buffer(rule.id))
                                    }
                                }
                                }
                            }
                        }
                    } else {
                        MobileEmptyState(
                            title: "暂无计划缓存",
                            message: session.savedEndpoint == nil
                                ? "先连接 Mac Host，手机才会显示周计划。"
                                : "当前没有可读取的周计划缓存，请刷新 Mac Host。",
                            symbol: "calendar.badge.exclamationmark",
                            actionTitle: session.savedEndpoint == nil ? "前往配对" : "刷新数据",
                            action: {
                                if session.savedEndpoint == nil { onNavigate(4) }
                                else { Task { await session.refresh() } }
                            }
                        )
                        .frame(minHeight: 520)
                    }
                }
                .padding(MobileTheme.pageInset)
                .safeAreaPadding(.bottom, 8)
            }
            .navigationTitle("周计划")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .background(MobileTheme.groupedBackground)
            .onAppear { handleSnapshotRevisionChange() }
            .onChange(of: session.snapshot?.revision) { _, _ in handleSnapshotRevisionChange() }
            .onChange(of: selectedDayID) { _, _ in focusedField = nil }
            .onDisappear { focusedField = nil }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                }
            }
            #endif
        }
    }

    private var isPlanDirty: Bool {
        guard let week = editableWeek else { return false }
        return drafts != Dictionary(uniqueKeysWithValues: week.days.map { ($0.id, $0.slots.map(\.text)) })
            || deliveryDrafts != Dictionary(uniqueKeysWithValues: week.deliveries.map { ($0.id, $0.text) })
            || bufferDrafts != Dictionary(uniqueKeysWithValues: week.bufferRules.map { ($0.id, $0.text) })
    }

    private func handleSnapshotRevisionChange() {
        guard !isSaving,
              let snapshot = session.snapshot,
              snapshot.revision != loadedRevision
        else { return }
        let latestWeek = snapshot.week
        if loadedRevision.isEmpty {
            loadLatestSnapshot()
            return
        }
        if let editableWeek, latestWeek == editableWeek {
            loadedRevision = snapshot.revision
            incomingRevision = nil
            return
        }
        guard !isPlanDirty, focusedField == nil else {
            incomingRevision = snapshot.revision
            return
        }
        loadLatestSnapshot()
    }

    private func loadLatestSnapshot() {
        guard let snapshot = session.snapshot else { return }
        let week = snapshot.week
        editableWeek = week
        loadedRevision = snapshot.revision
        incomingRevision = nil
        saveMessage = nil
        editorNotice = nil
        drafts = Dictionary(uniqueKeysWithValues: week.days.map { ($0.id, $0.slots.map(\.text)) })
        deliveryDrafts = Dictionary(uniqueKeysWithValues: week.deliveries.map { ($0.id, $0.text) })
        bufferDrafts = Dictionary(uniqueKeysWithValues: week.bufferRules.map { ($0.id, $0.text) })
        if !week.days.contains(where: { $0.id == selectedDayID }) {
            selectedDayID = week.days.first?.id ?? ""
        }
    }

    private func binding(for day: DaySnapshot, index: Int) -> Binding<String> {
        Binding {
            drafts[day.id]?[safe: index] ?? day.slots[safe: index]?.text ?? ""
        } set: { value in
            var values = drafts[day.id] ?? day.slots.map(\.text)
            while values.count <= index { values.append("") }
            values[index] = value
            drafts[day.id] = values
        }
    }

    private func updatedDays(from days: [DaySnapshot]) -> [DaySnapshot] {
        days.map { day in
            let values = drafts[day.id] ?? day.slots.map(\.text)
            let slots = day.slots.enumerated().map { index, slot in
                PeriodSnapshot(id: slot.id, title: slot.title, text: values[safe: index] ?? "", isCompleted: slot.isCompleted)
            }
            return DaySnapshot(id: day.id, dateLabel: day.dateLabel, slots: slots, unassigned: day.unassigned)
        }
    }

    private func binding(for delivery: DeliverySnapshot) -> Binding<String> {
        Binding(get: { deliveryDrafts[delivery.id] ?? delivery.text }, set: { deliveryDrafts[delivery.id] = $0 })
    }

    private func binding(for rule: BufferRuleSnapshot) -> Binding<String> {
        Binding(get: { bufferDrafts[rule.id] ?? rule.text }, set: { bufferDrafts[rule.id] = $0 })
    }

    private func slotSymbol(for index: Int) -> String {
        switch index {
        case 0: "sun.max"
        case 1: "sun.and.horizon"
        default: "moon.stars"
        }
    }
}

private struct MobileDailyView: View {
    @ObservedObject var session: MobileSession
    @State private var deliverables = ""
    @State private var studyTime = ""
    @State private var sleep = ""
    @State private var exercise = ""
    @State private var firstTask = ""
    @State private var loadedDaily: DailySnapshot?
    @State private var loadedRevision = ""
    @State private var incomingRevision: String?
    @State private var isSaving = false
    @State private var saveMessage: String?
    @FocusState private var focusedField: MobileDailyField?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top) {
                            dailyHeaderText
                            Spacer()
                            MobileStatusBanner(session: session)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            dailyHeaderText
                            MobileStatusBanner(session: session)
                        }
                    }
                    MobileSurface {
                        VStack(alignment: .leading, spacing: 16) {
                            MobileSectionHeading(title: "今天的五项事实", detail: "仅保存你确认的内容", icon: "checkmark.circle")
                            if incomingRevision != nil {
                                MobileInlineNotice(
                                    text: "Mac 端的今日记录已更新，当前输入仍保留，不会自动覆盖。",
                                    symbol: "arrow.triangle.2.circlepath",
                                    tint: .orange
                                )
                                Button("放弃当前输入并重新载入") {
                                    focusedField = nil
                                    loadLatestSnapshot()
                                }
                                .buttonStyle(.bordered)
                            }
                            MobileFactField(title: "完成交付物", symbol: "checklist", placeholder: "完成了什么", text: $deliverables, field: .deliverables, focus: $focusedField, multiline: true)
                            MobileFactField(title: "净学习时长", symbol: "clock", placeholder: "例如 3 小时 20 分钟", text: $studyTime, field: .studyTime, focus: $focusedField)
                            MobileFactField(title: "睡眠", symbol: "bed.double", placeholder: "入睡 / 起床时间", text: $sleep, field: .sleep, focus: $focusedField)
                            MobileFactField(title: "运动", symbol: "figure.run", placeholder: "项目和时长", text: $exercise, field: .exercise, focus: $focusedField)
                            MobileFactField(title: "明日第一任务", symbol: "arrow.right.circle", placeholder: "从哪一步开始", text: $firstTask, field: .firstTask, focus: $focusedField, multiline: true)
                            Button("保存行为账") {
                                guard incomingRevision == nil else { return }
                                focusedField = nil
                                let date = currentDailyDate
                                guard !date.isEmpty else {
                                    saveMessage = "尚未取得有效日期，请先连接并刷新 Mac Host。"
                                    return
                                }
                                let entry = DailySnapshot(date: date, deliverables: deliverables, studyTime: studyTime, sleep: sleep, exercise: exercise, firstTask: firstTask)
                                isSaving = true
                                Task {
                                    await session.saveDaily(entry)
                                    if session.state == .online { loadLatestSnapshot() }
                                    saveMessage = session.state == .online ? "已提交保存。" : "已保存到本机草稿，联网后可比较并提交。"
                                    isSaving = false
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(incomingRevision != nil || isSaving || currentDailyDate.isEmpty)
                            if let saveMessage { MobileInlineNotice(text: saveMessage, symbol: "checkmark.circle", tint: session.state == .online ? .teal : .orange) }
                        }
                    }
                }
                .padding(MobileTheme.pageInset)
                .safeAreaPadding(.bottom, 8)
            }
            .background(MobileTheme.groupedBackground)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear { handleSnapshotRevisionChange() }
            .onChange(of: session.snapshot?.revision) { _, _ in handleSnapshotRevisionChange() }
            .onDisappear { focusedField = nil }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                }
            }
            #endif
        }
    }

    private var isDailyDirty: Bool {
        guard let daily = loadedDaily else { return false }
        return deliverables != daily.deliverables
            || studyTime != daily.studyTime
            || sleep != daily.sleep
            || exercise != daily.exercise
            || firstTask != daily.firstTask
    }

    private var currentDailyDate: String {
        loadedDaily?.date ?? session.snapshot?.daily.date ?? ""
    }

    private var dailyHeaderText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("每日复盘")
                .font(.system(.title2, design: .rounded, weight: .bold))
            Text(currentDailyDate.isEmpty ? "等待 Mac Host" : currentDailyDate)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func handleSnapshotRevisionChange() {
        guard !isSaving, let snapshot = session.snapshot, snapshot.revision != loadedRevision else { return }
        if loadedRevision.isEmpty {
            loadLatestSnapshot()
            return
        }
        if let loadedDaily, snapshot.daily == loadedDaily {
            loadedRevision = snapshot.revision
            incomingRevision = nil
            return
        }
        guard !isDailyDirty, focusedField == nil else {
            incomingRevision = snapshot.revision
            return
        }
        loadLatestSnapshot()
    }

    private func loadLatestSnapshot() {
        guard let snapshot = session.snapshot else { return }
        let daily = snapshot.daily
        loadedDaily = daily
        loadedRevision = snapshot.revision
        incomingRevision = nil
        saveMessage = nil
        deliverables = daily.deliverables
        studyTime = daily.studyTime
        sleep = daily.sleep
        exercise = daily.exercise
        firstTask = daily.firstTask
    }
}

private enum MobilePairingFocus: Hashable {
    case endpoint
    case code
    case deviceName
}

private struct MobileMoreView: View {
    @ObservedObject var session: MobileSession
    @State private var endpoint: String
    @State private var pairingCode = ""
    @State private var deviceName = "我的 iPhone"
    @State private var pairingMessage: String?
    @State private var showPairingForm: Bool
    @State private var showDiscardDraftsConfirmation = false
    @State private var showClearCacheConfirmation = false
    @FocusState private var focusedPairingField: MobilePairingFocus?
    #if os(iOS)
    @ObservedObject private var reminders = MobileReminderScheduler.shared
    #endif

    init(session: MobileSession) {
        self.session = session
        _endpoint = State(initialValue: session.savedEndpoint ?? "https://")
        _showPairingForm = State(initialValue: session.savedEndpoint == nil)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("连接") {
                    MobileStatusBanner(session: session)
                    if let issue = session.lastConnectionIssue, session.state != .online {
                        Text(issue)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if session.state == .online {
                        MobilePrimaryButton(title: "刷新数据", symbol: "arrow.clockwise") {
                            focusedPairingField = nil
                            Task { await session.refresh() }
                        }
                        Button(showPairingForm ? "收起配对设置" : "更换 Mac Host") {
                            focusedPairingField = nil
                            showPairingForm.toggle()
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    } else if session.savedEndpoint != nil {
                        MobilePrimaryButton(title: "刷新数据", symbol: "arrow.clockwise") {
                            focusedPairingField = nil
                            Task { await session.refresh() }
                        }
                        Button(showPairingForm ? "收起配对设置" : "重新配对") {
                            focusedPairingField = nil
                            showPairingForm.toggle()
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }

                    if showPairingForm || session.savedEndpoint == nil {
                        TextField("Mac Host HTTPS 地址", text: $endpoint)
                            .focused($focusedPairingField, equals: .endpoint)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .submitLabel(.next)
                            #endif
                            .autocorrectionDisabled()
                            .onSubmit { focusedPairingField = .code }
                        TextField("一次性配对码", text: $pairingCode)
                            .focused($focusedPairingField, equals: .code)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.next)
                            #endif
                            .autocorrectionDisabled()
                            .onSubmit { focusedPairingField = .deviceName }
                        TextField("设备名称", text: $deviceName)
                            .focused($focusedPairingField, equals: .deviceName)
                            #if os(iOS)
                            .submitLabel(.done)
                            #endif
                            .onSubmit { focusedPairingField = nil }
                        MobilePrimaryButton(title: "配对并连接", symbol: "link.badge.plus") {
                            focusedPairingField = nil
                            guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                                pairingMessage = "地址格式不正确。"
                                return
                            }
                            Task {
                                do {
                                    try await session.pair(endpoint: url, code: pairingCode, deviceName: deviceName)
                                    pairingMessage = "配对成功。"
                                    showPairingForm = false
                                } catch {
                                    pairingMessage = error.localizedDescription
                                }
                            }
                        }
                    }
                    if let pairingMessage {
                        Text(pairingMessage)
                            .font(.footnote)
                            .foregroundStyle(session.state == .online ? .teal : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let summaries = session.snapshot?.summaries, !summaries.isEmpty {
                    Section("学习资料") {
                        ForEach(summaries) { summary in
                            let key = summary.documentKey ?? legacyDocumentKey(summary.id)
                            if let key {
                                NavigationLink {
                                    MobileDocumentDetailView(session: session, documentKey: key, title: summary.title)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "doc.text")
                                            .foregroundStyle(MobileTheme.rail)
                                        Text(summary.title)
                                            .font(.body.weight(.medium))
                                        Spacer(minLength: 0)
                                    }
                                    .frame(minHeight: 44)
                                }
                                .simultaneousGesture(TapGesture().onEnded { focusedPairingField = nil })
                            }
                        }
                    }
                }
                Section("Host 与配对") {
                    if let health = session.health {
                        LabeledContent("仓库", value: health.repositoryBound ? "已绑定" : "未绑定")
                        LabeledContent("Codex", value: health.codexReady ? "已就绪" : "不可用")
                        LabeledContent("草案工具", value: health.dynamicToolsReady == true ? "已校验" : "待校验")
                        LabeledContent("已配对设备", value: "\(health.pairedDeviceCount) 台")
                        if let threadID = health.activeThreadID {
                            Text("固定学业任务：\(threadID)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text("连接 Mac Host 后显示仓库、Codex 和配对状态。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if session.hasPendingDrafts {
                    Section("本机待提交草稿") {
                        Text("离线编辑尚未写入 Mac。提交前会重新比较最新版本，冲突时不会自动合并。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("比较最新版本并提交") {
                            Task { await session.commitPendingDrafts() }
                        }
                        .disabled(session.state != .online)
                        Button("放弃本机草稿", role: .destructive) {
                            focusedPairingField = nil
                            showDiscardDraftsConfirmation = true
                        }
                    }
                }
                Section("隐私与缓存") {
                    Text("手机只保留最近一次快照、当前输入草稿、待提交草稿，以及你打开过的五份只读学习资料缓存；PDF、Git 和完整聊天历史留在 Mac。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("清除本机缓存", role: .destructive) {
                        focusedPairingField = nil
                        showClearCacheConfirmation = true
                    }
                }
                #if os(iOS)
                Section("提醒") {
                    Toggle("手机日 / 周 / 月复盘提醒", isOn: Binding(get: { reminders.enabled }, set: { reminders.setEnabled($0) }))
                    Text("每日 21:30、每周日 19:30、每月最后一天 19:30 独立提醒；点击后只预填问题，不自动发送。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                #endif
            }
            .navigationTitle("更多")
            .onDisappear { focusedPairingField = nil }
            .confirmationDialog("放弃所有本机待提交草稿？", isPresented: $showDiscardDraftsConfirmation, titleVisibility: .visible) {
                Button("放弃草稿", role: .destructive) { session.discardPendingDrafts() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("尚未写入 Mac 的周计划、日结、交付物和时段完成修改将被删除。")
            }
            .confirmationDialog("清除本机缓存？", isPresented: $showClearCacheConfirmation, titleVisibility: .visible) {
                Button("清除缓存", role: .destructive) { session.clearLocalCache() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除快照、已读资料缓存、输入草稿和待提交草稿；Host 地址与配对身份保留。")
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedPairingField = nil }
                }
            }
            #endif
        }
    }

    private func legacyDocumentKey(_ id: String) -> String? {
        if id == "course" || id.hasSuffix("/课程.md") { return "course" }
        if id == "research" || id.hasSuffix("/科研.md") { return "research" }
        if id == "recommendation" || id.hasSuffix("/保研.md") { return "recommendation" }
        if id == "life" || id.hasSuffix("/生活.md") { return "life" }
        if id == "library" || id.hasSuffix("/来源索引.md") { return "library" }
        return nil
    }
}

private struct MobileDocumentDetailView: View {
    @ObservedObject var session: MobileSession
    let documentKey: String
    let title: String
    @State private var detail: DocumentDetail?
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            Group {
                if let detail {
                    MobileMarkdownView(text: detail.markdown)
                        .textSelection(.enabled)
                } else if isLoading {
                    ProgressView("正在读取资料")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    MobileEmptyState(
                        title: "暂时无法读取",
                        message: "连接 Mac Host 后重试；如果之前打开过此资料，也会优先显示本机缓存。",
                        symbol: "doc.text.magnifyingglass",
                        actionTitle: "刷新数据",
                        action: { Task { await load() } }
                    )
                    .frame(minHeight: 360)
                }
            }
            .padding(MobileTheme.pageInset)
        }
        .background(MobileTheme.groupedBackground)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        detail = await session.document(for: documentKey)
        isLoading = false
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

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
            homeContent
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var homeContent: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 12) {
                        MobileBrandMark(size: 46)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("NCU StudyRocket")
                                .font(.system(.title2, design: .rounded, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                            HStack(alignment: .center, spacing: 8) {
                                Text(session.snapshot?.home.dateLabel ?? "你的学习工作台")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                MobileStatusBanner(session: session)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
                                MobileDayRail(periods: home.periods)
                            }
                        }

                        MobileSurface {
                            VStack(alignment: .leading, spacing: 10) {
                                MobileSectionHeading(title: "本周交付物", detail: "不含今日安排", icon: "checklist")
                                if home.visibleDeliveries.isEmpty {
                                    Text("除今日安排外，本周暂无其他交付物")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(home.visibleDeliveries) { delivery in
                                        Button {
                                            Task { await session.toggleDelivery(delivery) }
                                        } label: {
                                            HStack(alignment: .top, spacing: 10) {
                                                Image(systemName: delivery.isCompleted ? "checkmark.circle.fill" : "circle")
                                                    .foregroundStyle(delivery.isCompleted ? MobileTheme.completion : .secondary)
                                                    .padding(.top, 1)
                                                Text(delivery.text)
                                                    .font(.subheadline)
                                                    .foregroundStyle(delivery.isCompleted ? .secondary : .primary)
                                                    .strikethrough(delivery.isCompleted, color: .secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                Spacer(minLength: 0)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 5)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    } else {
                        if session.savedEndpoint == nil {
                            MobileHomeConnectionCard { onNavigate(4) }
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
                    }

                    HStack(spacing: 8) {
                        MobileQuickAction(title: "学业对话", symbol: "bubble.left.and.bubble.right", action: { onNavigate(1) })
                        MobileQuickAction(title: "周计划", symbol: "calendar", action: { onNavigate(2) })
                        MobileQuickAction(title: "写日结", symbol: "checkmark.circle", action: { onNavigate(3) })
                    }
                }
                .padding(MobileTheme.pageInset)
            }
            .refreshable { await session.refresh() }
    }
}

private struct MobileHomeConnectionCard: View {
    let startConnection: () -> Void

    var body: some View {
        MobileSurface {
            VStack(alignment: .leading, spacing: 14) {
                MobileBrandMark(size: 54)
                Text("连接你的 Mac Host")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                Text("从 Mac 的 StudyRocket Host 复制私有 HTTPS 地址和一次性配对码，即可在手机继续查看计划、复盘和对话。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("开始连接", action: startConnection)
                    .buttonStyle(.borderedProminent)
            }
        }
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    MobileStatusBanner(session: session)
                    Spacer()
                    Menu {
                        Button("今天复盘") { session.inputDraft = "今天复盘：请先询问我已完成的交付物、净学习时长、睡眠、运动和明日第一任务。" }
                        Button("本周总结") { session.inputDraft = "本周总结：请先向我收集本周已完成的具体交付物、未完成原因和下周约束。" }
                        Button("排下周") { session.inputDraft = "排下周：请先询问我可投入的时间、固定安排和本周遗留交付物。" }
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
                            .background(Color(uiColor: .systemGroupedBackground))
                            .coordinateSpace(name: "mobile-chat-scroll")
                            .onPreferenceChange(MobileChatBottomPreference.self) { bottomY in
                                showJumpToLatest = bottomY > container.size.height + 72
                            }
                            .onChange(of: session.chatRevision) { _, _ in
                                guard !showJumpToLatest else { return }
                                withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                            }
                            .task {
                                await session.refreshChat()
                                await session.refreshProposals()
                                await Task.yield()
                                proxy.scrollTo("chat-bottom", anchor: .bottom)
                            }
                            if showJumpToLatest {
                                Button {
                                    withAnimation(.easeOut(duration: 0.16)) {
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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.primary.opacity(0.12)))
                    Button {
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
                .background(.bar)
            }
            .navigationTitle("学业对话")
            .navigationBarTitleDisplayMode(.inline)
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
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                MobileBrandMark(size: 26)
                    .alignmentGuide(.firstTextBaseline) { dimension in dimension[VerticalAlignment.center] }
                Markdown(message.text)
                    .markdownTheme(.gitHub)
                    .markdownTextStyle {
                        FontSize(15)
                        ForegroundColor(.primary)
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { isExpanded.toggle() }
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

private struct MobilePlanView: View {
    @ObservedObject var session: MobileSession
    let onNavigate: (Int) -> Void
    @State private var selectedDayID = ""
    @State private var drafts: [String: [String]] = [:]
    @State private var deliveryDrafts: [String: String] = [:]
    @State private var bufferDrafts: [String: String] = [:]
    @State private var loadedRevision = ""
    @State private var saveMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let week = session.snapshot?.week, !week.days.isEmpty {
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
                                        }
                                    }
                                    Button("保存当天计划") {
                                        let updated = updatedDays(from: days)
                                        let deliveries = week.deliveries.map { delivery in
                                            DeliverySnapshot(id: delivery.id, text: deliveryDrafts[delivery.id] ?? delivery.text, isCompleted: delivery.isCompleted, dateLabel: delivery.dateLabel)
                                        }
                                        let buffers = week.bufferRules.map { rule in
                                            BufferRuleSnapshot(id: rule.id, category: rule.category, text: bufferDrafts[rule.id] ?? rule.text)
                                        }
                                        Task {
                                            await session.saveWeek(WeeklyPlanSnapshot(days: updated, bufferRules: buffers, deliveries: deliveries, historicalRows: week.historicalRows, futureRows: week.futureRows))
                                            saveMessage = session.state == .online ? "已提交保存。" : "已保存到本机草稿，联网后可比较并提交。"
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    if let saveMessage { MobileInlineNotice(text: saveMessage, symbol: "checkmark.circle", tint: session.state == .online ? .teal : .orange) }
                                }
                            }
                        }
                        if !week.deliveries.isEmpty {
                            MobileSurface {
                                VStack(alignment: .leading, spacing: 12) {
                                MobileSectionHeading(title: "本周交付物", icon: "checklist")
                                ForEach(week.deliveries) { delivery in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Button {
                                            Task { await session.toggleDelivery(delivery) }
                                        } label: {
                                            Label(delivery.isCompleted ? "已完成" : "未完成", systemImage: delivery.isCompleted ? "checkmark.circle.fill" : "circle")
                                                .font(.caption)
                                                .foregroundStyle(delivery.isCompleted ? .teal : .secondary)
                                        }
                                        .buttonStyle(.plain)
                                        TextEditor(text: binding(for: delivery))
                                            .font(.subheadline)
                                            .scrollContentBackground(.hidden)
                                            .padding(8)
                                            .frame(minHeight: 54, maxHeight: 120)
                                            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            }
            .navigationTitle("周计划")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(uiColor: .systemGroupedBackground))
            .onAppear { syncSelection() }
            .onChange(of: session.snapshot?.revision) { _, _ in syncSelection() }
        }
    }

    private func syncSelection() {
        guard let week = session.snapshot?.week, let first = week.days.first else { return }
        if selectedDayID.isEmpty { selectedDayID = first.id }
        guard loadedRevision != (session.snapshot?.revision ?? "") else { return }
        loadedRevision = session.snapshot?.revision ?? ""
        drafts = Dictionary(uniqueKeysWithValues: week.days.map { ($0.id, $0.slots.map(\.text)) })
        deliveryDrafts = Dictionary(uniqueKeysWithValues: week.deliveries.map { ($0.id, $0.text) })
        bufferDrafts = Dictionary(uniqueKeysWithValues: week.bufferRules.map { ($0.id, $0.text) })
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
                PeriodSnapshot(id: slot.id, title: slot.title, text: values[safe: index] ?? "")
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
    @State private var saveMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("每日复盘")
                                .font(.system(.title2, design: .rounded, weight: .bold))
                            Text(session.snapshot?.daily.date ?? "等待 Mac Host")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        MobileStatusBanner(session: session)
                    }
                    MobileSurface {
                        VStack(alignment: .leading, spacing: 16) {
                            MobileSectionHeading(title: "今天的五项事实", detail: "仅保存你确认的内容", icon: "checkmark.circle")
                            MobileFactField(title: "完成交付物", symbol: "checklist", placeholder: "完成了什么", text: $deliverables, multiline: true)
                            MobileFactField(title: "净学习时长", symbol: "clock", placeholder: "例如 3 小时 20 分钟", text: $studyTime)
                            MobileFactField(title: "睡眠", symbol: "bed.double", placeholder: "入睡 / 起床时间", text: $sleep)
                            MobileFactField(title: "运动", symbol: "figure.run", placeholder: "项目和时长", text: $exercise)
                            MobileFactField(title: "明日第一任务", symbol: "arrow.right.circle", placeholder: "从哪一步开始", text: $firstTask, multiline: true)
                            Button("保存行为账") {
                                let date = session.snapshot?.daily.date ?? ""
                                Task {
                                    await session.saveDaily(DailySnapshot(date: date, deliverables: deliverables, studyTime: studyTime, sleep: sleep, exercise: exercise, firstTask: firstTask))
                                    saveMessage = session.state == .online ? "已提交保存。" : "已保存到本机草稿，联网后可比较并提交。"
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            if let saveMessage { MobileInlineNotice(text: saveMessage, symbol: "checkmark.circle", tint: session.state == .online ? .teal : .orange) }
                        }
                    }
                }
                .padding(MobileTheme.pageInset)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { syncFields() }
            .onChange(of: session.snapshot?.revision) { _, _ in syncFields() }
        }
    }

    private func syncFields() {
        guard let daily = session.snapshot?.daily else { return }
        deliverables = daily.deliverables
        studyTime = daily.studyTime
        sleep = daily.sleep
        exercise = daily.exercise
        firstTask = daily.firstTask
    }
}

private struct MobileMoreView: View {
    @ObservedObject var session: MobileSession
    @State private var endpoint: String
    @State private var pairingCode = ""
    @State private var deviceName = "我的 iPhone"
    @State private var pairingMessage: String?
    @State private var showPairingForm: Bool
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
                if let summaries = session.snapshot?.summaries, !summaries.isEmpty {
                    Section("学习资料") {
                        ForEach(summaries) { summary in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(summary.title).font(.headline)
                                Text(summary.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                Section("连接") {
                    MobileStatusBanner(session: session)
                    if session.state == .online {
                        MobilePrimaryButton(title: "刷新数据", symbol: "arrow.clockwise") {
                            Task { await session.refresh() }
                        }
                        Button(showPairingForm ? "收起配对设置" : "更换 Mac Host") {
                            showPairingForm.toggle()
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    } else if session.savedEndpoint != nil {
                        MobilePrimaryButton(title: "刷新数据", symbol: "arrow.clockwise") {
                            Task { await session.refresh() }
                        }
                        Button(showPairingForm ? "收起配对设置" : "重新配对") {
                            showPairingForm.toggle()
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }

                    if showPairingForm || session.savedEndpoint == nil {
                        TextField("Mac Host HTTPS 地址", text: $endpoint)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("一次性配对码", text: $pairingCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("设备名称", text: $deviceName)
                        MobilePrimaryButton(title: "配对并连接", symbol: "link.badge.plus") {
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
                            session.discardPendingDrafts()
                        }
                    }
                }
                Section("隐私与缓存") {
                    Text("手机只保留最近一次快照、当前输入草稿和待提交草稿；完整 Markdown、PDF、Git 和完整聊天历史留在 Mac。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("清除本机缓存", role: .destructive) {
                        session.clearLocalCache()
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
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

import SwiftUI
import MarkdownUI

struct ContentView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var document: MarkdownDocumentModel
    @EnvironmentObject private var chat: StudyChatStore
    @EnvironmentObject private var reminders: ReminderScheduler
    @State private var selection: AppSection? = .home
    @State private var pendingSection: AppSection?
    @State private var showBinder = false
    @State private var showUnsavedSectionDialog = false
    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: Binding(get: { selection }, set: { requestSection($0) })) { section in
                Label(section.title, systemImage: section.icon).tag(section)
            }
            .navigationTitle("StudyRocket")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    Label(workspace.gitStatus, systemImage: workspace.gitStatus == "已同步" ? "checkmark.seal" : "circle.dotted")
                        .font(.caption).foregroundStyle(workspace.gitStatus == "已同步" ? .green : .orange)
                    Button("重新绑定仓库", systemImage: "folder") { showBinder = true }
                        .font(.caption)
                }.padding(12)
            }
        } detail: {
            Group {
                switch selection ?? .home {
                case .home: DashboardView()
                case .chat: StudyChatView()
                case .week: WeeklyPlanView()
                case .daily: DailyCheckinView()
                case .routes: RouteView(title: "四条航线", files: ["工作台/航线/课程.md", "工作台/航线/科研.md", "工作台/航线/保研.md", "工作台/航线/生活.md"])
                case .baoyan: RouteView(title: "保研", files: ["保研/保研进度看板.md", "保研/目标院校库.md", "保研/保研政策与时间线.md", "保研/背景提升清单.md", "工作台/航线/保研.md"])
                case .library: LibraryView()
                case .settings: SettingsView()
                }
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .fileImporter(isPresented: $showBinder, allowedContentTypes: [.folder]) { result in if case .success(let url) = result { workspace.bind(to: url) } }
        .onAppear { workspace.startMonitoring(); routePendingReminder() }
        .task { reminders.requestPermissionAndSchedule() }
        .onDisappear { workspace.stopMonitoring() }
        .onReceive(NotificationCenter.default.publisher(for: .studyRocketOpenChat)) { _ in requestSection(.chat) }
        .onReceive(NotificationCenter.default.publisher(for: .studyRocketReminderRoute)) { notification in
            let route = reminders.takePendingRoute() ?? (notification.object as? ReminderRoute)
            guard let route else { return }
            chat.prepare(prompt: route.prompt); requestSection(.chat)
        }
        .alert("无法绑定仓库", isPresented: Binding(get: { workspace.errorMessage != nil }, set: { if !$0 { workspace.errorMessage = nil } })) { Button("好", role: .cancel) {} } message: { Text(workspace.errorMessage ?? "") }
        .confirmationDialog("未保存的 Markdown 修改", isPresented: $showUnsavedSectionDialog, titleVisibility: .visible) {
            Button("保存并切换") { if document.save(), let pendingSection { selection = pendingSection; self.pendingSection = nil; workspace.refreshGitStatus() } }
            Button("放弃修改并切换", role: .destructive) { if let pendingSection { selection = pendingSection; self.pendingSection = nil } }
            Button("取消", role: .cancel) { pendingSection = nil }
        } message: { Text("当前文件有未保存的内容。") }
    }
    private func requestSection(_ next: AppSection?) { guard let next, next != selection else { return }; if document.isDirty { pendingSection = next; showUnsavedSectionDialog = true } else { selection = next } }
    private func routePendingReminder() {
        guard let route = reminders.takePendingRoute() else { return }
        chat.prepare(prompt: route.prompt); requestSection(.chat)
    }
}

struct PageHeader: View {
    let title: String; let subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 28, weight: .semibold, design: .rounded)); Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8) }
}

struct Panel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { content.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary)) }
}

struct DashboardView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var chat: StudyChatStore
    @State private var firstTask = "打开周计划，确认今天的第一项交付物"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "今天，先交付一件事", subtitle: Date.now.formatted(date: .complete, time: .omitted) + " · 你的学习工作台")
                HStack(alignment: .top, spacing: 16) {
                    Panel { VStack(alignment: .leading, spacing: 12) { Label("今日第一任务", systemImage: "flag.fill").foregroundStyle(.blue); Text(firstTask).font(.title3.weight(.medium)); Button("打开学业对话", systemImage: "bubble.left.and.bubble.right") { chat.prepare(prompt: ReminderRoute.daily.prompt); NotificationCenter.default.post(name: .studyRocketOpenChat, object: nil) }.buttonStyle(.borderedProminent) } }.frame(maxWidth: .infinity, alignment: .leading)
                    Panel { VStack(alignment: .leading, spacing: 10) { Label("本周状态", systemImage: "chart.bar.fill").foregroundStyle(.teal); Text("交付物完成度").font(.caption).foregroundStyle(.secondary); ProgressView(value: 0.25); Text("1 / 4 项 · 先保持可证据") .font(.headline); Text("周计划由 Markdown 直接驱动").font(.caption).foregroundStyle(.secondary) } }.frame(width: 260)
                }
                Text("本周航线").font(.headline)
                WeekRail()
                HStack(alignment: .top, spacing: 16) {
                    Panel { VStack(alignment: .leading, spacing: 10) { Label("最近节点", systemImage: "calendar.badge.clock").foregroundStyle(.blue); Text("校历与重要日期").font(.headline); Text("日期与推免规则仍以仓库官方文件为准").font(.caption).foregroundStyle(.secondary); Button("查看资料库", systemImage: "books.vertical") {}.buttonStyle(.link) } }.frame(maxWidth: .infinity, alignment: .leading)
                    Panel { VStack(alignment: .leading, spacing: 10) { Label("待核实", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text("推免资格、名额、排名口径").font(.headline); Text("拿到学院正式文件后再更新结论").font(.caption).foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("快速开始").font(.headline)
                HStack(spacing: 10) { ChatQuickAction(title: "今天复盘", icon: "checkmark.circle", prompt: ReminderRoute.daily.prompt); ChatQuickAction(title: "排下周", icon: "calendar.badge.plus", prompt: ReminderRoute.weekly.prompt); ChatQuickAction(title: "问学业问题", icon: "questionmark.bubble", prompt: "我有一个学业问题，请先读取我的档案和相关航线再回答。") }
            }.padding(24)
        }
    }
}

struct WeekRail: View {
    let days = ["一", "二", "三", "四", "五", "六", "日"]
    var body: some View { HStack(spacing: 0) { ForEach(Array(days.enumerated()), id: \.offset) { index, day in VStack(spacing: 8) { Circle().fill(index == 0 ? Color.teal : Color.blue.opacity(index < 3 ? 0.65 : 0.16)).frame(width: 18, height: 18).overlay { if index == 0 { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) } }; Text("周\(day)").font(.caption.weight(index == 0 ? .bold : .regular)); Text(index == 0 ? "已完成" : index == 6 ? "复盘" : "待安排").font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity); if index < 6 { Rectangle().fill(.quaternary).frame(height: 1).padding(.horizontal, 4) } } }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary)) }
}

struct ChatQuickAction: View {
    @EnvironmentObject private var chat: StudyChatStore
    let title: String; let icon: String; let prompt: String
    var body: some View { Button { chat.prepare(prompt: prompt); NotificationCenter.default.post(name: .studyRocketOpenChat, object: nil) } label: { Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.bordered) }
}

struct WeeklyPlanView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var chat: StudyChatStore
    @State private var plan = WeeklyPlan(); @State private var original = ""; @State private var loadedHash = ""; @State private var notice: String?
    private let file = "工作台/下周计划.md"
    var body: some View { VStack(alignment: .leading, spacing: 14) { HStack { PageHeader(title: "周计划", subtitle: "用时间块保护课程主线，也给临时任务留出缓冲"); Spacer(); Button("保存", systemImage: "square.and.arrow.down") { save() }.buttonStyle(.borderedProminent); Button("学业对话", systemImage: "bubble.left.and.bubble.right") { chat.prepare(prompt: ReminderRoute.weekly.prompt); NotificationCenter.default.post(name: .studyRocketOpenChat, object: nil) } }.padding(.horizontal, 24).padding(.top, 20); Panel { Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) { GridRow { Text("时段").font(.caption.bold()); ForEach(WeeklyPlan.days, id: \.self) { Text($0).font(.caption.bold()).frame(maxWidth: .infinity) } }; ForEach(0..<3, id: \.self) { row in GridRow { Text(WeeklyPlan.periods[row]).font(.caption).foregroundStyle(.secondary); ForEach(0..<7, id: \.self) { col in TextField("", text: Binding(get: { plan.cells[row][col] }, set: { plan.cells[row][col] = $0 })).textFieldStyle(.roundedBorder).frame(minWidth: 85) } } } } }.padding(.horizontal, 24); HStack(alignment: .top, spacing: 16) { Panel { VStack(alignment: .leading) { Text("交付物清单").font(.headline); ForEach(plan.deliveries.indices, id: \.self) { index in HStack { Image(systemName: "square").foregroundStyle(.secondary); TextField("交付物", text: Binding(get: { plan.deliveries[index] }, set: { plan.deliveries[index] = $0 })) } }; Button("添加交付物", systemImage: "plus") { plan.deliveries.append("") }.buttonStyle(.link) } }.frame(maxWidth: .infinity, alignment: .leading); Panel { VStack(alignment: .leading) { Text("缓冲与降级").font(.headline); TextEditor(text: $plan.buffer).frame(height: 90); Text("保持至少一天弹性，撞车时先保课程与唯一关键交付物。").font(.caption).foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, alignment: .leading) }.padding(.horizontal, 24); Spacer() }.onAppear(perform: load).alert("保存结果", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("好", role: .cancel) {} } message: { Text(notice ?? "") } }
    private func load() { let repo = MarkdownRepository(root: workspace.rootURL); original = (try? repo.read(file)) ?? ""; loadedHash = repo.hash(original); plan = MarkdownParser.weekly(original) }
    private func save() { let repo = MarkdownRepository(root: workspace.rootURL); do { try repo.save(MarkdownParser.replaceWeekly(original, with: plan), relative: file, loadedHash: loadedHash); notice = "已保存到工作台/下周计划.md"; load(); workspace.refreshGitStatus() } catch { notice = error.localizedDescription } }
}

struct DailyCheckinView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var chat: StudyChatStore
    @State private var entry = DailyEntry(id: "", date: "", deliverables: "", studyTime: "", sleep: "", exercise: "", firstTask: ""); @State private var original = ""; @State private var hash = ""; @State private var notice: String?
    private let formatter = DateFormatter(); private var monthFile: String { "工作台/每日记录/" + String(entry.date.prefix(7)) + ".md" }
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 16) { PageHeader(title: "每日复盘", subtitle: "三分钟行为账：只记录已经发生的事实"); Panel { Form { DatePicker("日期", selection: Binding(get: { dateValue }, set: { entry.date = $0.formatted(.iso8601.year().month().day()) }), displayedComponents: .date); TextField("今日完成的具体交付物", text: $entry.deliverables); TextField("净学习时长", text: $entry.studyTime); TextField("入睡/起床", text: $entry.sleep); TextField("运动", text: $entry.exercise); TextField("明日第一任务", text: $entry.firstTask) }.formStyle(.grouped) }; HStack { Button("保存行为账", systemImage: "checkmark.circle") { save() }.buttonStyle(.borderedProminent); Button("学业对话", systemImage: "bubble.left.and.bubble.right") { chat.prepare(prompt: ReminderRoute.daily.prompt); NotificationCenter.default.post(name: .studyRocketOpenChat, object: nil) } }; Spacer() }.padding(24) }.onAppear { entry.date = Date.now.formatted(.iso8601.year().month().day()); load() }.alert("保存结果", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("好", role: .cancel) {} } message: { Text(notice ?? "") } }
    private var dateValue: Date { ISO8601DateFormatter().date(from: entry.date) ?? .now }
    private func load() { let repo = MarkdownRepository(root: workspace.rootURL); original = (try? repo.read(monthFile)) ?? ""; hash = repo.hash(original); entry = MarkdownParser.daily(original, date: entry.date) }
    private func save() { let repo = MarkdownRepository(root: workspace.rootURL); do { try repo.save(MarkdownParser.replaceDaily(original, entry: entry), relative: monthFile, loadedHash: hash); notice = "已保存今天的行为账"; load(); workspace.refreshGitStatus() } catch { notice = error.localizedDescription } }
}

struct RouteView: View {
    let title: String; let files: [String]
    var body: some View { MarkdownBrowserView(title: title, suppliedFiles: files, showsSearch: false) }
}

struct LibraryView: View {
    var body: some View { MarkdownBrowserView(title: "资料库", suppliedFiles: nil, showsSearch: true) }
}

struct MarkdownBrowserView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var document: MarkdownDocumentModel
    let title: String; let suppliedFiles: [String]?; let showsSearch: Bool
    @State private var query = ""
    @State private var selected: String?
    @State private var pendingSelection: String?
    @State private var showUnsavedDialog = false

    private var files: [String] { (suppliedFiles ?? MarkdownRepository(root: workspace.rootURL).markdownFiles()).filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if showsSearch { TextField("过滤 Markdown", text: $query).textFieldStyle(.roundedBorder).padding(10).onChange(of: query) { _, _ in ensureSelection() } }
                List(selection: Binding(get: { selected }, set: { requestSelection($0) })) {
                    ForEach(files, id: \.self) { file in Label(file.split(separator: "/").last.map(String.init) ?? file, systemImage: "doc.text").tag(Optional(file)) }
                }
            }.navigationTitle(title)
        } detail: {
            if document.relative != nil { MarkdownDocumentView(document: document) }
            else { ContentUnavailableView("选择一份 Markdown", systemImage: "doc.text", description: Text("详细内容保留在仓库文件中")) }
        }
        .onAppear { configureAndLoad() }
        .onChange(of: workspace.rootURL) { _, _ in configureAndLoad() }
        .confirmationDialog("未保存的 Markdown 修改", isPresented: $showUnsavedDialog, titleVisibility: .visible) {
            Button("保存并切换") { if document.save(), let pendingSelection { selected = pendingSelection; document.load(pendingSelection); workspace.refreshGitStatus(); self.pendingSelection = nil } }
            Button("放弃修改并切换", role: .destructive) { if let pendingSelection { selected = pendingSelection; document.discardAndLoad(pendingSelection); self.pendingSelection = nil } }
            Button("取消", role: .cancel) { pendingSelection = nil }
        } message: { Text("当前文件有未保存的内容。") }
    }

    private func configureAndLoad() { document.updateRoot(workspace.rootURL); if let current = document.relative, files.contains(current) { selected = current } else { selected = files.first; if let selected { document.load(selected) } } }
    private func ensureSelection() { guard let selected, files.contains(selected) else { self.selected = files.first; if let first = files.first { document.load(first) }; return } }
    private func requestSelection(_ next: String?) { guard let next, next != selected else { return }; if document.isDirty { pendingSelection = next; showUnsavedDialog = true } else { selected = next; document.load(next) } }
}

struct MarkdownDocumentView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @ObservedObject var document: MarkdownDocumentModel
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.relative ?? "Markdown").font(.headline)
                    if document.isDirty { Label("未保存", systemImage: "circle.fill").font(.caption).foregroundStyle(.orange) }
                }
                Spacer()
                Picker("显示模式", selection: $document.mode) { ForEach(MarkdownMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).frame(width: 132)
                Button("保存", systemImage: "square.and.arrow.down") { save() }.keyboardShortcut("s", modifiers: .command).disabled(!document.isDirty).buttonStyle(.borderedProminent)
            }.padding(.horizontal, 20).padding(.vertical, 14).background(.bar)
            Divider()
            Group {
                if document.mode == .preview { MarkdownPreview(text: document.text, baseURL: workspace.rootURL) }
                else { TextEditor(text: $document.text).font(.system(.body, design: .monospaced)).padding(16).overlay(alignment: .bottomLeading) { Text("Markdown 源码 · 预览会显示当前草稿").font(.caption).foregroundStyle(.secondary).padding(20) } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Markdown", isPresented: Binding(get: { notice != nil || document.errorMessage != nil }, set: { if !$0 { notice = nil; document.errorMessage = nil } })) { Button("好", role: .cancel) {} } message: { Text(notice ?? document.errorMessage ?? "") }
    }
    private func save() { if document.save() { workspace.refreshGitStatus(); notice = "已保存" } }
}

struct MarkdownPreview: View {
    let text: String; let baseURL: URL
    var body: some View {
        ScrollView {
            Markdown(text, baseURL: baseURL)
                .markdownTheme(.gitHub)
                .markdownTextStyle { FontSize(16); ForegroundColor(.primary) }
                .markdownBlockStyle(\.blockquote) { configuration in configuration.label.padding(.leading, 14).padding(.vertical, 4).overlay(alignment: .leading) { Rectangle().fill(Color.teal).frame(width: 3) } }
                .textSelection(.enabled)
                .frame(maxWidth: 900, alignment: .leading)
                .padding(28)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}


struct SettingsView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var reminders: ReminderScheduler
    var body: some View { Form { Section("当前仓库") { Text(workspace.rootURL.path).textSelection(.enabled); Text("需要迁移仓库时，请使用侧边栏底部的“重新绑定仓库”。").font(.caption).foregroundStyle(.secondary) }; Section("学业对话") { LabeledContent("Codex 连接", value: "复用本机登录，不保存令牌"); Text("应用会单独续接 StudyRocket 学业助理任务，开发任务不会被读取。").font(.caption).foregroundStyle(.secondary) }; Section("原生提醒") { LabeledContent("权限", value: reminders.authorization); ForEach(ReminderRoute.allCases) { route in Toggle(route.title, isOn: Binding(get: { reminders.enabled[route] ?? true }, set: { reminders.toggle(route, isOn: $0) })); HStack { Text("下一次").font(.caption).foregroundStyle(.secondary); Spacer(); Text(nextDateText(for: route)).font(.caption).foregroundStyle(.secondary); Button("测试") { reminders.sendTest(route) }.buttonStyle(.link) } }; Button("请求通知权限并登记") { reminders.requestPermissionAndSchedule() }.buttonStyle(.borderedProminent) }.onAppear { reminders.requestPermissionAndSchedule() }; Section("运行方式") { LabeledContent("后台服务", value: "无"); LabeledContent("数据存储", value: "Markdown 文件"); LabeledContent("旧自动任务", value: "验收前保留") }; Section("隐私") { Text("应用不保存模型凭证，不创建网络监听端口；PDF 继续使用私有云盘单独备份。学业对话继承当前 Codex 端点配置。").font(.callout).foregroundStyle(.secondary) } }.formStyle(.grouped).padding(24) }
    private func nextDateText(for route: ReminderRoute) -> String { guard let date = reminders.nextDates[route] ?? nil else { return "待登记" }; return date.formatted(date: .abbreviated, time: .shortened) }
}

struct StudyChatView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var chat: StudyChatStore
    @State private var showHelp = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) { Text("StudyRocket 学业助理").font(.headline); Text(chat.status).font(.caption).foregroundStyle(chat.status == "已连接" ? .green : .secondary) }
                Spacer()
                Button("在 Codex 中打开", systemImage: "arrow.up.right.square") { chat.openInCodex() }.disabled(chat.threadID == nil)
                Button("帮助", systemImage: "questionmark.circle") { showHelp = true }
            }.padding(16).background(.bar)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if chat.messages.isEmpty { ContentUnavailableView("开始你的学业对话", systemImage: "bubble.left.and.bubble.right", description: Text("可以问课程、保研、科研，也可以让助理生成计划修改草案。")) }
                        ForEach(chat.messages) { message in ChatBubble(message: message).id(message.id) }
                        if !chat.processMessages.isEmpty {
                            DisclosureGroup("查看过程（\(chat.processMessages.count)）") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(chat.processMessages) { message in ChatBubble(message: message).id(message.id) }
                                }.padding(.top, 4)
                            }.font(.caption).foregroundStyle(.secondary).id("process")
                        }
                        if !chat.streamingReply.isEmpty { ChatBubble(message: ChatMessage(id: "streaming", role: .assistant, text: chat.streamingReply, date: .now)).id("streaming") }
                    }.padding(20)
                }.onChange(of: chat.messages.count) { _, _ in if let last = chat.messages.last { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } } }
                 .onChange(of: chat.streamingReply) { _, _ in proxy.scrollTo("streaming", anchor: .bottom) }
            }
            if !chat.proposals.isEmpty { ProposalPanel() }
            Divider()
            if let error = chat.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).foregroundStyle(.primary).textSelection(.enabled)
                    Spacer(minLength: 8)
                    if chat.lastSubmitted != nil { Button("重试本条") { chat.retryLast() }.buttonStyle(.bordered) }
                    Button("重新连接") { Task { await chat.reconnect() } }.buttonStyle(.bordered)
                    if chat.canCreateNewTask { Button("创建新学业任务") { Task { await chat.createNewTask() } }.buttonStyle(.bordered) }
                }.padding(.horizontal, 14).padding(.vertical, 8).background(Color.orange.opacity(0.10))
            }
            HStack(spacing: 8) {
                Menu("快捷报告", systemImage: "wand.and.stars") { ForEach(ReminderRoute.allCases) { route in Button(route.title) { chat.prepare(prompt: route.prompt) } }; Button("学业答疑") { chat.prepare(prompt: "我有一个学业问题，请先读取我的档案和相关航线再回答。") } }
                TextField("输入问题或今天完成的事实…", text: $chat.draft, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...5).onSubmit { chat.send() }
                if chat.isBusy { Button("停止", systemImage: "stop.circle") { chat.stop() }.buttonStyle(.bordered) } else { Button("发送", systemImage: "paperplane.fill") { chat.send() }.buttonStyle(.borderedProminent).disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(14)
        }.task { await chat.connect(to: workspace.rootURL) }.onChange(of: workspace.rootURL) { _, root in Task { await chat.connect(to: root) } }.onDisappear { chat.disconnect() }.sheet(isPresented: $showHelp) { ChatHelpView() }
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    var body: some View {
        let isUser = message.role == .user
        return HStack(alignment: .top, spacing: 10) {
            if !isUser { Image(systemName: message.phase == .commentary ? "ellipsis.bubble" : "graduationcap.circle.fill").foregroundStyle(message.phase == .commentary ? Color.secondary : Color.teal).accessibilityLabel("学业助理") }
            Group {
                if message.role == .assistant { Markdown(message.text).markdownTheme(.gitHub).textSelection(.enabled) }
                else { Text(message.text).textSelection(.enabled) }
            }
            .padding(12)
            .background(isUser ? Color.blue.opacity(0.18) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomLeading) {
                if let state = message.turnState, state != .completed, message.role == .user {
                    Text(state == .interrupted ? "已中断" : state == .failed ? "未完成" : "进行中")
                        .font(.caption2).foregroundStyle(.secondary).padding(.top, 3).offset(y: 18)
                }
            }
            .frame(maxWidth: 780, alignment: isUser ? .trailing : .leading)
            if isUser {
                Image(systemName: "person.circle.fill").foregroundStyle(.blue).accessibilityLabel("我")
                Spacer(minLength: 20)
            } else { Spacer(minLength: 20) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

struct ProposalPanel: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var chat: StudyChatStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("待确认的 Markdown 修改", systemImage: "doc.badge.gearshape").font(.headline)
                Spacer()
                Button("应用已选修改") { chat.applySelectedChanges(workspace: workspace) }.buttonStyle(.borderedProminent)
            }
            ForEach($chat.proposals) { $proposal in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Toggle("", isOn: $proposal.isSelected).labelsHidden()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(proposal.relativePath).font(.subheadline.weight(.semibold))
                            Text(proposal.reason).font(.caption).foregroundStyle(.secondary)
                            Text("应用前会再次检查文件是否被外部修改").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    DisclosureGroup("查看差异") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("原文").font(.caption.bold()).foregroundStyle(.secondary)
                            Text(proposal.originalContent.isEmpty ? "（空文件）" : proposal.originalContent)
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                            Text("候选正文").font(.caption.bold()).foregroundStyle(.secondary)
                            Text(proposal.proposedContent.isEmpty ? "（空文件）" : proposal.proposedContent)
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                        }.padding(.top, 4)
                    }.font(.caption)
                }.padding(.vertical, 4)
            }
        }.padding(12).background(Color.orange.opacity(0.08))
    }
}

struct ChatHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { VStack(alignment: .leading, spacing: 12) { Text("学业对话帮助").font(.title2.weight(.semibold)); Text("这里连接的是独立的 StudyRocket 学业助理任务，当前应用开发对话不会被带入。你可以直接输入事实或问题，也可以使用快捷报告。涉及文件修改时，助理只生成草案；点击应用按钮后才写入 Markdown。"); Text("学校规则、推免名额、截止日期等未知信息会标记为【待核实】，不会用猜测填充。").foregroundStyle(.secondary); Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(24).frame(width: 440, height: 240) }
}

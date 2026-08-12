import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var selection: AppSection? = .home
    @State private var showBinder = false
    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
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
                case .week: WeeklyPlanView()
                case .daily: DailyCheckinView()
                case .routes: RouteView(title: "四条航线", files: ["工作台/航线/课程.md", "工作台/航线/科研.md", "工作台/航线/保研.md", "工作台/航线/生活.md"])
                case .baoyan: RouteView(title: "保研", files: ["保研/保研看板.md", "保研/目标院校库.md", "工作台/航线/保研.md"])
                case .library: LibraryView()
                case .settings: SettingsView()
                }
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .fileImporter(isPresented: $showBinder, allowedContentTypes: [.folder]) { result in if case .success(let url) = result { workspace.bind(to: url) } }
        .onAppear { workspace.startMonitoring() }
        .onDisappear { workspace.stopMonitoring() }
        .alert("无法绑定仓库", isPresented: Binding(get: { workspace.errorMessage != nil }, set: { if !$0 { workspace.errorMessage = nil } })) { Button("好", role: .cancel) {} } message: { Text(workspace.errorMessage ?? "") }
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
    @State private var firstTask = "打开周计划，确认今天的第一项交付物"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "今天，先交付一件事", subtitle: Date.now.formatted(date: .complete, time: .omitted) + " · 你的学习工作台")
                HStack(alignment: .top, spacing: 16) {
                    Panel { VStack(alignment: .leading, spacing: 12) { Label("今日第一任务", systemImage: "flag.fill").foregroundStyle(.blue); Text(firstTask).font(.title3.weight(.medium)); Button("打开 Codex", systemImage: "arrow.up.right.square") { CodexLink.open(workspace.rootURL, prompt: "今天复盘") }.buttonStyle(.borderedProminent) } }.frame(maxWidth: .infinity, alignment: .leading)
                    Panel { VStack(alignment: .leading, spacing: 10) { Label("本周状态", systemImage: "chart.bar.fill").foregroundStyle(.teal); Text("交付物完成度").font(.caption).foregroundStyle(.secondary); ProgressView(value: 0.25); Text("1 / 4 项 · 先保持可证据") .font(.headline); Text("周计划由 Markdown 直接驱动").font(.caption).foregroundStyle(.secondary) } }.frame(width: 260)
                }
                Text("本周航线").font(.headline)
                WeekRail()
                HStack(alignment: .top, spacing: 16) {
                    Panel { VStack(alignment: .leading, spacing: 10) { Label("最近节点", systemImage: "calendar.badge.clock").foregroundStyle(.blue); Text("校历与重要日期").font(.headline); Text("日期与推免规则仍以仓库官方文件为准").font(.caption).foregroundStyle(.secondary); Button("查看资料库", systemImage: "books.vertical") {}.buttonStyle(.link) } }.frame(maxWidth: .infinity, alignment: .leading)
                    Panel { VStack(alignment: .leading, spacing: 10) { Label("待核实", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text("推免资格、名额、排名口径").font(.headline); Text("拿到学院正式文件后再更新结论").font(.caption).foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("快速开始").font(.headline)
                HStack(spacing: 10) { QuickAction(title: "今天复盘", icon: "checkmark.circle", prompt: "今天复盘", root: workspace.rootURL); QuickAction(title: "排下周", icon: "calendar.badge.plus", prompt: "排下周", root: workspace.rootURL); QuickAction(title: "问学业问题", icon: "questionmark.bubble", prompt: "我有一个学业问题", root: workspace.rootURL) }
            }.padding(24)
        }
    }
}

struct WeekRail: View {
    let days = ["一", "二", "三", "四", "五", "六", "日"]
    var body: some View { HStack(spacing: 0) { ForEach(Array(days.enumerated()), id: \.offset) { index, day in VStack(spacing: 8) { Circle().fill(index == 0 ? Color.teal : Color.blue.opacity(index < 3 ? 0.65 : 0.16)).frame(width: 18, height: 18).overlay { if index == 0 { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) } }; Text("周\(day)").font(.caption.weight(index == 0 ? .bold : .regular)); Text(index == 0 ? "已完成" : index == 6 ? "复盘" : "待安排").font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity); if index < 6 { Rectangle().fill(.quaternary).frame(height: 1).padding(.horizontal, 4) } } }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary)) }
}

struct QuickAction: View {
    let title: String; let icon: String; let prompt: String; let root: URL
    var body: some View { Button { CodexLink.open(root, prompt: prompt) } label: { Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.bordered) }
}

struct WeeklyPlanView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var plan = WeeklyPlan(); @State private var original = ""; @State private var loadedHash = ""; @State private var notice: String?
    private let file = "工作台/下周计划.md"
    var body: some View { VStack(alignment: .leading, spacing: 14) { HStack { PageHeader(title: "周计划", subtitle: "用时间块保护课程主线，也给临时任务留出缓冲"); Spacer(); Button("保存", systemImage: "square.and.arrow.down") { save() }.buttonStyle(.borderedProminent); Button("打开 Codex", systemImage: "arrow.up.right.square") { CodexLink.open(workspace.rootURL, prompt: "排下周") } }.padding(.horizontal, 24).padding(.top, 20); Panel { Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) { GridRow { Text("时段").font(.caption.bold()); ForEach(WeeklyPlan.days, id: \.self) { Text($0).font(.caption.bold()).frame(maxWidth: .infinity) } }; ForEach(0..<3, id: \.self) { row in GridRow { Text(WeeklyPlan.periods[row]).font(.caption).foregroundStyle(.secondary); ForEach(0..<7, id: \.self) { col in TextField("", text: Binding(get: { plan.cells[row][col] }, set: { plan.cells[row][col] = $0 })).textFieldStyle(.roundedBorder).frame(minWidth: 85) } } } } }.padding(.horizontal, 24); HStack(alignment: .top, spacing: 16) { Panel { VStack(alignment: .leading) { Text("交付物清单").font(.headline); ForEach(plan.deliveries.indices, id: \.self) { index in HStack { Image(systemName: "square").foregroundStyle(.secondary); TextField("交付物", text: Binding(get: { plan.deliveries[index] }, set: { plan.deliveries[index] = $0 })) } }; Button("添加交付物", systemImage: "plus") { plan.deliveries.append("") }.buttonStyle(.link) } }.frame(maxWidth: .infinity, alignment: .leading); Panel { VStack(alignment: .leading) { Text("缓冲与降级").font(.headline); TextEditor(text: $plan.buffer).frame(height: 90); Text("保持至少一天弹性，撞车时先保课程与唯一关键交付物。").font(.caption).foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, alignment: .leading) }.padding(.horizontal, 24); Spacer() }.onAppear(perform: load).alert("保存结果", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("好", role: .cancel) {} } message: { Text(notice ?? "") } }
    private func load() { let repo = MarkdownRepository(root: workspace.rootURL); original = (try? repo.read(file)) ?? ""; loadedHash = repo.hash(original); plan = MarkdownParser.weekly(original) }
    private func save() { let repo = MarkdownRepository(root: workspace.rootURL); do { try repo.save(MarkdownParser.replaceWeekly(original, with: plan), relative: file, loadedHash: loadedHash); notice = "已保存到工作台/下周计划.md"; load(); workspace.refreshGitStatus() } catch { notice = error.localizedDescription } }
}

struct DailyCheckinView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var entry = DailyEntry(id: "", date: "", deliverables: "", studyTime: "", sleep: "", exercise: "", firstTask: ""); @State private var original = ""; @State private var hash = ""; @State private var notice: String?
    private let formatter = DateFormatter(); private var monthFile: String { "工作台/每日记录/" + String(entry.date.prefix(7)) + ".md" }
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 16) { PageHeader(title: "每日复盘", subtitle: "三分钟行为账：只记录已经发生的事实"); Panel { Form { DatePicker("日期", selection: Binding(get: { dateValue }, set: { entry.date = $0.formatted(.iso8601.year().month().day()) }), displayedComponents: .date); TextField("今日完成的具体交付物", text: $entry.deliverables); TextField("净学习时长", text: $entry.studyTime); TextField("入睡/起床", text: $entry.sleep); TextField("运动", text: $entry.exercise); TextField("明日第一任务", text: $entry.firstTask) }.formStyle(.grouped) }; HStack { Button("保存行为账", systemImage: "checkmark.circle") { save() }.buttonStyle(.borderedProminent); Button("打开 Codex", systemImage: "arrow.up.right.square") { CodexLink.open(workspace.rootURL, prompt: "今天复盘") } }; Spacer() }.padding(24) }.onAppear { entry.date = Date.now.formatted(.iso8601.year().month().day()); load() }.alert("保存结果", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("好", role: .cancel) {} } message: { Text(notice ?? "") } }
    private var dateValue: Date { ISO8601DateFormatter().date(from: entry.date) ?? .now }
    private func load() { let repo = MarkdownRepository(root: workspace.rootURL); original = (try? repo.read(monthFile)) ?? ""; hash = repo.hash(original); entry = MarkdownParser.daily(original, date: entry.date) }
    private func save() { let repo = MarkdownRepository(root: workspace.rootURL); do { try repo.save(MarkdownParser.replaceDaily(original, entry: entry), relative: monthFile, loadedHash: hash); notice = "已保存今天的行为账"; load(); workspace.refreshGitStatus() } catch { notice = error.localizedDescription } }
}

struct RouteView: View {
    @EnvironmentObject private var workspace: WorkspaceStore; let title: String; let files: [String]; @State private var selected: String?
    var body: some View { NavigationSplitView { List(files, id: \.self, selection: $selected) { Text($0.split(separator: "/").last.map(String.init) ?? $0).tag(Optional($0)) }.navigationTitle(title) } detail: { if let selected { MarkdownEditor(relative: selected) } else { ContentUnavailableView("选择一份 Markdown", systemImage: "doc.text", description: Text("详细内容保留在仓库文件中")) } } }
}

struct LibraryView: View {
    @EnvironmentObject private var workspace: WorkspaceStore; @State private var query = ""; @State private var selected: String?
    var files: [String] { MarkdownRepository(root: workspace.rootURL).markdownFiles().filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }
    var body: some View { NavigationSplitView { VStack { TextField("过滤 Markdown", text: $query).textFieldStyle(.roundedBorder).padding(10); List(files, id: \.self, selection: $selected) { Label($0, systemImage: "doc.text") } }.navigationTitle("资料库") } detail: { if let selected { MarkdownEditor(relative: selected) } else { ContentUnavailableView("仓库资料", systemImage: "books.vertical", description: Text("PDF 仍在私有云盘，Markdown 可在这里查看和编辑")) } } }
}

struct MarkdownEditor: View {
    @EnvironmentObject private var workspace: WorkspaceStore; let relative: String; @State private var text = ""; @State private var original = ""; @State private var hash = ""; @State private var notice: String?
    var body: some View { VStack(alignment: .leading) { HStack { Text(relative).font(.headline); Spacer(); Button("保存", systemImage: "square.and.arrow.down") { save() }.buttonStyle(.borderedProminent) }; TextEditor(text: $text).font(.system(.body, design: .monospaced)).padding(8).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary)); Text("Markdown 源码 · 明确保存后才写入仓库").font(.caption).foregroundStyle(.secondary) }.padding(20).onAppear { load() }.alert("保存结果", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("好", role: .cancel) {} } message: { Text(notice ?? "") } }
    private func load() { let repo = MarkdownRepository(root: workspace.rootURL); original = (try? repo.read(relative)) ?? ""; text = original; hash = repo.hash(original) }
    private func save() { do { try MarkdownRepository(root: workspace.rootURL).save(text, relative: relative, loadedHash: hash); notice = "已保存"; load(); workspace.refreshGitStatus() } catch { notice = error.localizedDescription } }
}

struct SettingsView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    var body: some View { Form { Section("当前仓库") { Text(workspace.rootURL.path).textSelection(.enabled); Text("需要迁移仓库时，请使用侧边栏底部的“重新绑定仓库”。").font(.caption).foregroundStyle(.secondary) }; Section("运行方式") { LabeledContent("后台服务", value: "无"); LabeledContent("数据存储", value: "Markdown 文件"); LabeledContent("自动任务", value: "由 Codex Scheduled Tasks 管理") }; Section("隐私") { Text("应用不保存模型凭证，不创建网络监听端口；PDF 继续使用私有云盘单独备份。").font(.callout).foregroundStyle(.secondary) } }.formStyle(.grouped).padding(24) }
}

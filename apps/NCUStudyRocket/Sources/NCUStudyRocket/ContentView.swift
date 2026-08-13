import SwiftUI
import MarkdownUI
import AppKit

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
                Label(section.title, systemImage: section.icon)
                    .frame(minHeight: 34)
                    .tag(section)
            }
            .navigationTitle("StudyRocket")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    Label(workspace.gitStatus, systemImage: workspace.gitStatus == "已同步" ? "checkmark.seal" : "circle.dotted")
                        .font(.caption).foregroundStyle(workspace.gitStatus == "已同步" ? .teal : .orange)
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

struct DashboardView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var chat: StudyChatStore
    @StateObject private var dashboard = DashboardModel()
    var body: some View {
        PageScaffold {
            VStack(alignment: .leading, spacing: StudyRocketTheme.sectionGap) {
                PageTitleBar(title: "今天的学习计划", subtitle: Date.now.formatted(date: .complete, time: .omitted)) {
                    if !dashboard.filteredDeliveries.isEmpty {
                        Text("\(dashboard.completedDeliveries) / \(dashboard.filteredDeliveries.count) 已完成")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.teal)
                    }
                }
                ResponsiveColumns {
                    TodayPlanList(tasks: dashboard.todayCells, firstTask: dashboard.firstOpenTask, unassigned: dashboard.todayUnassigned)
                } second: {
                    DeliveryChecklist(
                        deliveries: dashboard.filteredDeliveries,
                        emptyMessage: dashboard.plan.deliveries.isEmpty ? "周计划中还没有交付物。" : "除今日安排外，本周暂无其他交付物。"
                    ) { id in
                        dashboard.toggleDelivery(id, workspace: workspace)
                    }
                }
                if let error = dashboard.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("本周航线").font(.system(size: 15, weight: .semibold))
                    WeekRail(todayIndex: dashboard.weekdayIndex)
                }
                ResponsiveColumns {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("最近节点", systemImage: "calendar.badge.clock").font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                        Text("校历与重要日期").font(.system(size: 15, weight: .medium))
                        Text("日期与推免规则仍以仓库官方文件为准").font(.caption).foregroundStyle(.secondary)
                        Button("查看资料库", systemImage: "books.vertical") {}.buttonStyle(.link)
                    }
                } second: {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("待核实", systemImage: "exclamationmark.triangle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                        Text("推免资格、名额、排名口径").font(.system(size: 15, weight: .medium))
                        Text("拿到学院正式文件后再更新结论").font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("快速开始").font(.system(size: 15, weight: .semibold))
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { ChatQuickAction(title: "今天复盘", icon: "checkmark.circle", prompt: ReminderRoute.daily.prompt); ChatQuickAction(title: "排下周", icon: "calendar.badge.plus", prompt: ReminderRoute.weekly.prompt); ChatQuickAction(title: "问学业问题", icon: "questionmark.bubble", prompt: "我有一个学业问题，请先读取我的档案和相关航线再回答。") }
                        VStack(spacing: 8) { ChatQuickAction(title: "今天复盘", icon: "checkmark.circle", prompt: ReminderRoute.daily.prompt); ChatQuickAction(title: "排下周", icon: "calendar.badge.plus", prompt: ReminderRoute.weekly.prompt); ChatQuickAction(title: "问学业问题", icon: "questionmark.bubble", prompt: "我有一个学业问题，请先读取我的档案和相关航线再回答。") }
                    }
                }
            }
        }
        .onAppear { dashboard.load(from: workspace.rootURL) }
        .onChange(of: workspace.rootURL) { _, root in dashboard.load(from: root) }
    }
}

private struct TodayPlanList: View {
    @EnvironmentObject private var chat: StudyChatStore
    let tasks: [(period: String, task: String)]
    let firstTask: String?
    let unassigned: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("今日安排", systemImage: "checklist")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if firstTask != nil { Image(systemName: "flag.fill").foregroundStyle(.tint).accessibilityLabel("有待完成任务") }
            }
            .padding(.bottom, 8)
            ForEach(Array(tasks.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(item.period).font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
                    Circle().fill(item.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.28) : Color.accentColor)
                        .frame(width: 7, height: 7)
                    Text(item.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未安排" : item.task)
                        .font(.system(size: StudyRocketTheme.bodySize))
                        .foregroundStyle(item.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                if index < tasks.count - 1 { Divider().padding(.leading, 57) }
            }
            if !unassigned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("今天有待分时安排", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .help(unassigned)
                    .padding(.top, 8)
            }
            if firstTask == nil {
                Button("去周计划安排今天", systemImage: "calendar.badge.plus") {
                    chat.prepare(prompt: "请根据我的档案和本周约束，为今天安排可执行的时间块。先问缺失事实，不要编造。")
                    NotificationCenter.default.post(name: .studyRocketOpenChat, object: nil)
                }
                .buttonStyle(.bordered)
                .padding(.top, 12)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: StudyRocketTheme.cornerRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: StudyRocketTheme.cornerRadius, style: .continuous).strokeBorder(.quaternary) }
    }
}

private struct DeliveryChecklist: View {
    let deliveries: [WeeklyDelivery]
    let emptyMessage: String
    let toggle: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("本周交付物", systemImage: "checkmark.circle")
                .font(.system(size: 15, weight: .semibold)).padding(.bottom, 8)
            if deliveries.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: StudyRocketTheme.bodySize)).foregroundStyle(.secondary).frame(minHeight: 44, alignment: .leading)
            } else {
                ForEach(Array(deliveries.enumerated()), id: \.element.id) { index, delivery in
                    Button { toggle(delivery.id) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: delivery.isCompleted ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(delivery.isCompleted ? Color.teal : Color.secondary)
                            Text(delivery.text).strikethrough(delivery.isCompleted, color: .secondary).foregroundStyle(delivery.isCompleted ? .secondary : .primary).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(delivery.isCompleted ? "取消完成" : "标记完成")：\(delivery.text)")
                    if index < deliveries.count - 1 { Divider().padding(.leading, 28) }
                }
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: StudyRocketTheme.cornerRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: StudyRocketTheme.cornerRadius, style: .continuous).strokeBorder(.quaternary) }
    }
}

struct WeekRail: View {
    let days = ["一", "二", "三", "四", "五", "六", "日"]
    let todayIndex: Int
    var body: some View {
        StudySurface {
            HStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    VStack(spacing: 6) {
                        Circle()
                            .fill(index == todayIndex ? Color.accentColor : Color.secondary.opacity(0.18))
                            .frame(width: 15, height: 15)
                            .overlay {
                                if index == todayIndex {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                        Text("周\(day)").font(.caption.weight(index == todayIndex ? .bold : .regular))
                        Text(index == todayIndex ? "今天" : index == 6 ? "复盘" : "计划")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    if index < 6 {
                        Rectangle().fill(.quaternary).frame(height: 1).padding(.horizontal, 4)
                    }
                }
            }
        }
    }
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
    @State private var editingCell: WeeklyEditTarget?
    @State private var migrationNoticeVisible = true
    private let file = "工作台/下周计划.md"
    var body: some View { PageScaffold { VStack(alignment: .leading, spacing: StudyRocketTheme.sectionGap) {
        PageTitleBar(title: "周计划", subtitle: "每天三个时间块，点按格子编辑完整任务") {
            HStack(spacing: 8) {
                Button("保存", systemImage: "square.and.arrow.down") { save() }.buttonStyle(.borderedProminent)
                StudyIconButton(systemImage: "bubble.left.and.bubble.right", label: "在学业对话中排下周") { chat.prepare(prompt: ReminderRoute.weekly.prompt); NotificationCenter.default.post(name: .studyRocketOpenChat, object: nil) }
            }
        }
        if migrationNoticeVisible, let migrationNotice = plan.migrationNotice {
            MigrationNotice(text: migrationNotice) { migrationNoticeVisible = false }
        }
        WeeklyGridPlanEditor(plan: $plan) { target in editingCell = target }
        ResponsiveColumns {
            StudySurface { VStack(alignment: .leading, spacing: 10) {
                Text("交付物清单").font(.system(size: 15, weight: .semibold))
                ForEach(plan.deliveries.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("", isOn: Binding(get: { plan.deliveries[index].isCompleted }, set: { plan.deliveries[index].isCompleted = $0 })).labelsHidden().padding(.top, 4)
                        DeliveryTextEditor(text: Binding(get: { plan.deliveries[index].text }, set: { plan.deliveries[index].text = $0 }))
                    }
                }
                Button("添加交付物", systemImage: "plus") { plan.deliveries.append(WeeklyDelivery(text: "", isCompleted: false)) }.buttonStyle(.link)
            } }
        } second: {
            StudySurface { VStack(alignment: .leading, spacing: 10) { Text("缓冲与降级").font(.system(size: 15, weight: .semibold)); TextEditor(text: $plan.buffer).font(.system(size: 14)).frame(minHeight: 110); Text("保持至少一天弹性，撞车时先保课程与唯一关键交付物。").font(.caption).foregroundStyle(.secondary) } }
        }
    } }.onAppear(perform: load).popover(item: $editingCell) { target in
        WeeklyCellEditorPopover(target: target) { value in commitCell(target, value: value); editingCell = nil }
    }.alert("保存结果", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("好", role: .cancel) {} } message: { Text(notice ?? "") } }
    private func load() { let repo = MarkdownRepository(root: workspace.rootURL); original = (try? repo.read(file)) ?? ""; loadedHash = repo.hash(original); plan = MarkdownParser.weekly(original); migrationNoticeVisible = true }
    private func save() { let repo = MarkdownRepository(root: workspace.rootURL); do { try repo.save(MarkdownParser.replaceWeekly(original, with: plan), relative: file, loadedHash: loadedHash); notice = "已保存到工作台/下周计划.md"; load(); workspace.refreshGitStatus() } catch { notice = error.localizedDescription } }
    private func commitCell(_ target: WeeklyEditTarget, value: String) {
        switch target.kind {
        case .grid(let row, let column): plan.cells[row][column] = value
        }
    }
}

private struct MigrationNotice: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("已生成旧计划迁移预览").font(.subheadline.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("预览只存在于内存；确认三个时段内容后点击保存才会更新 Markdown。").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("知道了", action: dismiss).buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.orange.opacity(0.25)) }
    }
}

private struct DeliveryTextEditor: View {
    @Binding var text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var editorHeight: CGFloat {
        let lines = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
        return min(118, max(36, CGFloat(lines) * 20 + 12))
    }
    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: StudyRocketTheme.bodySize))
            .scrollContentBackground(.hidden)
            .frame(height: editorHeight)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: editorHeight)
    }
}

private struct WeeklyEditTarget: Identifiable {
    enum Kind { case grid(row: Int, column: Int) }
    let id: String
    let title: String
    let text: String
    let kind: Kind
}

private struct WeeklyCellEditorPopover: View {
    let target: WeeklyEditTarget
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    init(target: WeeklyEditTarget, onCommit: @escaping (String) -> Void) { self.target = target; self.onCommit = onCommit; _text = State(initialValue: target.text) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.title).font(.headline)
            TextEditor(text: $text).font(.system(size: StudyRocketTheme.bodySize)).scrollContentBackground(.hidden).padding(8).frame(width: 380, height: 190).overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("完成") { onCommit(text); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: [.command]) }
        }.padding(16).frame(width: 420)
    }
}

private struct WeeklyGridPlanEditor: View {
    @Binding var plan: WeeklyPlan
    let edit: (WeeklyEditTarget) -> Void
    var body: some View {
        StudySurface {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(WeeklyPlan.days.indices, id: \.self) { column in
                        WeeklyDayColumn(
                            title: dayTitle(for: column),
                            isToday: plan.isToday(column: column),
                            cells: cells(for: column),
                            unassigned: unassigned(for: column)
                        ) { row in
                            edit(target(for: row, column: column))
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }
    private func dayTitle(for column: Int) -> String {
        guard plan.dayDateLabels.indices.contains(column), !plan.dayDateLabels[column].isEmpty else { return WeeklyPlan.days[column] }
        return "\(WeeklyPlan.days[column]) · \(plan.dayDateLabels[column])"
    }
    private func cells(for column: Int) -> [String] {
        WeeklyPlan.periods.indices.map { row in
            plan.cells.indices.contains(row) && plan.cells[row].indices.contains(column) ? plan.cells[row][column] : ""
        }
    }
    private func unassigned(for column: Int) -> String {
        plan.unassignedByDay.indices.contains(column) ? plan.unassignedByDay[column] : ""
    }
    private func target(for row: Int, column: Int) -> WeeklyEditTarget {
        let text = plan.cells.indices.contains(row) && plan.cells[row].indices.contains(column) ? plan.cells[row][column] : ""
        return WeeklyEditTarget(id: "grid-\(row)-\(column)", title: "\(dayTitle(for: column)) · \(WeeklyPlan.periods[row])", text: text, kind: .grid(row: row, column: column))
    }
}

private struct WeeklyDayColumn: View {
    let title: String
    let isToday: Bool
    let cells: [String]
    let unassigned: String
    let edit: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(isToday ? .bold : .semibold)).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(0..<3, id: \.self) { row in
                Button { edit(row) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(WeeklyPlan.periods[row]).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(cells.indices.contains(row) && !cells[row].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? cells[row] : "未安排")
                            .font(.system(size: 13)).foregroundStyle(cells.indices.contains(row) && !cells[row].isEmpty ? .primary : .secondary)
                            .lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .padding(9).frame(width: 142, alignment: .topLeading).frame(minHeight: 76, alignment: .topLeading)
                    .background(isToday ? Color.accentColor.opacity(0.07) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(isToday ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.12)) }
                }.buttonStyle(.plain).accessibilityLabel("\(title)，\(WeeklyPlan.periods[row])，编辑任务")
            }
            if !unassigned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("待分时", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange).help(unassigned)
            }
        }
        .frame(width: 142, alignment: .leading)
    }
}

private struct WeeklyCellPreview: View {
    let text: String
    var body: some View {
        Text(text.isEmpty ? "未安排" : text)
            .font(.caption).multilineTextAlignment(.leading).lineLimit(2)
            .frame(width: 124, alignment: .topLeading)
            .frame(minHeight: 44, maxHeight: 64, alignment: .topLeading).padding(6)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct DailyCheckinView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var chat: StudyChatStore
    @State private var entry = DailyEntry(id: "", date: "", deliverables: "", studyTime: "", sleep: "", exercise: "", firstTask: ""); @State private var original = ""; @State private var hash = ""; @State private var notice: String?
    private let formatter = DateFormatter(); private var monthFile: String { "工作台/每日记录/" + String(entry.date.prefix(7)) + ".md" }
    var body: some View { PageScaffold { VStack(alignment: .leading, spacing: StudyRocketTheme.sectionGap) {
        PageTitleBar(title: "每日复盘", subtitle: "三分钟行为账：只记录已经发生的事实") { StudyIconButton(systemImage: "bubble.left.and.bubble.right", label: "在学业对话中复盘") { chat.prepare(prompt: ReminderRoute.daily.prompt); NotificationCenter.default.post(name: .studyRocketOpenChat, object: nil) } }
        Form { DatePicker("日期", selection: Binding(get: { dateValue }, set: { entry.date = $0.formatted(.iso8601.year().month().day()) }), displayedComponents: .date); TextField("今日完成的具体交付物", text: $entry.deliverables); TextField("净学习时长", text: $entry.studyTime); TextField("入睡/起床", text: $entry.sleep); TextField("运动", text: $entry.exercise); TextField("明日第一任务", text: $entry.firstTask) }.formStyle(.grouped)
        Button("保存行为账", systemImage: "checkmark.circle") { save() }.buttonStyle(.borderedProminent)
    } }.onAppear { entry.date = Date.now.formatted(.iso8601.year().month().day()); load() }.alert("保存结果", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("好", role: .cancel) {} } message: { Text(notice ?? "") } }
    private var dateValue: Date { ISO8601DateFormatter().date(from: entry.date) ?? .now }
    private func load() { let repo = MarkdownRepository(root: workspace.rootURL); original = (try? repo.read(monthFile)) ?? ""; hash = repo.hash(original); entry = MarkdownParser.daily(original, date: entry.date) }
    private func save() {
        let repo = MarkdownRepository(root: workspace.rootURL)
        do {
            try repo.save(MarkdownParser.replaceDaily(original, entry: entry), relative: monthFile, loadedHash: hash)
            try HabitProfileUpdater.update(after: entry, in: workspace.rootURL)
            notice = "已保存今天的行为账，并更新了助理习惯画像"
            load()
            workspace.refreshGitStatus()
            workspace.refreshMarkdownIndex()
        } catch { notice = error.localizedDescription }
    }
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

    private var files: [String] { (suppliedFiles ?? workspace.markdownIndex).filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text(title).font(.headline)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, showsSearch ? 4 : 10)
                if showsSearch { TextField("过滤 Markdown", text: $query).textFieldStyle(.roundedBorder).padding(10).onChange(of: query) { _, _ in ensureSelection() } }
                List(selection: Binding(get: { selected }, set: { requestSelection($0) })) {
                    ForEach(files, id: \.self) { file in Label(file.split(separator: "/").last.map(String.init) ?? file, systemImage: "doc.text").tag(Optional(file)) }
                }
            }
            .frame(width: 220)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            Group {
                if document.relative != nil { MarkdownDocumentView(document: document) }
                else { ContentUnavailableView("选择一份 Markdown", systemImage: "doc.text", description: Text("详细内容保留在仓库文件中")) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { configureAndLoad() }
        .onChange(of: title) { _, _ in configureAndLoad() }
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
                    Text(document.relative ?? "Markdown").font(.headline).lineLimit(1).truncationMode(.middle)
                    if document.isDirty { Label("未保存", systemImage: "circle.fill").font(.caption).foregroundStyle(.orange) }
                }
                Spacer()
                Picker("显示模式", selection: $document.mode) { ForEach(MarkdownMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).frame(width: 132)
                Button("保存", systemImage: "square.and.arrow.down") { save() }.keyboardShortcut("s", modifiers: .command).disabled(!document.isDirty).buttonStyle(.borderedProminent)
            }.padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
            Divider()
            Group {
                if document.mode == .preview { MarkdownPreview(text: document.text, baseURL: workspace.rootURL) }
                else { TextEditor(text: $document.text).font(.system(size: 14, design: .monospaced)).padding(16).overlay(alignment: .bottomLeading) { Text("Markdown 源码 · 预览会显示当前草稿").font(.caption2).foregroundStyle(.tertiary).padding(20) } }
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
                .markdownTextStyle { FontSize(15); ForegroundColor(.primary) }
                .markdownBlockStyle(\.blockquote) { configuration in configuration.label.padding(.leading, 14).padding(.vertical, 4).overlay(alignment: .leading) { Rectangle().fill(Color.teal).frame(width: 3) } }
                .textSelection(.enabled)
                .frame(maxWidth: StudyRocketTheme.readingMaxWidth, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .center)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}


struct SettingsView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var reminders: ReminderScheduler
    var body: some View { ScrollView { Form { Section("当前仓库") { Text(workspace.rootURL.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled); Text("需要迁移仓库时，请使用侧边栏底部的“重新绑定仓库”。").font(.caption).foregroundStyle(.secondary) }; Section("学业对话") { LabeledContent("Codex 连接", value: "复用本机登录，不保存令牌"); Text("应用会单独续接 StudyRocket 学业助理任务，开发任务不会被读取。").font(.caption).foregroundStyle(.secondary) }; Section("原生提醒") { LabeledContent("权限", value: reminders.authorization); ForEach(ReminderRoute.allCases) { route in Toggle(route.title, isOn: Binding(get: { reminders.enabled[route] ?? true }, set: { reminders.toggle(route, isOn: $0) })); HStack { Text("下一次").font(.caption).foregroundStyle(.secondary); Spacer(); Text(nextDateText(for: route)).font(.caption.monospacedDigit()).foregroundStyle(.secondary); Button("测试") { reminders.sendTest(route) }.buttonStyle(.link) } }; Button("请求通知权限并登记") { reminders.requestPermissionAndSchedule() }.buttonStyle(.borderedProminent) }; Section("运行方式") { LabeledContent("后台服务", value: "无"); LabeledContent("数据存储", value: "Markdown 文件"); LabeledContent("旧自动任务", value: "验收前保留") }; Section("隐私") { Text("应用不保存模型凭证，不创建网络监听端口；PDF 继续使用私有云盘单独备份。学业对话继承当前 Codex 端点配置。").font(.callout).foregroundStyle(.secondary) } }.formStyle(.grouped).frame(maxWidth: 760).frame(maxWidth: .infinity).padding(24) } }
    private func nextDateText(for route: ReminderRoute) -> String { guard let date = reminders.nextDates[route] ?? nil else { return "待登记" }; return date.formatted(date: .abbreviated, time: .shortened) }
}

struct StudyChatView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var chat: StudyChatStore
    @State private var showHelp = false
    var body: some View {
        VStack(spacing: 0) {
            ChatToolbar(statusColor: statusColor) { showHelp = true }
            ChatTranscript()
            if let error = chat.errorMessage {
                ChatInlineError(message: error)
            }
            ChatComposer()
        }
        .task { await chat.connect(to: workspace.rootURL) }.onChange(of: workspace.rootURL) { _, root in Task { await chat.connect(to: root) } }.onDisappear { chat.disconnect() }.sheet(isPresented: $showHelp) { ChatHelpView() }
    }
    private var statusColor: Color { switch chat.connectionState { case .connected: .green; case .thinking, .reconnecting, .connecting: .orange; case .failed: .red; default: .secondary } }
}

private struct ChatToolbar: View {
    @EnvironmentObject private var chat: StudyChatStore
    let statusColor: Color
    let showHelp: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            StudyRocketAvatar(size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("StudyRocket 学业助理").font(.system(size: 15, weight: .semibold))
                Label(chat.status, systemImage: "circle.fill").font(.caption).foregroundStyle(statusColor).labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 12)
            StudyIconButton(systemImage: "arrow.up.right.square", label: "在 Codex 中打开", action: chat.openInCodex, disabled: chat.threadID == nil)
            StudyIconButton(systemImage: "questionmark.circle", label: "帮助", action: showHelp)
        }
        .padding(.horizontal, StudyRocketTheme.pageInset).padding(.vertical, 9)
        .background(.bar).overlay(alignment: .bottom) { Divider() }
    }
}

private struct ChatTranscript: View {
    @EnvironmentObject private var chat: StudyChatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let viewportWidth = geometry.size.width
            let canvasWidth = max(1, viewportWidth - StudyRocketTheme.pageInset * 2)
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                        if chat.turns.isEmpty {
                            ContentUnavailableView("开始你的学业对话", systemImage: "bubble.left.and.bubble.right", description: Text("可以问课程、保研、科研，也可以让助理生成计划修改草案。"))
                                .frame(width: canvasWidth).frame(minHeight: 260)
                        }
                        ForEach(Array(chat.turns.enumerated()), id: \.element.id) { index, turn in
                            if index == 0 || !Calendar.current.isDate(chat.turns[index - 1].date, inSameDayAs: turn.date) {
                                ChatDateDivider(date: turn.date).frame(width: canvasWidth)
                            }
                            ChatTurnView(turn: turn, canvasWidth: canvasWidth)
                                .frame(width: canvasWidth, alignment: .leading).id(turn.id)
                        }
                            Color.clear
                                .frame(height: 1)
                                .id("chat-bottom")
                                .background(GeometryReader { marker in
                                    Color.clear.preference(key: ChatBottomPreferenceKey.self, value: marker.frame(in: .named("studyrocket-chat")).maxY)
                                })
                        }
                        .frame(width: canvasWidth, alignment: .leading)
                        .padding(.vertical, 20)
                        .padding(.horizontal, StudyRocketTheme.pageInset)
                        .frame(width: viewportWidth, alignment: .leading)
                    }
                    .coordinateSpace(name: "studyrocket-chat")
                    .onPreferenceChange(ChatBottomPreferenceKey.self) { bottomY in
                        chat.updateScrollPosition(isNearBottom: bottomY <= geometry.size.height + 72)
                    }
                    .onChange(of: chat.scrollRequest?.id) { _, _ in
                        guard let request = chat.scrollRequest else { return }
                        if reduceMotion { proxy.scrollTo(request.target, anchor: .bottom) }
                        else { withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(request.target, anchor: .bottom) } }
                    }
                    .onChange(of: chat.historyRevision) { _, _ in
                        DispatchQueue.main.async { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                    }
                    .onAppear {
                        DispatchQueue.main.async { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                    }
                    if !chat.isNearBottom && !chat.turns.isEmpty {
                        StudyIconButton(systemImage: "arrow.down", label: "回到最新消息") {
                            chat.requestScrollToBottom()
                        }
                        .background(.regularMaterial, in: Circle())
                        .padding(.trailing, StudyRocketTheme.pageInset)
                        .padding(.bottom, 14)
                        .transition(.opacity)
                    }
                }
            }
        }
    }
}

private struct ChatBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ChatInlineError: View {
    @EnvironmentObject private var chat: StudyChatStore
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).textSelection(.enabled)
            Spacer(minLength: 8)
            if chat.lastSubmitted != nil { Button("重试本条") { chat.retryLast() }.buttonStyle(.bordered) }
            Button("重新连接") { Task { await chat.reconnect() } }.buttonStyle(.bordered)
            if chat.canCreateNewTask { Button("创建新学业任务") { Task { await chat.createNewTask() } }.buttonStyle(.bordered) }
        }
        .frame(maxWidth: StudyRocketTheme.chatMaxWidth).frame(maxWidth: .infinity)
        .padding(.horizontal, StudyRocketTheme.pageInset).padding(.vertical, 9)
        .background(Color.orange.opacity(0.10))
    }
}

struct StudyRocketAvatar: View {
    let size: CGFloat
    var body: some View {
        Image(systemName: "point.3.connected.trianglepath.dotted")
            .font(.system(size: size * 0.43, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size).background(Color.teal, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

private extension VerticalAlignment {
    private enum AssistantFirstLineID: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.top] }
    }

    static let assistantFirstLine = VerticalAlignment(AssistantFirstLineID.self)
}

struct ChatDateDivider: View {
    let date: Date
    var body: some View { Text(date.formatted(.dateTime.year().month().day().weekday())).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 2) }
}

struct ChatTurnView: View {
    @EnvironmentObject private var chat: StudyChatStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let turn: ChatTurnPresentation
    let canvasWidth: CGFloat
    @State private var showTime = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let user = turn.userMessage { UserMessageView(message: user, showTime: $showTime, canvasWidth: canvasWidth) }
            ForEach(turn.finalMessages) { message in AssistantMessageView(message: message) }
            if turn.status == .inProgress, turn.finalMessages.isEmpty { ThinkingRow(status: chat.status) }
            if !turn.processMessages.isEmpty { ProcessDisclosureView(turnID: turn.id, messages: turn.processMessages) }
            let turnProposals = chat.proposals.filter { $0.turnID == turn.id }
            if !turnProposals.isEmpty { InlineProposalPanel(turnID: turn.id, proposals: turnProposals) }
            let turnSkillProposals = chat.skillProposals.filter { $0.turnID == turn.id }
            if !turnSkillProposals.isEmpty { InlineSkillProposalPanel(turnID: turn.id, proposals: turnSkillProposals) }
            if let error = turn.errorMessage { Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).padding(.leading, 42) }
        }.frame(width: canvasWidth, alignment: .leading).id(turn.id)
    }
}

struct UserMessageView: View {
    let message: ChatMessage
    @Binding var showTime: Bool
    let canvasWidth: CGFloat
    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                BubbleWidthLayout(maximumWidth: min(600, canvasWidth * 0.7)) {
                    Text(message.text).textSelection(.enabled).padding(.horizontal, 14).padding(.vertical, 11)
                        .font(.system(size: StudyRocketTheme.bodySize))
                        .multilineTextAlignment(.leading)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).foregroundStyle(.white)
                        .contextMenu { Button("复制", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) } }
                }
                HStack(spacing: 5) {
                    if let state = message.turnState, state != .completed { Text(state == .interrupted ? "已中断" : state == .failed ? "未完成" : "进行中") }
                    if showTime { Text(message.date.formatted(date: .omitted, time: .shortened)) }
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: canvasWidth, alignment: .trailing)
        .onHover { showTime = $0 }
    }
}

private struct BubbleWidthLayout: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        guard let bubble = subviews.first else { return .zero }
        let intrinsic = bubble.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height))
        guard intrinsic.width > maximumWidth else { return intrinsic }
        return bubble.sizeThatFits(ProposedViewSize(width: maximumWidth, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard let bubble = subviews.first else { return }
        bubble.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

struct AssistantMessageView: View {
    let message: ChatMessage
    @State private var hovering = false
    var body: some View {
        HStack(alignment: .assistantFirstLine, spacing: 10) {
            StudyRocketAvatar(size: 26)
                .alignmentGuide(.assistantFirstLine) { dimensions in dimensions[VerticalAlignment.center] }
            VStack(alignment: .leading, spacing: 6) {
                Markdown(message.text).markdownTheme(.gitHub).markdownTextStyle { FontSize(15); ForegroundColor(.primary) }.textSelection(.enabled).frame(maxWidth: StudyRocketTheme.readingMaxWidth, alignment: .leading)
                if hovering { HStack(spacing: 8) { Text(message.date.formatted(date: .omitted, time: .shortened)); Button("复制", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }.labelStyle(.iconOnly).buttonStyle(.plain).help("复制回答") }.font(.caption2).foregroundStyle(.secondary) }
            }
            .alignmentGuide(.assistantFirstLine) { dimensions in
                dimensions[.firstTextBaseline] - 6
            }
            .onHover { hovering = $0 }
            Spacer(minLength: 0)
        }
    }
}

struct ThinkingRow: View {
    let status: String
    var body: some View { HStack(spacing: 10) { StudyRocketAvatar(size: 28); ProgressView().controlSize(.small); Text(status == "重连中..." ? "连接波动，Codex 正在重试" : "正在读取资料").font(.caption).foregroundStyle(.secondary) }.accessibilityLabel(status) }
}

struct ProcessDisclosureView: View {
    @EnvironmentObject private var chat: StudyChatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let turnID: String
    let messages: [ChatMessage]
    var body: some View {
        let expanded = chat.expandedProcessTurnIDs.contains(turnID)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if reduceMotion { chat.toggleProcess(for: turnID) }
                else { withAnimation(.easeInOut(duration: 0.18)) { chat.toggleProcess(for: turnID) } }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: "waveform.path.ecg")
                    Text(expanded ? "收起过程" : "查看过程（\(messages.count)）")
                    Spacer()
                }.font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(minHeight: 44).padding(.horizontal, 12)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(expanded ? "收起过程，\(messages.count) 条" : "查看过程，\(messages.count) 条").accessibilityHint("双击展开或收起该回合的过程消息")
            if expanded { VStack(alignment: .leading, spacing: 8) { ForEach(messages) { Text($0.text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.leading, 14) } }.padding(.bottom, 4) }
        }.padding(.leading, 36).frame(maxWidth: StudyRocketTheme.readingMaxWidth + 36, alignment: .leading)
    }
}

struct InlineProposalPanel: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var chat: StudyChatStore
    let turnID: String
    let proposals: [MarkdownChangeProposal]
    var body: some View {
        let expanded = chat.expandedProposalTurnIDs.contains(turnID)
        VStack(alignment: .leading, spacing: 8) {
            Button { chat.toggleProposal(for: turnID) } label: {
                HStack { Image(systemName: expanded ? "chevron.down" : "chevron.right"); Label("待确认修改（\(proposals.count)）", systemImage: "doc.badge.gearshape"); Spacer(); Text(proposals.first?.reason ?? "").lineLimit(1).foregroundStyle(.secondary) }
                    .font(.caption.weight(.medium)).frame(minHeight: 44).padding(.horizontal, 12).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous)).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(expanded ? "收起待确认修改" : "查看待确认修改")
            if expanded {
            ForEach(proposals) { proposal in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Toggle("", isOn: Binding(get: { proposal.isSelected }, set: { chat.setProposal(proposal.id, selected: $0) })).labelsHidden()
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
            HStack { Spacer(); Button("应用已选修改") { chat.applySelectedChanges(workspace: workspace, for: turnID) }.buttonStyle(.borderedProminent) }
            }
        }.padding(.leading, 36).frame(maxWidth: StudyRocketTheme.readingMaxWidth + 36, alignment: .leading)
    }
}

private struct InlineSkillProposalPanel: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var chat: StudyChatStore
    let turnID: String
    let proposals: [SkillChangeProposal]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("待确认 Skill 调整（\(proposals.count)）", systemImage: "slider.horizontal.3")
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            ForEach(proposals) { proposal in
                VStack(alignment: .leading, spacing: 3) {
                    Text(proposal.relativePath).font(.caption.weight(.semibold))
                    Text(proposal.reason).font(.caption2).foregroundStyle(.secondary)
                    Text("只在确认后写入；应用前会再次检查内容是否变更。")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            HStack { Spacer(); Button("应用已选 Skill 调整") { chat.applySelectedSkillChanges(workspace: workspace, for: turnID) }.buttonStyle(.bordered) }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.leading, 36)
        .frame(maxWidth: StudyRocketTheme.readingMaxWidth + 36, alignment: .leading)
    }
}

struct ChatComposer: View {
    @EnvironmentObject private var chat: StudyChatStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(ReminderRoute.allCases) { route in Button(route.title) { chat.prepare(prompt: route.prompt) }.buttonStyle(.borderless).font(.caption) }
                    Button("学业答疑") { chat.prepare(prompt: "我有一个学业问题，请先读取我的档案和相关航线再回答。") }.buttonStyle(.borderless).font(.caption)
                    Spacer()
                }
                Menu("快捷报告") {
                    ForEach(ReminderRoute.allCases) { route in Button(route.title) { chat.prepare(prompt: route.prompt) } }
                    Button("学业答疑") { chat.prepare(prompt: "我有一个学业问题，请先读取我的档案和相关航线再回答。") }
                }.font(.caption)
            }.foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 10) {
                TextField("输入问题或今天完成的事实…", text: $chat.draft, axis: .vertical).lineLimit(2...8).font(.body).textFieldStyle(.plain).padding(11)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.quaternary))
                    .onSubmit { chat.send() }
                if chat.isBusy { StudyIconButton(systemImage: "stop.fill", label: "停止生成", action: chat.stop) }
                else { StudyIconButton(systemImage: "arrow.up", label: "发送（Return）", action: chat.send, disabled: chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            Text("使用当前 Codex 登录和只读学业任务；修改会先生成草案。Shift+Return 换行。") .font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: StudyRocketTheme.chatMaxWidth).frame(maxWidth: .infinity).padding(.horizontal, StudyRocketTheme.pageInset).padding(.vertical, 10).background(.bar)
    }
}

struct ChatHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { VStack(alignment: .leading, spacing: 12) { Text("学业对话帮助").font(.title2.weight(.semibold)); Text("这里连接的是独立的 StudyRocket 学业助理任务，当前应用开发对话不会被带入。你可以直接输入事实或问题，也可以使用快捷报告。遇到进度受阻时，助理会先用一句简短的话承接，再落到一个可执行的下一步或降级方案。"); Text("涉及文件修改时，助理只生成草案；点击应用按钮后才写入 Markdown。学校规则、推免名额、截止日期等未知信息会标记为【待核实】，不会用猜测填充。情绪只用于当轮沟通，不会写入每日账或习惯画像。").foregroundStyle(.secondary); Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(24).frame(width: 440, height: 280) }
}

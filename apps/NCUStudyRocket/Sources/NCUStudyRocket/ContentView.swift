import SwiftUI
import MarkdownUI
import AppKit
import StudyRocketChatCore
import StudyRocketShared

struct ContentView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var document: MarkdownDocumentModel
    @EnvironmentObject private var chat: StudyChatStore
    @EnvironmentObject private var reminders: ReminderScheduler
    @State private var selection: AppSection? = .home
    @State private var pendingSection: AppSection?
    @State private var showBinder = false
    @State private var showUnsavedSectionDialog = false
    @State private var showUnsavedBindingAlert = false
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
                    Button("重新绑定仓库", systemImage: "folder") {
                        if document.isDirty { showUnsavedBindingAlert = true }
                        else { showBinder = true }
                    }
                        .font(.caption)
                }.padding(12)
            }
        } detail: {
            Group {
                switch selection ?? .home {
                case .home: DashboardView()
                case .timetable: TimetableView()
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
        .alert("先处理未保存修改", isPresented: $showUnsavedBindingAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请先保存或放弃当前 Markdown 修改，再重新绑定仓库。")
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var dashboard = DashboardModel()
    @State private var deliveryTargets: [UUID: Bool] = [:]
    @State private var deliveryTasks: [UUID: Task<Void, Never>] = [:]
    @State private var writingDeliveryIDs = Set<UUID>()
    @State private var deliverySealSource: [WeeklyDelivery]?
    @State private var deliverySealPresented = true
    @State private var periodTargets: [String: Bool] = [:]
    @State private var periodTasks: [String: Task<Void, Never>] = [:]
    var body: some View {
        PageScaffold {
            VStack(alignment: .leading, spacing: StudyRocketTheme.sectionGap) {
                PageTitleBar(title: "今天的学习计划", subtitle: Date.now.formatted(date: .complete, time: .omitted)) {
                    if !dashboard.filteredDeliveries.isEmpty {
                        Text("\(dashboard.completedDeliveries) / \(dashboard.filteredDeliveries.count) 已完成")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.teal)
                    }
                }
                TimetableOverview(snapshot: dashboard.timetable)
                ResponsiveColumns {
                    let todayTasks = dashboard.todayCells.map { item in
                        TodayPeriodTask(
                            id: item.id,
                            dayID: item.dayID,
                            periodID: item.periodID,
                            taskID: item.taskID,
                            period: item.period,
                            task: item.task,
                            isCompleted: periodTargets[item.id] ?? item.isCompleted
                        )
                    }
                    let todayFocus = DesktopTodayFocus.resolve(tasks: todayTasks)
                    TodayPlanList(
                        tasks: todayTasks,
                        focus: todayFocus,
                        unassigned: dashboard.todayUnassigned,
                        toggle: requestPeriodToggle
                    )
                } second: {
                    DeliveryOverview(
                        deliveries: dashboard.visibleDeliveries,
                        sealSource: deliverySealSource,
                        sealPresented: deliverySealPresented,
                        completion: { deliveryTargets[$0.id] ?? $0.isCompleted },
                        isPending: { deliveryTargets[$0.id] != nil && !writingDeliveryIDs.contains($0.id) },
                        isWriting: { writingDeliveryIDs.contains($0.id) },
                        toggle: requestDeliveryToggle,
                        emptyMessage: dashboard.plan.deliveries.isEmpty ? "周计划中还没有交付物。" : "本周交付物已完成",
                        completed: dashboard.filteredDeliveries.filter { deliveryTargets[$0.id] ?? $0.isCompleted }.count,
                        total: dashboard.filteredDeliveries.count
                    )
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
        .onAppear { reloadDashboard(from: workspace.rootURL) }
        .onDisappear(perform: cancelPendingToggles)
        .onChange(of: workspace.rootURL) { _, root in
            reloadDashboard(from: root)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadDashboard(from: workspace.rootURL)
        }
        .onReceive(NotificationCenter.default.publisher(for: .studyRocketTimetableChanged)) { _ in
            reloadDashboard(from: workspace.rootURL)
        }
    }

    private func requestDeliveryToggle(_ delivery: WeeklyDelivery) {
        guard !writingDeliveryIDs.contains(delivery.id) else { return }
        if let task = deliveryTasks.removeValue(forKey: delivery.id) {
            task.cancel()
            deliveryTargets.removeValue(forKey: delivery.id)
            return
        }
        let target = !(deliveryTargets[delivery.id] ?? delivery.isCompleted)
        deliveryTargets[delivery.id] = target
        deliveryTasks[delivery.id] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            writingDeliveryIDs.insert(delivery.id)
            await Task.yield()
            guard !Task.isCancelled else { return }

            let sealSource = dashboard.visibleDeliveries
            let succeeded = dashboard.toggleDelivery(delivery.id, workspace: workspace)

            guard succeeded else {
                writingDeliveryIDs.remove(delivery.id)
                deliveryTasks.removeValue(forKey: delivery.id)
                deliveryTargets.removeValue(forKey: delivery.id)
                return
            }

            if target,
               !dashboard.filteredDeliveries.isEmpty,
               dashboard.completedDeliveries == dashboard.filteredDeliveries.count {
                deliverySealSource = sealSource
                deliverySealPresented = false
                await Task.yield()
                guard !Task.isCancelled, deliverySealSource != nil else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.34, dampingFraction: 1)) {
                    deliverySealPresented = true
                }
            }

            writingDeliveryIDs.remove(delivery.id)
            deliveryTasks.removeValue(forKey: delivery.id)
            deliveryTargets.removeValue(forKey: delivery.id)
        }
    }

    private func requestPeriodToggle(_ item: TodayPeriodTask) {
        let taskKey = item.id
        if let task = periodTasks.removeValue(forKey: taskKey) {
            task.cancel()
            periodTargets.removeValue(forKey: taskKey)
            return
        }
        guard item.taskID != nil,
              !item.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let target = !item.isCompleted
        periodTargets[taskKey] = target
        periodTasks[taskKey] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            periodTasks.removeValue(forKey: taskKey)
            periodTargets.removeValue(forKey: taskKey)
            dashboard.setPeriodTaskCompletion(item, isCompleted: target, workspace: workspace)
        }
    }

    private func cancelPendingToggles() {
        deliveryTasks.values.forEach { $0.cancel() }
        periodTasks.values.forEach { $0.cancel() }
        deliveryTasks.removeAll()
        periodTasks.removeAll()
        deliveryTargets.removeAll()
        writingDeliveryIDs.removeAll()
        deliverySealSource = nil
        deliverySealPresented = true
        periodTargets.removeAll()
    }

    private func reloadDashboard(from root: URL) {
        cancelPendingToggles()
        dashboard.load(from: root)
    }
}

private struct TimetableOverview: View {
    let snapshot: TimetableSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label("今日课程", systemImage: "calendar.badge.clock")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 12)
                Text(snapshotHeader)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.bottom, 10)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: StudyRocketTheme.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: StudyRocketTheme.cornerRadius, style: .continuous)
                .strokeBorder(.quaternary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("今日课程")
    }

    @ViewBuilder
    private var content: some View {
        switch snapshot.status {
        case .notImported:
            TimetableStateNotice(
                text: "尚未找到 261 一班课表，请在资料库中确认课表 Markdown 已存在。",
                symbol: "calendar.badge.exclamationmark",
                tint: .orange
            )
        case .invalid:
            TimetableStateNotice(
                text: "课表文件格式有误，今日课程暂不可用。请检查资料库中的课表文件。",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        case .beforeTerm:
            TimetableStateNotice(
                text: "课表已接入，课程从 \(dateText(snapshot.firstImportedDate)) 开始。",
                symbol: "calendar.badge.clock",
                tint: .secondary
            )
        case .afterTerm:
            TimetableStateNotice(
                text: "已导入范围结束于 \(dateText(snapshot.lastImportedDate))，未推算后续周次。",
                symbol: "calendar.badge.checkmark",
                tint: .secondary
            )
        case .available:
            if let day = snapshot.days.first(where: { $0.id == snapshot.referenceDate }) {
                let holidays = day.entries.filter { $0.kind == .holiday }
                let entries = day.entries.filter { $0.kind != .holiday }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(holidays) { entry in
                        TimetableStateNotice(text: entry.title, symbol: "sun.max.fill", tint: .orange)
                            .padding(.bottom, entries.isEmpty ? 8 : 10)
                    }
                    if entries.isEmpty {
                        Label("今日无课程安排", systemImage: holidays.isEmpty ? "calendar" : "calendar.badge.checkmark")
                            .font(.system(size: StudyRocketTheme.bodySize))
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 44, alignment: .leading)
                    } else {
                        ForEach(entries) { entry in
                            TimetableEntryRow(entry: entry)
                        }
                    }
                }
            } else {
                TimetableStateNotice(
                    text: "今日课程快照缺少对应日期，请刷新后重试。",
                    symbol: "arrow.clockwise",
                    tint: .orange
                )
            }
        }
    }

    private var snapshotHeader: String {
        [snapshot.classLabel, snapshot.weekLabel].compactMap { $0 }.joined(separator: " · ")
    }

    private func dateText(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "待定日期" }
        return value
    }
}

private struct TimetableEntryRow: View {
    let entry: TimetableEntrySnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(entry.kind == .course ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.timeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let periodLabel = entry.periodLabel, !periodLabel.isEmpty {
                        Text(entry.periodText(periodLabel))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(displayTitle.primary)
                    .font(.system(size: StudyRocketTheme.bodySize, weight: entry.kind == .course ? .medium : .regular))
                    .foregroundStyle(entry.kind == .course ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let secondary = displayTitle.secondary {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    metadata(horizontal: true)
                    metadata(horizontal: false)
                }
                if let note = entry.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 34)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.accessibilityText)
    }

    @ViewBuilder
    private func metadata(horizontal: Bool) -> some View {
        if horizontal {
            HStack(alignment: .top, spacing: 12) {
                metadataItems
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                metadataItems
            }
        }
    }

    @ViewBuilder
    private var metadataItems: some View {
        if let location = entry.location, !location.isEmpty {
            Label(location, systemImage: "mappin.and.ellipse")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if entry.kind == .course {
            Label("地点待确认", systemImage: "mappin.and.ellipse")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let instructor = entry.instructor, !instructor.isEmpty {
            Label(instructor, systemImage: "person")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if entry.kind == .course {
            Label("教师待确认", systemImage: "person")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var displayTitle: TimetableDisplayTitle {
        StudyRocketTimetableCourseCatalog.displayTitle(for: entry.title)
    }
}

private struct TimetableStateNotice: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: StudyRocketTheme.bodySize))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

private extension TimetableEntrySnapshot {
    var symbol: String {
        switch kind {
        case .course: return "book.closed"
        case .support: return "questionmark.circle"
        case .officeHour: return "person.crop.circle"
        case .event: return "calendar.badge.clock"
        case .holiday: return "sun.max.fill"
        }
    }

    var timeText: String {
        switch (startTime, endTime) {
        case let (start?, end?): return "\(start) - \(end)"
        case let (start?, nil): return "\(start) 开始"
        case let (nil, end?): return "\(end) 结束"
        case (nil, nil): return "时间待定"
        }
    }

    func periodText(_ value: String) -> String {
        value.contains("节") ? value : "第\(value)节"
    }

    var accessibilityText: String {
        var values = [timeText, title]
        if let periodLabel, !periodLabel.isEmpty { values.append(periodText(periodLabel)) }
        if let location, !location.isEmpty { values.append(location) }
        if let instructor, !instructor.isEmpty { values.append(instructor) }
        return values.joined(separator: "，")
    }
}

/// The dashboard writes through DashboardModel so completion only settles
/// after the weekly Markdown file has been saved atomically.
private struct DeliveryOverview: View {
    let deliveries: [WeeklyDelivery]
    let sealSource: [WeeklyDelivery]?
    let sealPresented: Bool
    let completion: (WeeklyDelivery) -> Bool
    let isPending: (WeeklyDelivery) -> Bool
    let isWriting: (WeeklyDelivery) -> Bool
    let toggle: (WeeklyDelivery) -> Void
    let emptyMessage: String
    let completed: Int
    let total: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var sealFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Label("本周交付物", systemImage: "checkmark.circle")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if total > 0 {
                    Text("\(completed) / \(total)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.teal)
                }
            }
            .padding(.bottom, 8)
            if let sealSource {
                ZStack(alignment: .leading) {
                    if sealPresented {
                        DeliveryCompletionSeal()
                            .accessibilityFocused($sealFocused)
                            .transition(sealTransition)
                    } else {
                        deliveryRows(sealSource, forceCompleted: true)
                            .transition(rowsTransition)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if deliveries.isEmpty {
                if total == 0 {
                    Label(emptyMessage, systemImage: "tray")
                        .font(.system(size: StudyRocketTheme.bodySize))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44, alignment: .leading)
                } else {
                    DeliveryCompletionSeal()
                }
            } else {
                deliveryRows(deliveries)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: StudyRocketTheme.cornerRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: StudyRocketTheme.cornerRadius, style: .continuous).strokeBorder(.quaternary) }
        .onChange(of: sealPresented) { _, presented in
            if presented, sealSource != nil { sealFocused = true }
        }
    }

    @ViewBuilder
    private func deliveryRows(_ rows: [WeeklyDelivery], forceCompleted: Bool = false) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, delivery in
            DeliveryOverviewRow(
                delivery: delivery,
                isCompleted: forceCompleted || completion(delivery),
                isPending: !forceCompleted && isPending(delivery),
                isWriting: isWriting(delivery),
                isLast: index == rows.count - 1,
                toggle: { toggle(delivery) }
            )
        }
    }

    private var rowsTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(x: -8))
    }

    private var sealTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity
                .combined(with: .offset(x: -6))
                .combined(with: .scale(scale: 0.96, anchor: .leading))
    }
}

private struct DeliveryOverviewRow: View {
    let delivery: WeeklyDelivery
    let isCompleted: Bool
    let isPending: Bool
    let isWriting: Bool
    let isLast: Bool
    let toggle: () -> Void

    private var presentation: WeeklyDeliveryPresentation {
        WeeklyDeliveryPresentation(text: delivery.text)
    }

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 4) {
                    Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle.fill")
                        .foregroundStyle(isCompleted ? Color.teal : Color.accentColor)
                        .font(.system(size: 14, weight: .semibold))
                        .accessibilityHidden(true)
                    if !isLast {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.22))
                            .frame(width: 2)
                            .frame(maxHeight: .infinity)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    if let dateLabel = presentation.dateLabel, !dateLabel.isEmpty {
                        Text(dateLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    DesktopInterruptibleStrikeText(
                        text: presentation.body,
                        isStruck: isCompleted,
                        font: .system(size: StudyRocketTheme.bodySize)
                    )
                }
                Spacer(minLength: 0)
                if isWriting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isWriting)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(delivery.text)
        .accessibilityValue(isWriting ? "正在保存到周计划" : isCompleted ? "已完成" : "未完成")
        .accessibilityHint(isWriting ? "保存成功后显示本周完成印章" : isPending ? "再次点按可撤销，不会写入" : "点按后有 1 秒撤销时间")
    }
}

private struct DeliveryCompletionSeal: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 43, weight: .medium))
                .foregroundStyle(.teal)
                .frame(width: 44, height: 44, alignment: .leading)
                .accessibilityHidden(true)
            Text("本周交付物已完成")
                .font(.system(size: StudyRocketTheme.bodySize, weight: .semibold))
                .foregroundStyle(.teal)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("本周交付物已全部完成，已写入周计划")
    }
}

private struct TodayPlanList: View {
    @EnvironmentObject private var chat: StudyChatStore
    let tasks: [TodayPeriodTask]
    let focus: DesktopTodayFocus
    let unassigned: String
    let toggle: (TodayPeriodTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("今日安排", systemImage: "checklist")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if case .task = focus { Image(systemName: "flag.fill").foregroundStyle(.tint).accessibilityLabel("有待完成任务") }
            }
            .padding(.bottom, 8)
            ForEach(WeeklyPlan.periods, id: \.self) { period in
                let periodTasks = tasks.filter { $0.period == period }
                VStack(alignment: .leading, spacing: 0) {
                    Label(period, systemImage: periodSymbol(period))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 28, alignment: .leading)
                    ForEach(Array(periodTasks.enumerated()), id: \.element.id) { index, item in
                        Button { toggle(item) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .font(.body)
                                    .foregroundStyle(item.isCompleted ? Color.teal : item.task.isEmpty ? Color.secondary.opacity(0.45) : Color.accentColor)
                                    .frame(width: 20, height: 20)
                                    .padding(.top, 1)
                                DesktopInterruptibleStrikeText(
                                    text: item.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未安排" : item.task,
                                    isStruck: item.isCompleted,
                                    font: .system(size: StudyRocketTheme.bodySize),
                                    inactiveColor: item.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .primary
                                )
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, 28)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(item.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("\(item.period)：\(item.task.isEmpty ? "未安排" : item.task)")
                        .accessibilityValue(item.isCompleted ? "已完成" : "未完成")
                        .accessibilityHint(item.task.isEmpty ? "当前时段没有任务" : item.isCompleted ? "点按标记为未完成" : "点按标记为已完成")
                        if index < periodTasks.count - 1 { Divider().padding(.leading, 32) }
                    }
                }
                if period != (WeeklyPlan.periods.last ?? "") { Divider().padding(.vertical, 4) }
            }
            if !unassigned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("今天有待分时安排", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .help(unassigned)
                    .padding(.top, 8)
            }
            switch focus {
            case .completed:
                Label("今日安排已完成", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.teal)
                    .padding(.top, 12)
            case .unplanned:
                Button("去周计划安排今天", systemImage: "calendar.badge.plus") {
                    chat.prepare(prompt: "请根据我的档案和本周约束，为今天安排可执行的时间块。先问缺失事实，不要编造。")
                    NotificationCenter.default.post(name: .studyRocketOpenChat, object: nil)
                }
                .buttonStyle(.bordered)
                .padding(.top, 12)
            case .task:
                EmptyView()
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: StudyRocketTheme.cornerRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: StudyRocketTheme.cornerRadius, style: .continuous).strokeBorder(.quaternary) }
    }

    private func periodSymbol(_ period: String) -> String {
        switch period {
        case "上午": "sun.max"
        case "中午": "sun.and.horizon"
        default: "moon.stars"
        }
    }
}

private enum DesktopTodayFocus {
    case task
    case completed
    case unplanned

    static func resolve(tasks: [TodayPeriodTask]) -> DesktopTodayFocus {
        let assigned = tasks.filter { !$0.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !assigned.isEmpty else { return .unplanned }
        return assigned.contains(where: { !$0.isCompleted }) ? .task : .completed
    }
}

private struct DesktopInterruptibleStrikeText: View {
    let text: String
    let isStruck: Bool
    var font: Font = .body
    var inactiveColor: Color = .primary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    var body: some View {
        Group {
            if reduceMotion {
                Text(text)
                    .font(font)
                    .foregroundStyle(isStruck ? Color.secondary : inactiveColor)
                    .strikethrough(isStruck, color: .secondary)
            } else {
                ZStack(alignment: .leading) {
                    Text(text).font(font).foregroundStyle(inactiveColor)
                    Text(text)
                        .font(font)
                        .foregroundStyle(.secondary)
                        .strikethrough(true, color: .secondary)
                        .mask(alignment: .leading) {
                            Rectangle().scaleEffect(x: progress, anchor: .leading)
                        }
                }
                .onAppear { progress = isStruck ? 1 : 0 }
                .onChange(of: isStruck) { _, value in
                    withAnimation(.linear(duration: value ? 1 : 0.16)) { progress = value ? 1 : 0 }
                }
            }
        }
        .lineSpacing(StudyRocketTheme.bodyLineSpacing)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
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
                            Text(delivery.text)
                                .font(.body)
                                .lineSpacing(StudyRocketTheme.bodyLineSpacing)
                                .strikethrough(delivery.isCompleted, color: .secondary)
                                .foregroundStyle(delivery.isCompleted ? .secondary : .primary)
                                .multilineTextAlignment(.leading)
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

private enum WeeklyPlanDisplayMode: String, CaseIterable, Identifiable {
    case agenda
    case overview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agenda: "日程"
        case .overview: "周览"
        }
    }

    var systemImage: String {
        switch self {
        case .agenda: "list.bullet"
        case .overview: "rectangle.grid.2x2"
        }
    }
}

private enum WeeklyPlanPresentation {
    static func dayTitle(plan: WeeklyPlan, column: Int) -> String {
        let label = dateLabel(plan: plan, column: column)
        guard let date = MarkdownParser.leadingDate(in: label, relativeTo: .now) else {
            return label
        }
        let weekday = MarkdownParser.studyCalendar.component(.weekday, from: date)
        return "\(WeeklyPlan.days[(weekday + 5) % 7]) · \(label)"
    }

    static func dateLabel(plan: WeeklyPlan, column: Int) -> String {
        guard plan.dayDateLabels.indices.contains(column), !plan.dayDateLabels[column].isEmpty else {
            return WeeklyPlan.days.indices.contains(column) ? WeeklyPlan.days[column] : "未标注日期"
        }
        return plan.dayDateLabels[column]
    }

    static func weekdayLabel(plan: WeeklyPlan, column: Int) -> String {
        guard let date = MarkdownParser.leadingDate(in: dateLabel(plan: plan, column: column), relativeTo: .now) else {
            return WeeklyPlan.days.indices.contains(column) ? WeeklyPlan.days[column] : "日期"
        }
        let weekday = MarkdownParser.studyCalendar.component(.weekday, from: date)
        return WeeklyPlan.days[(weekday + 5) % 7]
    }

    static func taskCount(plan: WeeklyPlan, column: Int) -> Int {
        WeeklyPlan.periods.indices.reduce(into: 0) { count, row in
            guard plan.cells.indices.contains(row), plan.cells[row].indices.contains(column) else { return }
            count += PeriodTaskParser.tasks(from: plan.cells[row][column]).count
        }
    }

    static func pendingCount(plan: WeeklyPlan, column: Int) -> Int {
        guard plan.unassignedByDay.indices.contains(column) else { return 0 }
        return PeriodTaskParser.tasks(from: plan.unassignedByDay[column]).count
    }
}

struct WeeklyPlanView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var chat: StudyChatStore
    private static let weeklyPlanPreferences: UserDefaults = {
        guard let configuration = StudyRocketSelfCheckConfiguration.current else {
            return .standard
        }
        guard let defaults = UserDefaults(suiteName: configuration.desktopPreferencesSuite) else {
            preconditionFailure("无法创建隔离周计划偏好域。")
        }
        return defaults
    }()
    @State private var plan = WeeklyPlan(); @State private var original = ""; @State private var loadedHash = ""; @State private var notice: String?
    @State private var editingCell: WeeklyEditTarget?
    @State private var migrationNoticeVisible = true
    @AppStorage("studyrocket.completedDeliveriesExpanded", store: WeeklyPlanView.weeklyPlanPreferences) private var completedDeliveriesExpanded = false
    @AppStorage("studyrocket.weeklyPlan.displayMode", store: WeeklyPlanView.weeklyPlanPreferences) private var displayModeRaw = WeeklyPlanDisplayMode.agenda.rawValue
    @State private var originalDeliveries: [UUID: String] = [:]
    @State private var originalRules: [UUID: (BufferRuleCategory, String)] = [:]
    @State private var deletionReview: WeeklyDeletionSummary?
    @State private var activeEditor: WeeklyRowEditorState?
    @State private var pendingTaskAssignment: WeeklyPendingTaskAssignment?
    @State private var expandedDeliveryIDs = Set<UUID>()
    @State private var expandedBufferRuleIDs = Set<UUID>()
    @State private var pendingCompletionIDs = Set<UUID>()
    @State private var inlineNotice: String?
    @State private var selectedDayLabel: String?
    private let file = "工作台/下周计划.md"

    private var displayMode: Binding<WeeklyPlanDisplayMode> {
        Binding(
            get: { WeeklyPlanDisplayMode(rawValue: displayModeRaw) ?? .agenda },
            set: { displayModeRaw = $0.rawValue }
        )
    }

    private var selectedDayIndex: Int {
        if let selectedDayLabel,
           let index = plan.dayDateLabels.firstIndex(of: selectedDayLabel) {
            return index
        }
        return plan.dayDateLabels.indices.first(where: { plan.isToday(column: $0) })
            ?? plan.dayDateLabels.indices.first
            ?? 0
    }

    private var hasPendingTasks: Bool {
        plan.unassignedByDay.contains { !PeriodTaskParser.tasks(from: $0).isEmpty }
    }

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
        Picker("周计划显示方式", selection: displayMode) {
            ForEach(WeeklyPlanDisplayMode.allCases) { mode in
                Label(mode.title, systemImage: mode.systemImage).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)
        .accessibilityLabel("周计划显示方式")

        switch displayMode.wrappedValue {
        case .agenda:
            WeeklyDaySelector(plan: plan, selectedDay: selectedDayIndex, select: selectDay)
            if hasPendingTasks {
                ResponsiveColumns {
                    WeeklyDayAgenda(
                        plan: plan,
                        day: selectedDayIndex,
                        edit: { target in editingCell = target },
                        returnTask: { row, taskID in returnScheduledTask(row: row, column: selectedDayIndex, taskID: taskID) }
                    )
                } second: {
                    WeeklyPendingTasksSection(plan: plan) { assignment in
                        pendingTaskAssignment = assignment
                    }
                }
            } else {
                WeeklyDayAgenda(
                    plan: plan,
                    day: selectedDayIndex,
                    edit: { target in editingCell = target },
                    returnTask: { row, taskID in returnScheduledTask(row: row, column: selectedDayIndex, taskID: taskID) }
                )
            }
        case .overview:
            WeeklyCompactOverview(plan: plan) { day in
                selectDay(day)
                displayModeRaw = WeeklyPlanDisplayMode.agenda.rawValue
            }
        }
        if let inlineNotice {
            Label(inlineNotice, systemImage: "info.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
        VStack(alignment: .leading, spacing: 16) {
            DeliveryWorkspaceSection(
                title: "未完成交付物",
                subtitle: "每项是一份可检查的产出；换行可补充验收条件。",
                deliveries: plan.deliveries.filter { !$0.isCompleted },
                isCompletedSection: false,
                activeEditor: $activeEditor,
                expandedIDs: $expandedDeliveryIDs,
                pendingCompletionIDs: pendingCompletionIDs,
                beginEditing: beginEditing,
                commitEditing: commitEditing,
                cancelEditing: cancelEditing,
                toggle: requestToggleDelivery,
                remove: removeDelivery,
                move: moveDelivery,
                stepMove: moveDeliveryByStep,
                add: addDelivery
            )
            DeliveryWorkspaceSection(
                title: "已完成交付物",
                subtitle: "完成项保留在本周记录中，可随时取消勾选。",
                deliveries: plan.deliveries.filter(\.isCompleted),
                isCompletedSection: true,
                isExpanded: $completedDeliveriesExpanded,
                activeEditor: $activeEditor,
                expandedIDs: $expandedDeliveryIDs,
                pendingCompletionIDs: pendingCompletionIDs,
                beginEditing: beginEditing,
                commitEditing: commitEditing,
                cancelEditing: cancelEditing,
                toggle: requestToggleDelivery,
                remove: removeDelivery,
                move: moveDelivery,
                stepMove: moveDeliveryByStep,
                add: nil
            )
            BufferWorkspaceSection(
                rules: plan.bufferRules,
                activeEditor: $activeEditor,
                expandedIDs: $expandedBufferRuleIDs,
                beginEditing: beginEditing,
                commitEditing: commitEditing,
                cancelEditing: cancelEditing,
                remove: removeBufferRule,
                move: moveBufferRule,
                stepMove: moveBufferRuleByStep,
                add: addBufferRule
            )
        }
    } }.onAppear(perform: load).popover(item: $editingCell) { target in
        WeeklyCellEditorPopover(target: target) { value in commitCell(target, value: value); editingCell = nil }
    }
    .sheet(item: $pendingTaskAssignment) { assignment in
        WeeklyPendingTaskAssignmentSheet(assignment: assignment, plan: plan) { text, targetDay, targetPeriod in
            assignUnassignedTask(assignment, text: text, targetDay: targetDay, targetPeriod: targetPeriod)
        }
    }
    .sheet(item: $deletionReview) { summary in
        WeeklyDeletionReviewSheet(summary: summary, returnToEditing: { deletionReview = nil }, confirm: { deletionReview = nil; persist() })
    }
    .alert("保存结果", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("好", role: .cancel) {} } message: { Text(notice ?? "") } }
    private func load() {
        let previousDayLabel = selectedDayLabel
        let repo = MarkdownRepository(root: workspace.rootURL)
        original = (try? repo.read(file)) ?? ""
        loadedHash = repo.hash(original)
        plan = MarkdownParser.weekly(original)
        originalDeliveries = Dictionary(uniqueKeysWithValues: plan.deliveries.map { ($0.id, $0.text) })
        originalRules = Dictionary(uniqueKeysWithValues: plan.bufferRules.map { ($0.id, ($0.category, $0.text)) })
        selectedDayLabel = plan.dayDateLabels.contains(previousDayLabel ?? "")
            ? previousDayLabel
            : preferredDayLabel()
        migrationNoticeVisible = true
    }

    private func preferredDayLabel() -> String? {
        let index = plan.dayDateLabels.indices.first(where: { plan.isToday(column: $0) })
            ?? plan.dayDateLabels.indices.first
        guard let index, plan.dayDateLabels.indices.contains(index) else { return nil }
        return plan.dayDateLabels[index]
    }

    private func selectDay(_ index: Int) {
        guard plan.dayDateLabels.indices.contains(index) else { return }
        selectedDayLabel = plan.dayDateLabels[index]
    }
    private func save() {
        let summary = currentDeletionSummary()
        if !summary.isEmpty { deletionReview = summary } else { persist() }
    }
    private func persist() {
        let repo = MarkdownRepository(root: workspace.rootURL)
        do {
            let sourceMigrations = Dictionary(uniqueKeysWithValues: plan.deliveries.compactMap { delivery -> (String, String)? in
                guard let previous = originalDeliveries[delivery.id], previous != delivery.text else { return nil }
                return (
                    DeliveryPeriodMatcher.sourceKey(for: previous),
                    DeliveryPeriodMatcher.sourceKey(for: delivery.text)
                )
            })
            try repo.save(
                MarkdownParser.replaceWeekly(original, with: plan, deliverySourceMigrations: sourceMigrations),
                relative: file,
                loadedHash: loadedHash
            )
            notice = "已保存到工作台/下周计划.md"
            load()
            workspace.refreshGitStatus()
        } catch { notice = error.localizedDescription }
    }
    private func commitCell(_ target: WeeklyEditTarget, value: String) {
        switch target.kind {
        case .grid(let row, let column): plan.cells[row][column] = value
        }
    }
    private func assignUnassignedTask(
        _ assignment: WeeklyPendingTaskAssignment,
        text: String,
        targetDay: Int,
        targetPeriod: Int
    ) {
        let editedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !editedText.isEmpty,
              plan.unassignedByDay.indices.contains(assignment.sourceDay),
              plan.cells.indices.contains(targetPeriod),
              plan.cells[targetPeriod].indices.contains(targetDay) else { return }

        var pendingTasks = PeriodTaskParser.tasks(from: plan.unassignedByDay[assignment.sourceDay]).map(\.text)
        guard pendingTasks.indices.contains(assignment.sourceTask) else { return }
        pendingTasks.remove(at: assignment.sourceTask)
        plan.unassignedByDay[assignment.sourceDay] = pendingTasks.joined(separator: "\n")

        var targetTasks = PeriodTaskParser.tasks(from: plan.cells[targetPeriod][targetDay]).map(\.text)
        targetTasks.append(editedText)
        plan.cells[targetPeriod][targetDay] = targetTasks.joined(separator: "\n")
        inlineNotice = "已纳入安排，点击保存同步到周计划。"
    }
    private func returnScheduledTask(row: Int, column: Int, taskID: String) {
        guard plan.cells.indices.contains(row),
              plan.cells[row].indices.contains(column),
              plan.unassignedByDay.indices.contains(column) else { return }

        let parsedTasks = PeriodTaskParser.tasks(from: plan.cells[row][column])
        var scheduledTasks = parsedTasks.map(\.text)
        guard let taskIndex = parsedTasks.firstIndex(where: { $0.id == taskID }),
              scheduledTasks.indices.contains(taskIndex) else { return }
        let task = scheduledTasks.remove(at: taskIndex)
        plan.cells[row][column] = scheduledTasks.joined(separator: "\n")

        var pendingTasks = PeriodTaskParser.tasks(from: plan.unassignedByDay[column]).map(\.text)
        pendingTasks.append(task)
        plan.unassignedByDay[column] = pendingTasks.joined(separator: "\n")
        inlineNotice = "已退回待分时，点击保存同步到周计划。"
    }
    private func beginEditing(_ state: WeeklyRowEditorState) {
        guard activeEditor == nil || activeEditor?.id == state.id else {
            inlineNotice = "请先完成或取消当前编辑"
            return
        }
        inlineNotice = nil
        activeEditor = state
    }
    private func commitEditing() {
        guard let activeEditor else { return }
        switch activeEditor.kind {
        case .delivery(let id):
            guard let index = plan.deliveries.firstIndex(where: { $0.id == id }) else { break }
            plan.deliveries[index].text = activeEditor.draftText
        case .bufferRule(let id):
            guard let index = plan.bufferRules.firstIndex(where: { $0.id == id }) else { break }
            plan.bufferRules[index].text = activeEditor.draftText
        }
        self.activeEditor = nil
    }
    private func cancelEditing() {
        guard let activeEditor else { return }
        if activeEditor.isNew, activeEditor.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch activeEditor.kind {
            case .delivery(let id): plan.deliveries.removeAll { $0.id == id }
            case .bufferRule(let id): plan.bufferRules.removeAll { $0.id == id }
            }
        }
        self.activeEditor = nil
    }
    private func addDelivery() {
        let delivery = WeeklyDelivery(text: "", isCompleted: false)
        plan.deliveries.append(delivery)
        beginEditing(WeeklyRowEditorState(kind: .delivery(delivery.id), originalText: "", draftText: "", isNew: true))
    }
    private func addBufferRule(_ category: BufferRuleCategory) {
        let rule = BufferRule(category: category, text: "")
        plan.bufferRules.append(rule)
        beginEditing(WeeklyRowEditorState(kind: .bufferRule(rule.id), originalText: "", draftText: "", isNew: true))
    }
    private func toggleDelivery(_ id: UUID) {
        guard let index = plan.deliveries.firstIndex(where: { $0.id == id }) else { return }
        plan.deliveries[index].isCompleted.toggle()
        plan.deliveries.sort { !$0.isCompleted && $1.isCompleted }
    }
    private func requestToggleDelivery(_ id: UUID) {
        guard let delivery = plan.deliveries.first(where: { $0.id == id }) else { return }
        if delivery.isCompleted {
            toggleDelivery(id)
            return
        }
        pendingCompletionIDs.insert(id)
        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.0 : 0.16
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard self.pendingCompletionIDs.remove(id) != nil else { return }
            self.toggleDelivery(id)
        }
    }
    private func removeDelivery(_ id: UUID) { plan.deliveries.removeAll { $0.id == id } }
    private func moveDelivery(_ source: UUID, _ destination: UUID) {
        guard let from = plan.deliveries.firstIndex(where: { $0.id == source }), let to = plan.deliveries.firstIndex(where: { $0.id == destination }), plan.deliveries[from].isCompleted == plan.deliveries[to].isCompleted, from != to else { return }
        let item = plan.deliveries.remove(at: from)
        plan.deliveries.insert(item, at: plan.deliveries.firstIndex(where: { $0.id == destination }) ?? plan.deliveries.endIndex)
    }
    private func moveDeliveryByStep(_ id: UUID, _ step: Int) {
        guard let current = plan.deliveries.first(where: { $0.id == id }) else { return }
        let group = plan.deliveries.filter { $0.isCompleted == current.isCompleted }
        guard let index = group.firstIndex(where: { $0.id == id }), group.indices.contains(index + step) else { return }
        moveDelivery(id, group[index + step].id)
    }
    private func removeBufferRule(_ id: UUID) { plan.bufferRules.removeAll { $0.id == id } }
    private func moveBufferRule(_ source: UUID, _ destination: UUID) {
        guard let from = plan.bufferRules.firstIndex(where: { $0.id == source }), let to = plan.bufferRules.firstIndex(where: { $0.id == destination }), plan.bufferRules[from].category == plan.bufferRules[to].category, from != to else { return }
        let item = plan.bufferRules.remove(at: from)
        plan.bufferRules.insert(item, at: plan.bufferRules.firstIndex(where: { $0.id == destination }) ?? plan.bufferRules.endIndex)
    }
    private func moveBufferRuleByStep(_ id: UUID, _ step: Int) {
        guard let current = plan.bufferRules.first(where: { $0.id == id }) else { return }
        let group = plan.bufferRules.filter { $0.category == current.category }
        guard let index = group.firstIndex(where: { $0.id == id }), group.indices.contains(index + step) else { return }
        moveBufferRule(id, group[index + step].id)
    }
    private func currentDeletionSummary() -> WeeklyDeletionSummary {
        let deliveryIDs = Set(plan.deliveries.map(\.id)), ruleIDs = Set(plan.bufferRules.map(\.id))
        let deliveries = originalDeliveries.compactMap { deliveryIDs.contains($0.key) ? nil : $0.value }.sorted()
        var rules: [BufferRuleCategory: [String]] = [:]
        for (id, item) in originalRules where !ruleIDs.contains(id) { rules[item.0, default: []].append(item.1) }
        return WeeklyDeletionSummary(deliveries: deliveries, rules: rules)
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

private struct WeeklyRowEditorState: Identifiable, Equatable {
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

private struct StudyGroupedSection<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: StudyRocketTheme.cornerRadius, style: .continuous))
        .overlay(alignment: .leading) {
            Capsule().fill(tint.opacity(0.82)).frame(width: 2).padding(.vertical, 16)
        }
        .overlay {
            RoundedRectangle(cornerRadius: StudyRocketTheme.cornerRadius, style: .continuous)
                .strokeBorder(.quaternary)
        }
    }
}

private struct DeliveryWorkspaceSection: View {
    let title: String
    let subtitle: String
    let deliveries: [WeeklyDelivery]
    let isCompletedSection: Bool
    var isExpanded: Binding<Bool>? = nil
    @Binding var activeEditor: WeeklyRowEditorState?
    @Binding var expandedIDs: Set<UUID>
    let pendingCompletionIDs: Set<UUID>
    let beginEditing: (WeeklyRowEditorState) -> Void
    let commitEditing: () -> Void
    let cancelEditing: () -> Void
    let toggle: (UUID) -> Void
    let remove: (UUID) -> Void
    let move: (UUID, UUID) -> Void
    let stepMove: (UUID, Int) -> Void
    let add: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StudyGroupedSection(title: title, subtitle: subtitle, icon: isCompletedSection ? "checkmark.circle" : "checklist", tint: isCompletedSection ? .teal : .accentColor) {
            VStack(alignment: .leading, spacing: 12) {
                if let isExpanded {
                    Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { isExpanded.wrappedValue.toggle() } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold)).frame(width: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title).font(.system(size: 15, weight: .semibold))
                                Text(deliveries.isEmpty ? "暂无已完成交付物" : "\(deliveries.count) 项已完成")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(deliveries.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title)，\(isExpanded.wrappedValue ? "已展开" : "已折叠")")
                    .accessibilityHint("点按显示或收起已完成交付物")
                    if isExpanded.wrappedValue { rows }
                } else {
                    rows
                    if let add {
                        Button("添加交付物", systemImage: "plus", action: add)
                            .buttonStyle(.link)
                            .frame(minHeight: 30, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var rows: some View {
        if deliveries.isEmpty {
            ContentUnavailableView(isCompletedSection ? "暂无已完成交付物" : "本周还没有交付物", systemImage: isCompletedSection ? "checkmark.circle" : "checklist", description: Text(isCompletedSection ? "完成后会自动归到这里。" : "从一项明确、可验收的成果开始。"))
                .frame(maxWidth: .infinity, minHeight: 78)
        } else {
            VStack(spacing: StudyRocketTheme.planRowSpacing) {
                ForEach(Array(deliveries.enumerated()), id: \.element.id) { index, delivery in
                    PlanReadingRow(
                        id: delivery.id,
                        text: delivery.text,
                        metadata: .delivery(WeeklyDeliveryPresentation(text: delivery.text)),
                        isCompleted: delivery.isCompleted,
                        isPendingCompletion: pendingCompletionIDs.contains(delivery.id),
                        isExpanded: expandedIDs.contains(delivery.id),
                        activeEditor: $activeEditor,
                        editorKind: .delivery(delivery.id),
                        position: index,
                        total: deliveries.count,
                        beginEditing: beginEditing,
                        commitEditing: commitEditing,
                        cancelEditing: cancelEditing,
                        toggle: { toggle(delivery.id) },
                        remove: { remove(delivery.id) },
                        move: { move(delivery.id, $0) },
                        stepMove: { stepMove(delivery.id, $0) },
                        toggleExpanded: { toggleExpanded(delivery.id) }
                    )
                }
            }
        }
    }

    private func toggleExpanded(_ id: UUID) {
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
    }
}

private struct BufferWorkspaceSection: View {
    let rules: [BufferRule]
    @Binding var activeEditor: WeeklyRowEditorState?
    @Binding var expandedIDs: Set<UUID>
    let beginEditing: (WeeklyRowEditorState) -> Void
    let commitEditing: () -> Void
    let cancelEditing: () -> Void
    let remove: (UUID) -> Void
    let move: (UUID, UUID) -> Void
    let stepMove: (UUID, Int) -> Void
    let add: (BufferRuleCategory) -> Void

    var body: some View {
        StudyGroupedSection(title: "缓冲与降级", subtitle: "计划受阻时，按日常留白、撞车取舍和最低底线依次降级。", icon: "shield.lefthalf.filled", tint: .secondary) {
            VStack(alignment: .leading, spacing: StudyRocketTheme.planRowSpacing) {
                let orderedRules = BufferRuleCategory.allCases.flatMap { category in rules.filter { $0.category == category } }
                ForEach(Array(orderedRules.enumerated()), id: \.element.id) { index, rule in
                    let categoryRules = rules.filter { $0.category == rule.category }
                    let categoryPosition = categoryRules.firstIndex(where: { $0.id == rule.id }) ?? 0
                    PlanReadingRow(
                        id: rule.id,
                        text: rule.text,
                        metadata: .buffer(index + 1, rule.category.title),
                        isCompleted: false,
                        isPendingCompletion: false,
                        isExpanded: expandedIDs.contains(rule.id),
                        activeEditor: $activeEditor,
                        editorKind: .bufferRule(rule.id),
                        position: categoryPosition,
                        total: categoryRules.count,
                        beginEditing: beginEditing,
                        commitEditing: commitEditing,
                        cancelEditing: cancelEditing,
                        toggle: nil,
                        remove: { remove(rule.id) },
                        move: { move(rule.id, $0) },
                        stepMove: { stepMove(rule.id, $0) },
                        toggleExpanded: { toggleExpanded(rule.id) }
                    )
                }
                HStack(spacing: 12) {
                    ForEach(BufferRuleCategory.allCases) { category in
                        Button("添加\(category.title)", systemImage: "plus") { add(category) }
                            .buttonStyle(.link)
                    }
                }
                .frame(minHeight: 30, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleExpanded(_ id: UUID) {
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
    }
}

private struct BufferRuleGroup: View {
    let category: BufferRuleCategory
    let rules: [BufferRule]
    @Binding var activeEditor: WeeklyRowEditorState?
    @Binding var expandedIDs: Set<UUID>
    let beginEditing: (WeeklyRowEditorState) -> Void
    let commitEditing: () -> Void
    let cancelEditing: () -> Void
    let remove: (UUID) -> Void
    let move: (UUID, UUID) -> Void
    let stepMove: (UUID, Int) -> Void
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: StudyRocketTheme.planRowSpacing) {
            BufferCategoryHeader(category: category)
            ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                PlanReadingRow(
                    id: rule.id,
                    text: rule.text,
                    metadata: .plain,
                    isCompleted: false,
                    isPendingCompletion: false,
                    isExpanded: expandedIDs.contains(rule.id),
                    activeEditor: $activeEditor,
                    editorKind: .bufferRule(rule.id),
                    position: index,
                    total: rules.count,
                    beginEditing: beginEditing,
                    commitEditing: commitEditing,
                    cancelEditing: cancelEditing,
                    toggle: nil,
                    remove: { remove(rule.id) },
                    move: { move(rule.id, $0) },
                    stepMove: { stepMove(rule.id, $0) },
                    toggleExpanded: { toggleExpanded(rule.id) }
                )
            }
            Button("添加规则", systemImage: "plus", action: add)
                .buttonStyle(.link)
                .frame(minHeight: 30, alignment: .leading)
        }
    }

    private func toggleExpanded(_ id: UUID) {
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
    }
}

private struct BufferCategoryHeader: View {
    let category: BufferRuleCategory
    private var icon: String {
        switch category {
        case .daily: "circle.dotted"
        case .collision: "arrow.triangle.branch"
        case .minimum: "flag.fill"
        }
    }
    private var tint: Color {
        switch category {
        case .daily: .secondary
        case .collision: .orange
        case .minimum: .red
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
            Text(category.title).font(.subheadline.weight(.semibold))
        }
        .padding(.top, category == .daily ? 0 : 4)
    }
}

private enum PlanRowMetadata {
    case delivery(WeeklyDeliveryPresentation)
    case buffer(Int, String)
    case plain
}

private struct PlanReadingRow: View {
    let id: UUID
    let text: String
    let metadata: PlanRowMetadata
    let isCompleted: Bool
    let isPendingCompletion: Bool
    let isExpanded: Bool
    @Binding var activeEditor: WeeklyRowEditorState?
    let editorKind: WeeklyRowEditorState.Kind
    let position: Int
    let total: Int
    let beginEditing: (WeeklyRowEditorState) -> Void
    let commitEditing: () -> Void
    let cancelEditing: () -> Void
    let toggle: (() -> Void)?
    let remove: () -> Void
    let move: (UUID) -> Void
    let stepMove: (Int) -> Void
    let toggleExpanded: () -> Void
    @State private var hovering = false

    private var isEditing: Bool { activeEditor?.id == editorID }
    private var editorID: String { WeeklyRowEditorState(kind: editorKind, originalText: text).id }
    private var visibleText: String {
        switch metadata {
        case .delivery(let presentation): return presentation.body
        case .buffer(let index, let title): return "\(index). \(title)：\(text)"
        case .plain: return text
        }
    }
    private var rowLineSpacing: CGFloat {
        switch metadata {
        case .delivery:
            return StudyRocketTheme.bodyLineSpacing
        case .buffer, .plain:
            return 0
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let toggle {
                Button(action: toggle) {
                    Image(systemName: isCompleted || isPendingCompletion ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isCompleted || isPendingCompletion ? .teal : .secondary)
                        .font(.system(size: 17))
                        .frame(width: 28, height: 36)
                }
                .buttonStyle(.plain)
                .help(isCompleted ? "取消完成" : "标记完成")
                .accessibilityLabel(isCompleted ? "取消完成" : "标记完成")
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
            }
            Group {
                if isEditing, let editor = activeEditor {
                    InlinePlanEditor(text: Binding(get: { editor.draftText }, set: { activeEditor?.draftText = $0 }), lineSpacing: rowLineSpacing, commit: commitEditing, cancel: cancelEditing)
                } else {
                    Button(action: toggleExpanded) {
                        VStack(alignment: .leading, spacing: 4) {
                            if case .delivery(let presentation) = metadata, let label = presentation.dateLabel {
                                Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            }
                            Text(visibleText.isEmpty ? "未命名项目" : visibleText)
                                .font(.body)
                                .foregroundStyle(isCompleted ? .secondary : .primary)
                                .strikethrough(isCompleted || isPendingCompletion, color: .secondary)
                                .lineLimit(isExpanded ? nil : 3)
                                .lineSpacing(rowLineSpacing)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onTapGesture(count: 2) { beginEditing(WeeklyRowEditorState(kind: editorKind, originalText: text)) }
                    .accessibilityLabel(visibleText)
                    .accessibilityHint(isExpanded ? "点按收起全文，双击编辑" : "点按展开全文，双击编辑")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HoverActionStrip(position: position, total: total, visible: hovering || isEditing, edit: { beginEditing(WeeklyRowEditorState(kind: editorKind, originalText: text)) }, up: { stepMove(-1) }, down: { stepMove(1) }, remove: remove)
                .draggable(id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, let source = UUID(uuidString: raw), source != id else { return false }
                    move(source)
                    return true
                }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(isEditing ? Color.accentColor.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .bottom) { Divider().padding(.leading, 36) }
        .onHover { hovering = $0 }
    }
}

private struct InlinePlanEditor: View {
    @Binding var text: String
    let lineSpacing: CGFloat
    let commit: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.body)
                .lineSpacing(lineSpacing)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(minHeight: 54, maxHeight: 132)
                .padding(4)
                .background(.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor.opacity(0.45)) }
            HStack(spacing: 8) {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("完成", action: commit).buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .onAppear { focused = true }
    }
}

private struct HoverActionStrip: View {
    let position: Int
    let total: Int
    let visible: Bool
    let edit: () -> Void
    let up: () -> Void
    let down: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 28, height: 44)
                .accessibilityLabel("拖拽排序")
            Button(action: edit) { Image(systemName: "pencil") }.help("编辑").accessibilityLabel("编辑")
            Menu {
                Button("上移", action: up).disabled(position == 0)
                Button("下移", action: down).disabled(position == total - 1)
                Divider()
                Button("删除", role: .destructive, action: remove)
            } label: { Image(systemName: "ellipsis") }
            .help("更多操作")
            .accessibilityLabel("更多操作")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.caption)
        .frame(width: 84, height: 44)
        .opacity(visible ? 1 : 0)
        .accessibilityElement(children: .contain)
    }
}

private struct WeeklyDeletionSummary: Identifiable {
    let deliveries: [String]
    let rules: [BufferRuleCategory: [String]]
    var id: String { deliveries.joined(separator: "|") + rules.values.flatMap { $0 }.joined(separator: "|") }
    var isEmpty: Bool { deliveries.isEmpty && rules.values.allSatisfy(\.isEmpty) }
}

private struct WeeklyDeletionReviewSheet: View {
    let summary: WeeklyDeletionSummary
    let returnToEditing: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认删除并保存").font(.title3.weight(.semibold))
            Text("以下已存在于文件中的内容会在保存时删除。新增后又删除的内容不会列入此处。")
                .font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !summary.deliveries.isEmpty { DeletionSummaryGroup(title: "交付物", values: summary.deliveries) }
                    ForEach(BufferRuleCategory.allCases) { category in
                        if let values = summary.rules[category], !values.isEmpty { DeletionSummaryGroup(title: category.title, values: values) }
                    }
                }
            }
            .frame(maxHeight: 260)
            HStack { Spacer(); Button("返回编辑", action: returnToEditing); Button("确认删除并保存", role: .destructive, action: confirm).buttonStyle(.borderedProminent) }
        }
        .padding(20)
        .frame(width: 520)
    }
}

private struct DeletionSummaryGroup: View {
    let title: String
    let values: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(values, id: \.self) { value in Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
        }
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

private struct WeeklyPendingTaskAssignment: Identifiable {
    let sourceDay: Int
    let sourceTask: Int
    let text: String

    var id: String { "\(sourceDay)-\(sourceTask)-\(text)" }
}

private struct WeeklyPendingTasksSection: View {
    let plan: WeeklyPlan
    let schedule: (WeeklyPendingTaskAssignment) -> Void

    private var assignments: [WeeklyPendingTaskAssignment] {
        plan.unassignedByDay.enumerated().flatMap { day, text in
            PeriodTaskParser.tasks(from: text).enumerated().map { task, value in
                WeeklyPendingTaskAssignment(sourceDay: day, sourceTask: task, text: value.text)
            }
        }
    }

    var body: some View {
        if !assignments.isEmpty {
            StudySurface {
                VStack(alignment: .leading, spacing: 8) {
                    Text("待分时事项").font(.headline)
                    ForEach(assignments) { assignment in
                        Button { schedule(assignment) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "calendar.badge.plus")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 20, height: 20)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(dayTitle(for: assignment.sourceDay))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(assignment.text)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("待分时，\(dayTitle(for: assignment.sourceDay))，\(assignment.text)")
                        .accessibilityHint("选择日期和时段纳入安排")
                    }
                }
            }
        }
    }

    private func dayTitle(for index: Int) -> String {
        guard plan.dayDateLabels.indices.contains(index), !plan.dayDateLabels[index].isEmpty else {
            return WeeklyPlan.days.indices.contains(index) ? WeeklyPlan.days[index] : "未标注日期"
        }
        return plan.dayDateLabels[index]
    }
}

private struct WeeklyPendingTaskAssignmentSheet: View {
    let assignment: WeeklyPendingTaskAssignment
    let plan: WeeklyPlan
    let schedule: (String, Int, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var targetDay: Int
    @State private var targetPeriod = 0

    init(
        assignment: WeeklyPendingTaskAssignment,
        plan: WeeklyPlan,
        schedule: @escaping (String, Int, Int) -> Void
    ) {
        self.assignment = assignment
        self.plan = plan
        self.schedule = schedule
        _text = State(initialValue: assignment.text)
        _targetDay = State(initialValue: assignment.sourceDay)
    }

    private var occupiedTaskCount: Int {
        guard plan.cells.indices.contains(targetPeriod), plan.cells[targetPeriod].indices.contains(targetDay) else { return 0 }
        return PeriodTaskParser.tasks(from: plan.cells[targetPeriod][targetDay]).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("安排待分时事项").font(.headline)
            TextEditor(text: $text)
                .font(.system(size: StudyRocketTheme.bodySize))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(width: 400, height: 116)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
            Picker("日期", selection: $targetDay) {
                ForEach(WeeklyPlan.days.indices, id: \.self) { day in
                    Text(dayTitle(for: day)).tag(day)
                }
            }
            Picker("时段", selection: $targetPeriod) {
                ForEach(WeeklyPlan.periods.indices, id: \.self) { period in
                    Text(WeeklyPlan.periods[period]).tag(period)
                }
            }
            .pickerStyle(.segmented)
            if occupiedTaskCount > 0 {
                Label("该时段已有 \(occupiedTaskCount) 项安排", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("纳入安排") {
                    schedule(text, targetDay, targetPeriod)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private func dayTitle(for index: Int) -> String {
        guard plan.dayDateLabels.indices.contains(index), !plan.dayDateLabels[index].isEmpty else {
            return WeeklyPlan.days.indices.contains(index) ? WeeklyPlan.days[index] : "未标注日期"
        }
        return plan.dayDateLabels[index]
    }
}

private struct WeeklyDaySelector: View {
    let plan: WeeklyPlan
    let selectedDay: Int
    let select: (Int) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        StudySurface {
            if dynamicTypeSize.isAccessibilitySize {
                menuSelector
            } else {
                ViewThatFits(in: .horizontal) {
                    expandedSelector
                    menuSelector
                }
            }
        }
    }

    private var expandedSelector: some View {
        HStack(spacing: 6) {
            ForEach(WeeklyPlan.days.indices, id: \.self) { day in
                let isSelected = day == selectedDay
                let taskCount = WeeklyPlanPresentation.taskCount(plan: plan, column: day)
                let pendingCount = WeeklyPlanPresentation.pendingCount(plan: plan, column: day)
                Button { select(day) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(WeeklyPlanPresentation.weekdayLabel(plan: plan, column: day))
                                .font(.caption.weight(isSelected ? .bold : .semibold))
                            if plan.isToday(column: day) {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 6, height: 6)
                                    .accessibilityHidden(true)
                            }
                        }
                        Text(WeeklyPlanPresentation.dateLabel(plan: plan, column: day))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Label("\(taskCount)", systemImage: "checklist")
                            if pendingCount > 0 {
                                Label("\(pendingCount)", systemImage: "calendar.badge.plus")
                            }
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor.opacity(0.30) : Color.clear)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("\(WeeklyPlanPresentation.dayTitle(plan: plan, column: day))，\(taskCount) 项安排，\(pendingCount) 项待分时")
                .accessibilityValue(isSelected ? "已选中" : "")
            }
        }
    }

    private var menuSelector: some View {
        Menu {
            ForEach(WeeklyPlan.days.indices, id: \.self) { day in
                Button {
                    select(day)
                } label: {
                    if day == selectedDay {
                        Label(WeeklyPlanPresentation.dayTitle(plan: plan, column: day), systemImage: "checkmark")
                    } else {
                        Text(WeeklyPlanPresentation.dayTitle(plan: plan, column: day))
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                Text(WeeklyPlanPresentation.dayTitle(plan: plan, column: selectedDay))
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("选择日期")
        .accessibilityValue(WeeklyPlanPresentation.dayTitle(plan: plan, column: selectedDay))
    }
}

private struct WeeklyDayAgenda: View {
    let plan: WeeklyPlan
    let day: Int
    let edit: (WeeklyEditTarget) -> Void
    let returnTask: (Int, String) -> Void

    var body: some View {
        StudySurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WeeklyPlanPresentation.dayTitle(plan: plan, column: day))
                            .font(.headline)
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if plan.isToday(column: day) {
                        Text("今天")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                ForEach(WeeklyPlan.periods.indices, id: \.self) { row in
                    if row > 0 { Divider() }
                    WeeklyAgendaPeriodRow(
                        dayTitle: WeeklyPlanPresentation.dayTitle(plan: plan, column: day),
                        title: WeeklyPlan.periods[row],
                        text: periodText(row),
                        edit: { edit(target(for: row)) },
                        returnTask: { taskID in returnTask(row, taskID) }
                    )
                }
            }
        }
    }

    private var summary: String {
        let taskCount = WeeklyPlanPresentation.taskCount(plan: plan, column: day)
        let pendingCount = WeeklyPlanPresentation.pendingCount(plan: plan, column: day)
        return pendingCount == 0 ? "\(taskCount) 项安排" : "\(taskCount) 项安排 · \(pendingCount) 项待分时"
    }

    private func periodText(_ row: Int) -> String {
        guard plan.cells.indices.contains(row), plan.cells[row].indices.contains(day) else { return "" }
        return plan.cells[row][day]
    }

    private func target(for row: Int) -> WeeklyEditTarget {
        WeeklyEditTarget(
            id: "grid-\(row)-\(day)",
            title: "\(WeeklyPlanPresentation.dayTitle(plan: plan, column: day)) · \(WeeklyPlan.periods[row])",
            text: periodText(row),
            kind: .grid(row: row, column: day)
        )
    }
}

private struct WeeklyAgendaPeriodRow: View {
    let dayTitle: String
    let title: String
    let text: String
    let edit: () -> Void
    let returnTask: (String) -> Void

    var body: some View {
        let tasks = PeriodTaskParser.tasks(from: text)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Button(action: edit) {
                    Image(systemName: "pencil")
                        .frame(width: StudyRocketTheme.controlHeight, height: StudyRocketTheme.controlHeight)
                }
                .buttonStyle(.borderless)
                .help("编辑\(title)任务")
                .accessibilityLabel("\(dayTitle)，\(title)，编辑任务")
            }
            if tasks.isEmpty {
                Text("未安排")
                    .font(.system(size: StudyRocketTheme.bodySize))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                ForEach(tasks) { task in
                    HStack(alignment: .top, spacing: 8) {
                        Text(task.text)
                            .font(.system(size: StudyRocketTheme.bodySize))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button { returnTask(task.id) } label: {
                            Image(systemName: "tray.and.arrow.down")
                                .frame(width: StudyRocketTheme.controlHeight, height: StudyRocketTheme.controlHeight)
                        }
                        .buttonStyle(.borderless)
                        .help("退回待分时")
                        .accessibilityLabel("将\(task.text)退回待分时")
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WeeklyCompactOverview: View {
    let plan: WeeklyPlan
    let select: (Int) -> Void

    private let columns = [GridItem(.adaptive(minimum: 216), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(WeeklyPlan.days.indices, id: \.self) { day in
                WeeklyCompactDayCard(plan: plan, day: day) { select(day) }
            }
        }
    }
}

private struct WeeklyCompactDayCard: View {
    let plan: WeeklyPlan
    let day: Int
    let select: () -> Void

    var body: some View {
        let taskCount = WeeklyPlanPresentation.taskCount(plan: plan, column: day)
        let pendingCount = WeeklyPlanPresentation.pendingCount(plan: plan, column: day)
        Button(action: select) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WeeklyPlanPresentation.weekdayLabel(plan: plan, column: day))
                            .font(.subheadline.weight(plan.isToday(column: day) ? .bold : .semibold))
                        Text(WeeklyPlanPresentation.dateLabel(plan: plan, column: day))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if plan.isToday(column: day) {
                        Image(systemName: "location.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                ForEach(WeeklyPlan.periods.indices, id: \.self) { row in
                    WeeklyCompactPeriodSummary(title: WeeklyPlan.periods[row], text: periodText(row))
                }
                if pendingCount > 0 {
                    Label("\(pendingCount) 项待分时", systemImage: "calendar.badge.plus")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
            .padding(14)
            .background(
                plan.isToday(column: day) ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: StudyRocketTheme.cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: StudyRocketTheme.cornerRadius, style: .continuous)
                    .strokeBorder(plan.isToday(column: day) ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.18))
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("\(WeeklyPlanPresentation.dayTitle(plan: plan, column: day))，\(taskCount) 项安排，\(pendingCount) 项待分时")
        .accessibilityHint("查看当天日程")
    }

    private func periodText(_ row: Int) -> String {
        guard plan.cells.indices.contains(row), plan.cells[row].indices.contains(day) else { return "" }
        return plan.cells[row][day]
    }
}

private struct WeeklyCompactPeriodSummary: View {
    let title: String
    let text: String

    var body: some View {
        let tasks = PeriodTaskParser.tasks(from: text)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            Text(tasks.first?.text ?? "未安排")
                .font(.caption)
                .foregroundStyle(tasks.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            if tasks.count > 1 {
                Text("\(tasks.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }
}

struct DailyCheckinView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var chat: StudyChatStore
    @State private var entry = DailyEntry(id: "", date: "", deliverables: "", studyTime: "", sleep: "", exercise: "", firstTask: "")
    @State private var original = ""
    @State private var hash = ""
    @State private var notice: String?

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = MarkdownParser.studyCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MarkdownParser.studyCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var monthFile: String { "工作台/每日记录/" + String(entry.date.prefix(7)) + ".md" }

    var body: some View {
        PageScaffold {
            VStack(alignment: .leading, spacing: StudyRocketTheme.sectionGap) {
                PageTitleBar(title: "每日复盘", subtitle: "三分钟行为账：只记录已经发生的事实") {
                    StudyIconButton(systemImage: "bubble.left.and.bubble.right", label: "在学业对话中复盘") {
                        chat.prepare(prompt: ReminderRoute.daily.prompt)
                        NotificationCenter.default.post(name: .studyRocketOpenChat, object: nil)
                    }
                }
                Form {
                    DatePicker("日期", selection: Binding(get: { dateValue }, set: { entry.date = Self.dayFormatter.string(from: $0) }), displayedComponents: .date)
                    TextField("今日完成的具体交付物", text: $entry.deliverables)
                    TextField("净学习时长", text: $entry.studyTime)
                    TextField("入睡/起床", text: $entry.sleep)
                    TextField("运动", text: $entry.exercise)
                    TextField("明日第一任务", text: $entry.firstTask)
                }
                .formStyle(.grouped)
                Button("保存行为账", systemImage: "checkmark.circle") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            entry.date = Self.dayFormatter.string(from: .now)
            load()
        }
        .onChange(of: entry.date) { oldValue, newValue in
            if oldValue != newValue { load() }
        }
        .alert("保存结果", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    private var dateValue: Date { Self.dayFormatter.date(from: entry.date) ?? .now }

    private func load() {
        let repo = MarkdownRepository(root: workspace.rootURL)
        original = (try? repo.read(monthFile)) ?? ""
        hash = repo.hash(original)
        entry = MarkdownParser.daily(original, date: entry.date)
    }

    private func save() {
        let repo = MarkdownRepository(root: workspace.rootURL)
        let savedEntry = entry
        do {
            try repo.save(MarkdownParser.replaceDaily(original, entry: entry), relative: monthFile, loadedHash: hash)
        } catch {
            notice = error.localizedDescription
            return
        }

        load()
        do {
            try HabitProfileUpdater.update(after: savedEntry, in: workspace.rootURL)
            notice = "已保存行为账，并更新助理习惯画像。"
        } catch {
            notice = "行为账已保存，但助理习惯画像更新失败：\(error.localizedDescription)"
        }
        workspace.refreshGitStatus()
        workspace.refreshMarkdownIndex()
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
    private func ensureSelection() { guard let selected, files.contains(selected) else { guard !document.isDirty else { return }; self.selected = files.first; if let first = files.first { document.load(first) }; return } }
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
            ChatTranscript(
                transcript: chat.transcript,
                status: chat.status,
                updateScrollPosition: chat.updateScrollPosition(distanceFromBottom:),
                requestScrollToBottom: { chat.requestScrollToBottom() },
                consumeScrollRequest: chat.transcript.consumeScrollRequest(id:),
                userDidScroll: chat.userDidScroll
            )
            if let error = chat.errorMessage {
                ChatInlineError(message: error)
            }
            ChatComposer()
        }
        .task { await chat.connect(to: workspace.rootURL) }.onChange(of: workspace.rootURL) { _, root in Task { await chat.connect(to: root) } }.sheet(isPresented: $showHelp) { ChatHelpView() }
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
            StudyIconButton(systemImage: "arrow.up.right.square", label: "在 Codex 查看历史；修改计划请在此处发送", action: chat.openInCodex, disabled: chat.threadID == nil)
            StudyIconButton(systemImage: "questionmark.circle", label: "帮助", action: showHelp)
        }
        .padding(.horizontal, StudyRocketTheme.pageInset).padding(.vertical, 9)
        .background(.bar).overlay(alignment: .bottom) { Divider() }
    }
}

private struct ChatTranscript: View {
    @ObservedObject var transcript: ChatTranscriptState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isNearBottom = true
    @State private var didInitialScroll = false
    let status: String
    let updateScrollPosition: (CGFloat) -> Bool
    let requestScrollToBottom: () -> Void
    let consumeScrollRequest: (UUID) -> ChatScrollRequest?
    let userDidScroll: () -> Void

    var body: some View {
        let rows = transcriptRows()
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                List {
                    if transcript.turns.isEmpty {
                        switch transcript.loadState {
                        case .loading:
                            ChatEmptyLoadingView()
                        case .loaded:
                            ContentUnavailableView("开始你的学业对话", systemImage: "bubble.left.and.bubble.right", description: Text("可以问课程、保研、科研，也可以让助理生成计划修改草案。"))
                                .frame(maxWidth: .infinity, minHeight: 260)
                        case .failed(let message):
                            VStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                Text("聊天记录加载失败").font(.headline)
                                Text(message).font(.system(size: StudyRocketTheme.bodySize)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, minHeight: 260)
                        }
                    }
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 18) {
                            if row.showsDateDivider { ChatDateDivider(date: row.turn.date) }
                            ChatTurnView(
                                turn: row.turn,
                                canvasWidth: 840,
                                status: status,
                                processExpanded: row.processExpanded,
                                toggleProcess: {
                                    if transcript.expandedProcessTurnIDs.contains(row.turn.id) { transcript.expandedProcessTurnIDs.remove(row.turn.id) }
                                    else { transcript.expandedProcessTurnIDs.insert(row.turn.id) }
                                },
                                proposals: row.proposals,
                                proposalExpanded: row.proposalExpanded,
                                toggleProposal: {
                                    if transcript.expandedProposalTurnIDs.contains(row.turn.id) { transcript.expandedProposalTurnIDs.remove(row.turn.id) }
                                    else { transcript.expandedProposalTurnIDs.insert(row.turn.id) }
                                },
                                skillProposals: row.skillProposals
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(EdgeInsets(top: 9, leading: StudyRocketTheme.pageInset, bottom: 9, trailing: StudyRocketTheme.pageInset))
                        .listRowSeparator(.hidden)
                        .id(row.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .id("chat-bottom")
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(
                    ChatScrollViewObserver(onDistance: { distance in
                        isNearBottom = distance <= (isNearBottom ? ChatScrollPolicy.leaveThreshold : ChatScrollPolicy.enterThreshold)
                        _ = updateScrollPosition(distance)
                    }, onUserScroll: userDidScroll)
                )
                .onChange(of: transcript.scrollRequest?.id) { _, requestID in
                    guard let requestID, let request = transcript.scrollRequest else { return }
                    if reduceMotion || !request.force {
                        proxy.scrollTo(request.target, anchor: .bottom)
                    } else {
                        withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(request.target, anchor: .bottom) }
                    }
                    _ = consumeScrollRequest(requestID)
                }
                .onAppear { scrollToInitialHistory(using: proxy) }
                .onChange(of: transcript.loadState) { _, state in
                    if state == .loading { didInitialScroll = false; return }
                    scrollToInitialHistory(using: proxy)
                }
                if !isNearBottom && !transcript.turns.isEmpty {
                    StudyIconButton(systemImage: "arrow.down", label: "回到最新消息") {
                        requestScrollToBottom()
                    }
                    .background(.regularMaterial, in: Circle())
                    .padding(.trailing, StudyRocketTheme.pageInset)
                    .padding(.bottom, 14)
                    .transition(.opacity)
                }
            }
        }
    }

    private func scrollToInitialHistory(using proxy: ScrollViewProxy) {
        guard !didInitialScroll, transcript.loadState == .loaded, !transcript.turns.isEmpty else { return }
        didInitialScroll = true
        DispatchQueue.main.async { proxy.scrollTo("chat-bottom", anchor: .bottom) }
    }

    private func transcriptRows() -> [ChatTranscriptRow] {
        let proposalsByTurn = Dictionary(grouping: transcript.proposals, by: \.turnID)
        let skillProposalsByTurn = Dictionary(grouping: transcript.skillProposals, by: \.turnID)
        return transcript.turns.enumerated().map { index, turn in
            ChatTranscriptRow(
                turn: turn,
                showsDateDivider: index == 0 || !Calendar.current.isDate(transcript.turns[index - 1].date, inSameDayAs: turn.date),
                processExpanded: transcript.expandedProcessTurnIDs.contains(turn.id),
                proposals: proposalsByTurn[turn.id] ?? [],
                proposalExpanded: transcript.expandedProposalTurnIDs.contains(turn.id),
                skillProposals: skillProposalsByTurn[turn.id] ?? []
            )
        }
    }
}

private struct ChatEmptyLoadingView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在加载聊天记录…").font(.system(size: StudyRocketTheme.bodySize)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }
}

private struct ChatTranscriptRow: Identifiable {
    let turn: ChatTurnPresentation
    let showsDateDivider: Bool
    let processExpanded: Bool
    let proposals: [MarkdownChangeProposal]
    let proposalExpanded: Bool
    let skillProposals: [SkillChangeProposal]
    var id: String { turn.id }
}

private struct ChatScrollViewObserver: NSViewRepresentable {
    let onDistance: (CGFloat) -> Void
    let onUserScroll: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDistance: onDistance, onUserScroll: onUserScroll) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        DispatchQueue.main.async { context.coordinator.attach(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDistance = onDistance
        context.coordinator.onUserScroll = onUserScroll
        DispatchQueue.main.async { context.coordinator.attach(from: nsView) }
    }

    final class Coordinator {
        var onDistance: (CGFloat) -> Void
        var onUserScroll: () -> Void
        private var observedScrollViews: [NSScrollView] = []
        private var observations: [NSObjectProtocol] = []
        private var readScheduled = false
        private weak var preferredScrollView: NSScrollView?

        init(onDistance: @escaping (CGFloat) -> Void, onUserScroll: @escaping () -> Void) {
            self.onDistance = onDistance
            self.onUserScroll = onUserScroll
        }

        func attach(from view: NSView) {
            guard let window = view.window else {
                retryAttach(from: view)
                return
            }
            var candidates: [NSScrollView] = []
            collectScrollViews(in: window.contentView, into: &candidates)
            let usable = candidates.filter {
                $0.documentView != nil && $0.bounds.width >= 300 && $0.hasVerticalScroller
            }
            guard !usable.isEmpty else {
                retryAttach(from: view)
                return
            }
            let oldIDs = observedScrollViews.map(ObjectIdentifier.init)
            let newIDs = usable.map(ObjectIdentifier.init)
            if oldIDs != newIDs {
                detach()
                observedScrollViews = usable
                let center = NotificationCenter.default
                for scroll in usable {
                    observations.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in self?.onUserScroll() })
                    observations.append(center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self, weak scroll] _ in self?.scheduleRead(for: scroll) })
                    observations.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in self?.scheduleRead(for: scroll) })
                }
            }
            scheduleRead()
        }

        private func retryAttach(from view: NSView) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak view] in
                guard let self, let view else { return }
                self.attach(from: view)
            }
        }

        private func detach() {
            let center = NotificationCenter.default
            observations.forEach(center.removeObserver)
            observations.removeAll()
            observedScrollViews.removeAll()
            preferredScrollView = nil
        }

        private func collectScrollViews(in view: NSView?, into result: inout [NSScrollView]) {
            guard let view else { return }
            if let scroll = view as? NSScrollView { result.append(scroll) }
            for child in view.subviews { collectScrollViews(in: child, into: &result) }
        }

        func scheduleRead(for preferred: NSScrollView? = nil) {
            if let preferred { preferredScrollView = preferred }
            guard !readScheduled else { return }
            readScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readScheduled = false
                let scroll = self.preferredScrollView ?? self.observedScrollViews.max(by: { lhs, rhs in
                    (lhs.documentView?.bounds.height ?? 0) < (rhs.documentView?.bounds.height ?? 0)
                })
                self.preferredScrollView = nil
                guard let scroll, let document = scroll.documentView else { return }
                let distance = max(0, document.bounds.maxY - scroll.contentView.bounds.maxY)
                self.onDistance(distance)
            }
        }

        deinit {
            detach()
        }
    }
}

private struct ChatInlineError: View {
    @EnvironmentObject private var chat: StudyChatStore
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: StudyRocketTheme.bodySize)).textSelection(.enabled)
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
    let turn: ChatTurnPresentation
    let canvasWidth: CGFloat
    let status: String
    let processExpanded: Bool
    let toggleProcess: () -> Void
    let proposals: [MarkdownChangeProposal]
    let proposalExpanded: Bool
    let toggleProposal: () -> Void
    let skillProposals: [SkillChangeProposal]
    @State private var showTime = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let user = turn.userMessage { UserMessageView(message: user, showTime: $showTime, canvasWidth: canvasWidth) }
            ForEach(turn.finalMessages) { message in AssistantMessageView(message: message) }
            if turn.status == .inProgress, turn.finalMessages.isEmpty { ThinkingRow(status: status) }
            if !turn.processMessages.isEmpty {
                ProcessDisclosureView(
                    turnID: turn.id,
                    messages: turn.processMessages,
                    expanded: processExpanded,
                    toggle: toggleProcess
                )
            }
            if !proposals.isEmpty {
                InlineProposalPanel(
                    turnID: turn.id,
                    proposals: proposals,
                    expanded: proposalExpanded,
                    toggle: toggleProposal
                )
            }
            if !skillProposals.isEmpty { InlineSkillProposalPanel(turnID: turn.id, proposals: skillProposals) }
            if let error = turn.errorMessage { Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: StudyRocketTheme.bodySize)).foregroundStyle(.orange).padding(.leading, 42) }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
                Text(message.text)
                    .font(.system(size: StudyRocketTheme.bodySize))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: min(600, canvasWidth * 0.7), alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).foregroundStyle(.white)
                    .contextMenu { Button("复制", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) } }
                HStack(spacing: 5) {
                    if let state = message.turnState, state != .completed { Text(state == .interrupted ? "已中断" : state == .failed ? "未完成" : "进行中") }
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                        .opacity(showTime ? 1 : 0)
                        .accessibilityHidden(!showTime)
                }
                .font(.caption2).foregroundStyle(.secondary)
                .frame(minHeight: 16, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { showTime = $0 }
    }
}

struct AssistantMessageView: View {
    let message: ChatMessage
    var body: some View {
        HStack(alignment: .assistantFirstLine, spacing: 10) {
            StudyRocketAvatar(size: 26)
                .alignmentGuide(.assistantFirstLine) { dimensions in dimensions[VerticalAlignment.center] }
            VStack(alignment: .leading, spacing: 6) {
                if message.isStreaming {
                Text(message.text)
                    .font(.system(size: StudyRocketTheme.bodySize))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: StudyRocketTheme.readingMaxWidth, alignment: .leading)
                } else {
                    CachedAssistantMarkdown(messageID: message.id, text: message.text)
                        .frame(maxWidth: StudyRocketTheme.readingMaxWidth, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                    Button("复制", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("复制回答")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .alignmentGuide(.assistantFirstLine) { dimensions in
                dimensions[.firstTextBaseline] - 6
            }
            Spacer(minLength: 0)
        }
    }
}

private struct CachedAssistantMarkdown: View {
    let messageID: String
    let text: String
    @State private var document: ChatMarkdownDocument?
    private static let cache = ChatMarkdownCache()

    init(messageID: String, text: String) {
        self.messageID = messageID
        self.text = text
    }

    var body: some View {
        Group {
            if let document {
                ChatMarkdownDocumentView(document: document)
            } else {
                // Keep the completed text visible while the one-time parse is
                // prepared; a slow parser must never create a white bubble.
                Text(text)
                    .font(.system(size: StudyRocketTheme.bodySize))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: "\(messageID):\(ChatMarkdownCache.exactTextHash(text))") {
            document = await Self.cache.document(for: messageID, text: text)
        }
    }
}

private struct ChatMarkdownDocumentView: View {
    let document: ChatMarkdownDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let content): inlineText(content).font(.system(size: StudyRocketTheme.bodySize)).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let content):
            inlineText(content)
                .font(.system(size: level <= 2 ? 20 : 17, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        case .quote(let blocks):
            ChatMarkdownDocumentView(document: ChatMarkdownDocument(blocks: blocks))
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 3) }
        case .bulletedList(let items):
            VStack(alignment: .leading, spacing: 5) { ForEach(Array(items.enumerated()), id: \.offset) { _, item in HStack(alignment: .top, spacing: 7) { Text("•"); inlineText(item) } } }
        case .numberedList(let start, let items):
            VStack(alignment: .leading, spacing: 5) { ForEach(Array(items.enumerated()), id: \.offset) { offset, item in HStack(alignment: .top, spacing: 7) { Text("\(start + offset)."); inlineText(item) } } }
        case .taskList(let items):
            VStack(alignment: .leading, spacing: 5) { ForEach(Array(items.enumerated()), id: \.offset) { _, item in HStack(alignment: .top, spacing: 7) { Image(systemName: item.checked ? "checkmark.square.fill" : "square").foregroundStyle(item.checked ? .secondary : .primary); inlineText(item.content).strikethrough(item.checked, color: .secondary) } } }
        case .codeBlock(let language, let code):
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 5) { if let language { Text(language).font(.caption2).foregroundStyle(.secondary) }; Text(code).font(.system(size: 13, design: .monospaced)).textSelection(.enabled) }
                    .padding(11)
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .table(let headers, let rows): tableView(headers: headers, rows: rows)
        case .divider: Divider()
        }
    }

    private func tableView(headers: [[ChatMarkdownInline]], rows: [[[ChatMarkdownInline]]]) -> some View {
        let columnCount = max(1, max(headers.count, rows.map(\.count).max() ?? 0))
        return ScrollView(.horizontal, showsIndicators: true) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { index in
                        cellView(index < headers.count ? headers[index] : [], emphasized: true)
                            .frame(width: 160)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { index in
                            cellView(index < row.count ? row[index] : [], emphasized: false)
                                .frame(width: 160)
                        }
                    }
                }
            }
            .fixedSize()
        }
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)) }
    }

    private func cellView(_ content: [ChatMarkdownInline], emphasized: Bool) -> some View {
        inlineText(content)
            .font(.system(size: 13, weight: emphasized ? .semibold : .regular))
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(emphasized ? Color.secondary.opacity(0.10) : Color.clear)
            .overlay(alignment: .trailing) { Rectangle().fill(Color.secondary.opacity(0.16)).frame(width: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Color.secondary.opacity(0.16)).frame(height: 1) }
    }

    private func inlineText(_ inlines: [ChatMarkdownInline]) -> Text {
        inlines.reduce(Text("") as Text) { result, inline in
            result + inlineText(inline)
        }
    }

    private func inlineText(_ inline: ChatMarkdownInline) -> Text {
        switch inline {
        case .text(let value): return Text(value)
        case .strong(let children): return inlineText(children).bold()
        case .emphasis(let children): return inlineText(children).italic()
        case .strikethrough(let children): return inlineText(children).strikethrough()
        case .code(let value): return Text(value).font(.system(size: 13, design: .monospaced)).foregroundColor(.accentColor)
        case .link(let children, _, _): return inlineText(children).underline().foregroundColor(.accentColor)
        case .lineBreak: return Text("\n")
        }
    }
}

struct ThinkingRow: View {
    let status: String
    var body: some View { HStack(spacing: 10) { StudyRocketAvatar(size: 28); ProgressView().controlSize(.small); Text(status == "重连中..." ? "连接波动，Codex 正在重试" : "正在读取资料").font(.system(size: StudyRocketTheme.bodySize)).foregroundStyle(.secondary) }.accessibilityLabel(status) }
}

struct ProcessDisclosureView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let turnID: String
    let messages: [ChatMessage]
    let expanded: Bool
    let toggle: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if reduceMotion { toggle() }
                else { withAnimation(.easeInOut(duration: 0.18)) { toggle() } }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: "waveform.path.ecg")
                    Text(expanded ? "收起过程" : "查看过程（\(messages.count)）")
                    Spacer()
                }.font(.system(size: StudyRocketTheme.bodySize, weight: .medium)).foregroundStyle(.secondary).frame(minHeight: 44).padding(.horizontal, 12)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(expanded ? "收起过程，\(messages.count) 条" : "查看过程，\(messages.count) 条").accessibilityHint("双击展开或收起该回合的过程消息")
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { message in
                        CachedAssistantMarkdown(messageID: message.id, text: message.text)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 14)
                    }
                }
                .padding(.bottom, 4)
            }
        }.padding(.leading, 36).frame(maxWidth: StudyRocketTheme.readingMaxWidth + 36, alignment: .leading)
    }
}

struct InlineProposalPanel: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var chat: StudyChatStore
    let turnID: String
    let proposals: [MarkdownChangeProposal]
    let expanded: Bool
    let toggle: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { toggle() } label: {
                HStack { Image(systemName: expanded ? "chevron.down" : "chevron.right"); Label("待确认修改（\(proposals.count)）", systemImage: "doc.badge.gearshape"); Spacer(); Text(proposals.first?.reason ?? "").lineLimit(1).foregroundStyle(.secondary) }
                    .font(.system(size: StudyRocketTheme.bodySize, weight: .medium))
                    .frame(minHeight: 44)
                    .padding(.horizontal, 12)
                    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.orange.opacity(0.24)) }
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(expanded ? "收起待确认修改" : "查看待确认修改")
            if expanded {
            ForEach(proposals) { proposal in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Toggle("", isOn: Binding(get: { proposal.isSelected }, set: { chat.setProposal(proposal.id, selected: $0) })).labelsHidden()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(proposal.relativePath).font(.system(size: StudyRocketTheme.bodySize, weight: .semibold))
                            Text(proposal.reason).font(.system(size: StudyRocketTheme.bodySize)).foregroundStyle(.secondary)
                            Text("应用前会再次检查文件是否被外部修改").font(.system(size: StudyRocketTheme.bodySize)).foregroundStyle(.orange)
                        }
                    }
                    DisclosureGroup("查看差异") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("原文").font(.system(size: StudyRocketTheme.bodySize, weight: .bold)).foregroundStyle(.secondary)
                            Text(proposal.originalContent.isEmpty ? "（空文件）" : proposal.originalContent)
                                .font(.system(size: StudyRocketTheme.bodySize, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                            Text("候选正文").font(.system(size: StudyRocketTheme.bodySize, weight: .bold)).foregroundStyle(.secondary)
                            Text(proposal.proposedContent.isEmpty ? "（空文件）" : proposal.proposedContent)
                                .font(.system(size: StudyRocketTheme.bodySize, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                        }.padding(.top, 4)
                    }.font(.system(size: StudyRocketTheme.bodySize))
                }.padding(.vertical, 4)
            }
            HStack {
                Spacer()
                Button("应用已选修改") { chat.applySelectedChanges(workspace: workspace, for: turnID) }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
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
                .font(.system(size: StudyRocketTheme.bodySize, weight: .semibold)).foregroundStyle(.orange)
            ForEach(proposals) { proposal in
                VStack(alignment: .leading, spacing: 3) {
                    Text(proposal.relativePath).font(.system(size: StudyRocketTheme.bodySize, weight: .semibold))
                    Text(proposal.reason).font(.system(size: StudyRocketTheme.bodySize)).foregroundStyle(.secondary)
                    Text("只在确认后写入；应用前会再次检查内容是否变更。")
                        .font(.system(size: StudyRocketTheme.bodySize)).foregroundStyle(.orange)
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
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(ReminderRoute.allCases) { route in Button(route.title) { prepare(route.prompt) }.buttonStyle(.borderless).font(.caption) }
                    Button("学业答疑") { prepare("我有一个学业问题，请先读取我的档案和相关航线再回答。") }.buttonStyle(.borderless).font(.caption)
                    Spacer()
                }
                Menu("快捷报告") {
                    ForEach(ReminderRoute.allCases) { route in Button(route.title) { prepare(route.prompt) } }
                    Button("学业答疑") { prepare("我有一个学业问题，请先读取我的档案和相关航线再回答。") }
                }.font(.caption)
            }.foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 10) {
                TextField("输入问题或今天完成的事实…", text: $chat.draft, axis: .vertical).lineLimit(2...8).font(.body).textFieldStyle(.plain).padding(11)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.quaternary))
                    .focused($inputFocused)
                    .onSubmit(submit)
                    .onExitCommand { inputFocused = false }
                if chat.isBusy { StudyIconButton(systemImage: "stop.fill", label: "停止生成", action: chat.stop) }
                else { StudyIconButton(systemImage: "arrow.up", label: "发送（Return）", action: submit, disabled: chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            Text("使用当前 Codex 登录和只读学业任务；修改会先生成草案。Shift+Return 换行。") .font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: StudyRocketTheme.chatMaxWidth).frame(maxWidth: .infinity).padding(.horizontal, StudyRocketTheme.pageInset).padding(.vertical, 10).background(.bar)
    }

    private func prepare(_ prompt: String) {
        chat.prepare(prompt: prompt)
        inputFocused = true
    }

    private func submit() {
        guard !chat.isBusy, !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        chat.send()
        inputFocused = false
    }
}

struct ChatHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { VStack(alignment: .leading, spacing: 12) { Text("学业对话帮助").font(.title2.weight(.semibold)); Text("这里连接的是独立的 StudyRocket 学业助理任务，当前应用开发对话不会被带入。你可以直接输入事实或问题，也可以使用快捷报告。遇到进度受阻时，助理会先用一句简短的话承接，再落到一个可执行的下一步或降级方案。"); Text("修改计划请在 StudyRocket 内发送；Codex 历史页直接续聊无法接收本应用的草案工具。涉及文件修改时，助理只生成草案；点击应用按钮后才写入 Markdown。学校规则、推免名额、截止日期等未知信息会标记为【待核实】，不会用猜测填充。情绪只用于当轮沟通，不会写入每日账或习惯画像。").foregroundStyle(.secondary); Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(24).frame(width: 440, height: 340) }
}

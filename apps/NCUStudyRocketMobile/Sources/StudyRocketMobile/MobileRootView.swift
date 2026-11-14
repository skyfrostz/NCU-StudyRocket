import Foundation
import MarkdownUI
import StudyRocketShared
import SwiftUI

public struct StudyRocketMobileRoot: View {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var session: MobileSession
  @State private var selectedTab = 0
  @State private var showFact = false
  private func navigate(_ destination: Int) {
    if destination == 4 { showFact = true } else { showFact = false; selectedTab = destination }
  }
  #if os(iOS)
    @StateObject private var reminders = MobileReminderScheduler.shared
  #endif

  #if os(iOS)
    private var recordedDays: Set<String> {
      var days = Set((session.snapshot?.recentFacts ?? []).map(\.date) + session.pendingFacts.map(\.date))
      if let old = session.snapshot?.daily,
         [old.deliverables, old.studyTime, old.sleep, old.exercise, old.firstTask].contains(where: { !$0.isEmpty }) {
        days.insert(old.date)
      }
      return days
    }
  #endif

  public init(session: MobileSession = MobileSession()) {
    _session = StateObject(wrappedValue: session)
  }

  public var body: some View {
    TabView(selection: $selectedTab) {
      MobileHomeView(session: session) { navigate($0) }
        .tabItem { StudyLabel("首页", systemImage: "house") }
        .tag(0)
      MobileChatView(session: session)
        .tabItem { StudyLabel("对话", systemImage: "bubble.left.and.bubble.right.fill") }
        .tag(1)
      MobileTimetableView(session: session)
        .tabItem { StudyLabel("课表", systemImage: "calendar") }
        .tag(2)
      MobilePlanView(session: session) { navigate($0) }
        .tabItem { StudyLabel("计划", systemImage: "checklist") }
        .tag(3)
      MobileMoreView(session: session) { showFact = true }
        .tabItem { StudyLabel("更多", systemImage: "ellipsis.circle") }
        .tag(5)
    }
    .sheet(isPresented: $showFact) { MobileDailyView(session: session) }
    .tint(MobileTheme.brand)
    .studyTypography()
    .onOpenURL { url in
      guard let destination = MobileWidgetDestination.parse(url) else { return }
      navigate(destination.tabIndex)
    }
    #if os(iOS)
      .task { await reminders.updateRecords(recordedDays) }
      .onChange(of: recordedDays) { _, days in Task { await reminders.updateRecords(days) } }
      .onChange(of: reminders.pendingRoute, initial: true) { _, route in
        guard let route else { return }
        if route == .daily { showFact = true; NotificationCenter.default.post(name: .focusStudyFact, object: nil) }
        else { selectedTab = 1; if session.inputDraft.isEmpty { session.inputDraft = route.prompt } }
        _ = reminders.takePendingRoute()
      }
    #endif
    .task { if scenePhase == .active { await session.enterForeground() } }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active:
        session.foregroundDidChange(isActive: true)
        #if os(iOS)
        Task { await reminders.updateRecords(recordedDays) }
        #endif
      case .background, .inactive:
        session.foregroundDidChange(isActive: false)
      @unknown default:
        break
      }
    }
    .sheet(
      isPresented: Binding(
        get: { session.legacyPendingReview != nil },
        set: { isPresented in
          if !isPresented { session.deferLegacyPendingReview() }
        }
      )
    ) {
      if let review = session.legacyPendingReview {
        MobileLegacyPendingReviewSheet(session: session, review: review)
      }
    }
  }
}

private struct MobileLegacyPendingReviewSheet: View {
  @ObservedObject var session: MobileSession
  let review: MobileLegacyPendingReview
  @Environment(\.dismiss) private var dismiss
  @State private var selectedIDs: Set<String>
  @State private var isApplying = false
  @State private var showDiscardConfirmation = false

  init(session: MobileSession, review: MobileLegacyPendingReview) {
    self.session = session
    self.review = review
    _selectedIDs = State(initialValue: review.selectableIDs)
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("这些操作来自旧版手机缓存。请确认后再写入正式仓库；任务已变化的项目不会自动同步。")
            .studyTypography(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Section("待确认操作") {
          ForEach(review.items) { item in
            Button {
              guard item.canSync else { return }
              if selectedIDs.contains(item.id) {
                selectedIDs.remove(item.id)
              } else {
                selectedIDs.insert(item.id)
              }
            } label: {
              HStack(alignment: .top, spacing: 12) {
                Image(
                  systemName: item.canSync
                    ? (selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    : "exclamationmark.circle.fill"
                )
                .foregroundStyle(item.canSync ? MobileTheme.brand : Color.orange)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                  Text(item.title)
                    .studyTypography(.subheadline, weight: .medium)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                  Text(item.detail)
                    .studyTypography(.caption)
                    .foregroundStyle(item.canSync ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!item.canSync || isApplying)
            .accessibilityLabel("\(item.kind == .delivery ? "交付物" : "时段")，\(item.title)")
            .accessibilityValue(
              item.canSync
                ? (selectedIDs.contains(item.id) ? "已选择，\(item.detail)" : "未选择，\(item.detail)")
                : "任务已变化，无法同步")
          }
        }
        Section {
          MobilePrimaryButton(
            title: isApplying ? "正在同步" : "同步所选项目", symbol: "arrow.triangle.2.circlepath"
          ) {
            isApplying = true
            Task {
              await session.applyLegacyPendingReview(selectedIDs: selectedIDs)
              isApplying = false
              dismiss()
            }
          }
          .disabled(selectedIDs.isEmpty || isApplying)
          StudyButton("全部丢弃", role: .destructive) {
            showDiscardConfirmation = true
          }
          .disabled(isApplying)
        } footer: {
          Text("未选项目会从本机旧队列中移除；周计划正文和日结草稿不受影响。")
        }
      }
      .navigationTitle("旧版待同步操作")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          StudyButton("暂不处理") {
            session.deferLegacyPendingReview()
            dismiss()
          }
          .disabled(isApplying)
        }
      }
      .confirmationDialog(
        "丢弃全部旧版操作？", isPresented: $showDiscardConfirmation, titleVisibility: .visible
      ) {
        StudyButton("全部丢弃", role: .destructive) {
          session.discardLegacyPendingToggles()
          dismiss()
        }
        StudyButton("取消", role: .cancel) {}
      } message: {
        Text("只会删除这些尚未写入正式仓库的旧版勾选操作，无法撤销。")
      }
      .interactiveDismissDisabled(isApplying)
    }
  }
}

private struct MobileStatusBanner: View {
  @ObservedObject var session: MobileSession

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      MobileConnectionPill(state: session.state)
      if session.chatUnavailableMessage != nil {
        Text("对话未就绪")
          .studyTypography(.caption2, weight: .medium)
          .foregroundStyle(.orange)
      }
    }
  }
}

private struct MobileSnapshotFreshness: View {
  @ObservedObject var session: MobileSession

  @ViewBuilder
  var body: some View {
    if let snapshot = session.snapshot, session.state != .online {
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: "icloud.slash")
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
        Text(statusText(for: snapshot.fetchedAt))
          .studyTypography(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Button {
          Task { await session.refresh() }
        } label: {
          Image(systemName: "arrow.clockwise")
            .studyTypography(.body, weight: .semibold)
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .disabled(session.state == .connecting)
        .accessibilityLabel("刷新数据")
      }
      .padding(10)
      .background(
        Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(Color.orange.opacity(0.25))
      }
      .accessibilityElement(children: .combine)
    }
  }

  private func statusText(for fetchedAt: Date) -> String {
    let prefix = session.state == .connecting ? "正在刷新，缓存于" : "离线缓存，更新于"
    return "\(prefix) \(Self.timestampFormatter.string(from: fetchedAt))"
  }

  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "M月d日 HH:mm"
    return formatter
  }()
}

private struct HomeScheduleSection<Content: View>: View {
  let isEmpty: Bool
  @ViewBuilder let content: Content
  @State private var expanded = false

  var body: some View {
    MobileSurface {
      VStack(alignment: .leading, spacing: 14) {
        if isEmpty {
          Button {
            expanded.toggle()
          } label: {
            HStack {
              StudyLabel("今日安排", systemImage: "point.3.connected.trianglepath.dotted").studyTypography(.headline)
              Spacer()
              Text("暂无安排").studyTypography(.subheadline)
              Image(systemName: expanded ? "chevron.down" : "chevron.right").studyTypography(.caption)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityValue(expanded ? "已展开" : "已折叠")
        } else {
          MobileSectionHeading(title: "今日安排", icon: "point.3.connected.trianglepath.dotted")
        }
        if !isEmpty || expanded { content }
      }
    }
    .onChange(of: isEmpty) { _, _ in expanded = false }
  }
}

private struct MobileHomeView: View {
  @ObservedObject var session: MobileSession
  let onNavigate: (Int) -> Void
  @State private var deliveryChapter = MobileDeliveryChapterState()
  @State private var deliveryChapterTask: Task<Void, Never>?
  @State private var periodTargets: [String: Bool] = [:]
  @State private var periodTasks: [String: Task<Void, Never>] = [:]
  @State private var deliveryNotice: String?
  @State private var deliveryConfirmation: DeliverySnapshot?
  @State private var confirmedChildIDs: [String] = []
  @State private var homeClockAnchor = Date.now
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
    .confirmationDialog("将一并完成这些子任务", isPresented: Binding(get: { deliveryConfirmation != nil }, set: { if !$0 { deliveryConfirmation = nil } }), titleVisibility: .visible) {
      if let delivery = deliveryConfirmation {
        StudyButton("确认全部完成") { deliveryConfirmation = nil; submitDeliveryToggle(delivery, confirmedTaskIDs: confirmedChildIDs) }
      }
      StudyButton("取消", role: .cancel) { deliveryConfirmation = nil }
    } message: {
      Text(deliveryConfirmation.map { session.snapshot?.week.linkage?.pendingChildren(of: $0.id).map(\.text).joined(separator: "\n") ?? "" } ?? "")
    }
    .onAppear { synchronizeDeliveryChapter() }
    .onChange(of: session.snapshot?.revision) { _, _ in synchronizeDeliveryChapter() }
    .onChange(of: session.pendingDeliveryCount) { _, _ in synchronizeDeliveryChapter() }
    .onChange(of: session.repositoryGeneration) { _, _ in
      deliveryChapterTask?.cancel()
      deliveryChapterTask = nil
      synchronizeDeliveryChapter()
    }
  }

  private var unconfiguredContent: some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          homeHeader
          MobileDailyVerseView()
          MobileStatusBanner(session: session)
          quickActions
          Spacer(minLength: 24)
          MobileUnframedConnectionPrompt { onNavigate(5) }
            .frame(maxWidth: .infinity)
          Spacer(minLength: 24)
        }
        .frame(minHeight: max(0, proxy.size.height - 2 * MobileTheme.pageInset), alignment: .top)
        .padding(MobileTheme.pageInset)
      }
    }
  }

  private var homeContent: some View {
    ScrollView {
      TimelineView(.periodic(from: homeClockAnchor, by: 60)) { context in
        VStack(alignment: .leading, spacing: 18) {
          homeHeader
          MobileDailyVerseView()
          MobileStatusBanner(session: session)
          MobileSnapshotFreshness(session: session)
          if let message = session.chatUnavailableMessage {
            MobileInlineNotice(
              text: message, symbol: "bubble.left.and.exclamationmark", tint: .orange)
          }
          if let issue = session.pendingToggleSyncIssue {
            MobileInlineNotice(
              text: issue,
              symbol: "exclamationmark.arrow.triangle.2.circlepath",
              tint: .orange
            )
          }
          if let snapshot = session.snapshot {
            let home = snapshot.home
            let todayDayID = todayDayID(for: home)
            let focus = todayFocus(for: home, dayID: todayDayID, now: context.date)
            MobileSurface {
              VStack(alignment: .leading, spacing: 12) {
                MobileSectionHeading(title: "现在先做什么", detail: focus.progressLabel, icon: "scope")
                switch focus {
                case .task(let task, _, _):
                  Text(task)
                    .studyTypography(.title3, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                  Button {
                    onNavigate(1)
                  } label: {
                    StudyLabel("和学业助理确认下一步", systemImage: "arrow.right")
                      .studyTypography(.subheadline, weight: .medium)
                      .frame(minHeight: 44)
                      .contentShape(Rectangle())
                  }
                  .buttonStyle(.borderless)
                case .completed:
                  StudyLabel("今日安排已完成", systemImage: "checkmark.seal.fill")
                    .studyTypography(.title3, weight: .semibold)
                    .foregroundStyle(MobileTheme.completion)
                    .frame(minHeight: 44, alignment: .leading)
                case .unplanned:
                  MobileInlineNotice(text: "今日尚未安排首要任务，可在周计划中补充。", symbol: "calendar.badge.plus")
                }
              }
            }

            let day = snapshot.week.days.first { $0.id == todayDayID }
            let today = DaySnapshot(id: todayDayID ?? home.dateLabel, dateLabel: home.dateLabel,
                                    slots: home.periods, unassigned: day?.unassigned ?? "")
            let emptyDay = session.isEmptyPlanDay(today)
            let displayPeriods = session.snapshot?.week.linkage == nil ? home.periods : home.periods.map { period in
              let open = period.tasks.filter { !session.effectiveTaskCompletion(dayID: todayDayID ?? home.dateLabel, period: period, task: $0) }
              return PeriodSnapshot(id: period.id, title: period.title, text: open.map(\.text).joined(separator: "\n"), tasks: open)
            }
            let visiblePeriods = emptyDay ? displayPeriods : displayPeriods.filter { !$0.tasks.isEmpty }
            HomeScheduleSection(isEmpty: emptyDay) {
              if !visiblePeriods.isEmpty {
                MobileTodayChecklist(
                  periods: visiblePeriods,
                  canToggle: todayDayID != nil,
                  completion: { period, task in
                    effectiveTaskCompletion(for: period, task: task, home: home, dayID: todayDayID)
                  },
                  isPending: { period, task in
                    guard let todayDayID else { return false }
                    return periodTargets[taskKey(dayID: todayDayID, periodID: period.id, taskID: task.id)] != nil
                      || session.isTaskTogglePending(dayID: todayDayID, period: period, task: task)
                  },
                  canCancelPending: { period, task in
                    guard let todayDayID else { return false }
                    return periodTargets[taskKey(dayID: todayDayID, periodID: period.id, taskID: task.id)] != nil
                      || session.canCancelPendingTask(dayID: todayDayID, period: period, task: task)
                  },
                  pendingLabel: { period, task in
                    guard let todayDayID,
                      periodTargets[taskKey(dayID: todayDayID, periodID: period.id, taskID: task.id)] == nil
                    else { return nil }
                    return pendingStatusLabel(isLegacy: false)
                  },
                  hasLegacyPending: { period in
                    guard let todayDayID else { return false }
                    return session.isLegacyPeriodTogglePending(dayID: todayDayID, period: period)
                  },
                  onToggle: { period, task in
                    guard let todayDayID else { return }
                    requestTaskToggle(dayID: todayDayID, period: period, task: task)
                  }
                )
              }
              let unassigned = PeriodTaskParser.tasks(from: today.unassigned)
              if !unassigned.isEmpty {
                Text("待分时").studyTypography(.subheadline, weight: .semibold)
                ForEach(unassigned) { task in
                  StudyLabel(task.text, systemImage: "tray").studyTypography(.subheadline)
                }
                StudyButton("去周计划安排", action: { onNavigate(3) })
              }
              if !emptyDay && visiblePeriods.isEmpty && unassigned.isEmpty {
                StudyLabel("今天有待同步的安排", systemImage: "arrow.triangle.2.circlepath")
                  .studyTypography(.subheadline).foregroundStyle(.secondary)
              }
              if let issue = session.lastConnectionIssue, session.state != .online {
                MobileInlineNotice(
                  text: issue,
                  symbol: "exclamationmark.arrow.triangle.2.circlepath",
                  tint: .orange
                )
              }
            }
            .id("\(session.repositoryGeneration)-\(today.id)")

            MobileSurface {
              VStack(alignment: .leading, spacing: 10) {
                MobileSectionHeading(title: "本周交付物", detail: "未完成及本周完成", icon: "checklist")
                if let deliveryNotice {
                  MobileInlineNotice(text: deliveryNotice, symbol: "link.badge.plus", tint: .orange)
                }
                MobileDeliveryOverview(
                  deliveries: session.currentWeekDeliveries(at: context.date),
                  phase: deliveryChapter.phase,
                  completion: { delivery in
                    isLocallyCompleting(delivery) || session.effectiveDeliveryCompletion(delivery)
                  },
                  isPending: session.isDeliveryTogglePending,
                  canCancelPending: {
                    session.canCancelPendingDelivery($0)
                      || session.isLegacyDeliveryTogglePending($0)
                  },
                  pendingLabel: {
                    pendingStatusLabel(isLegacy: session.isLegacyDeliveryTogglePending($0))
                  },
                  pendingSyncState: pendingTogglePresentation,
                  onPendingAction: {
                    if session.legacyPendingToggleCount > 0 {
                      session.presentLegacyPendingReview()
                    } else {
                      Task { await session.retryPendingToggles() }
                    }
                  },
                  onToggle: requestDeliveryToggle
                )
              }
            }
            MobileTimetableCard(
              snapshot: home.timetable,
              isOffline: session.state != .online,
              cachedAt: snapshot.fetchedAt
            )
          } else {
            MobileSurface {
              VStack(alignment: .leading, spacing: 14) {
                MobileInlineNotice(
                  text: session.lastConnectionIssue
                    ?? "暂时无法连接学业服务，请检查网络并刷新；待提交草稿仍保留。",
                  symbol: "wifi.exclamationmark",
                  tint: .orange
                )
                HStack {
                  StudyButton("刷新") { Task { await session.refresh() } }
                  StudyButton("检查连接设置") { onNavigate(5) }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
              }
            }
          }

          quickActions
        }
        .padding(MobileTheme.pageInset)
        .safeAreaPadding(.bottom, 8)
        .onChange(of: PlanningDate.key(context.date)) { _, _ in Task { await session.refreshVisibleContent() } }
      }
    }
    .refreshable { await session.refreshVisibleContent() }
  }

  private var homeHeader: some View {
    HStack(alignment: .top, spacing: 12) {
      MobileBrandMark(size: 46)
      VStack(alignment: .leading, spacing: 3) {
        Text("NCU StudyRocket")
          .studyTypography(.title2, weight: .bold)
          .fixedSize(horizontal: false, vertical: true)
        homeDateLabel
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var homeDateLabel: some View {
    Text(session.snapshot?.home.dateLabel ?? "你的学习工作台")
      .studyTypography(.subheadline)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var quickActions: some View {
    let accessible = dynamicTypeSize.isAccessibilitySize
    let layout = accessible ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 8))
    return layout {
      MobileQuickAction(title: "学业对话", symbol: "bubble.left.and.bubble.right", isWide: accessible, action: { onNavigate(1) })
      MobileQuickAction(title: "周计划", symbol: "calendar", isWide: accessible, action: { onNavigate(3) })
      MobileQuickAction(title: "记一件事", symbol: "square.and.pencil", isWide: accessible, action: { onNavigate(4) })
    }
  }

  private var pendingTogglePresentation: MobilePendingTogglePresentation {
    if session.isReplayingPendingToggles { return .replaying }
    if session.legacyPendingToggleCount > 0 { return .legacyReview }
    if session.pendingToggleSyncIssue != nil { return .blocked }
    if session.pendingDeliveryCount > 0 {
      return session.state == .online ? .waiting : .offline
    }
    return .none
  }

  private func pendingStatusLabel(isLegacy: Bool) -> String {
    if isLegacy { return "待确认" }
    if session.isReplayingPendingToggles { return "正在同步" }
    if session.pendingToggleSyncIssue != nil { return "同步未完成" }
    return session.state == .online ? "等待同步" : "等待连接"
  }

  private func todayDayID(for home: HomeSnapshot) -> String? {
    guard let days = session.snapshot?.week.days else { return nil }
    if let exact = days.first(where: { $0.dateLabel == home.dateLabel }) { return exact.id }
    return days.first(where: { $0.id == Self.todayIDFormatter.string(from: .now) })?.id
  }

  private func todayFocus(for home: HomeSnapshot, dayID: String?, now: Date) -> MobileTodayFocus {
    MobileTodayFocus.resolve(periods: home.periods, timetable: home.timetable, now: now) { period, task in
      effectiveTaskCompletion(for: period, task: task, home: home, dayID: dayID)
    }
  }

  private func effectiveTaskCompletion(
    for period: PeriodSnapshot,
    task: PeriodTaskSnapshot,
    home: HomeSnapshot,
    dayID: String?
  ) -> Bool {
    if let dayID, let target = periodTargets[taskKey(dayID: dayID, periodID: period.id, taskID: task.id)] {
      return target
    }
    let deliveries = session.snapshot?.week.deliveries ?? home.visibleDeliveries
    if deliveries.contains(where: { delivery in
      isLocallyCompleting(delivery)
        && (session.snapshot?.week.linkage != nil || Self.dateNumbers(in: delivery.dateLabel ?? "") == Self.dateNumbers(in: home.dateLabel))
        && matchingTaskKeys(for: delivery).contains(taskMatchKey(periodID: period.id, taskID: task.id))
    }) {
      return true
    }
    guard let dayID else { return task.isCompleted }
    return session.effectiveTaskCompletion(dayID: dayID, period: period, task: task)
  }

  private func requestDeliveryToggle(_ delivery: DeliverySnapshot) {
    if !session.effectiveDeliveryCompletion(delivery), !session.isDeliveryTogglePending(delivery),
       let children = session.snapshot?.week.linkage?.pendingChildren(of: delivery.id), !children.isEmpty {
      confirmedChildIDs = children.map(\.id)
      deliveryConfirmation = delivery
      return
    }
    submitDeliveryToggle(delivery)
  }

  private func submitDeliveryToggle(_ delivery: DeliverySnapshot, confirmedTaskIDs: [String]? = nil) {
    if case .striking(let mutation) = deliveryChapter.phase,
      mutation.deliveryID == delivery.id
    {
      deliveryChapterTask?.cancel()
      deliveryChapterTask = nil
      _ = deliveryChapter.undo(mutation)
      return
    }

    if session.isDeliveryTogglePending(delivery) {
      if session.isLegacyDeliveryTogglePending(delivery) {
        session.presentLegacyPendingReview()
      } else if session.canCancelPendingDelivery(delivery) {
        session.cancelPendingDelivery(delivery)
      }
      return
    }

    guard !session.effectiveDeliveryCompletion(delivery),
      let mutation = deliveryChapter.begin(deliveryID: delivery.id)
    else { return }
    deliveryNotice = nil
    let completesAll =
      !(session.snapshot?.week.deliveries ?? []).isEmpty
      && (session.snapshot?.week.deliveries ?? []).allSatisfy {
        $0.id == delivery.id || session.effectiveDeliveryCompletion($0)
      }
    deliveryChapterTask = Task { @MainActor in
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        return
      }
      guard deliveryChapter.finishStrike(mutation) == .submit(mutation) else { return }
      let result = await session.toggleDelivery(delivery, isCompleted: true, mutation: mutation, confirmedTaskIDs: confirmedTaskIDs)
      guard !Task.isCancelled else { return }
      deliveryChapter.resolve(
        result,
        for: mutation,
        queuedOfflineCompletesAll: completesAll
      )

      switch result {
      case .confirmed:
        break
      case .failed(let message):
        deliveryNotice = message
      case .queuedOffline, .staleGeneration:
        break
      }

      guard deliveryChapter.phase == .sealing(mutation) else {
        deliveryChapterTask = nil
        synchronizeDeliveryChapter()
        return
      }
      await finishDeliverySeal(mutation)
      deliveryChapterTask = nil
    }
  }

  private func isLocallyCompleting(_ delivery: DeliverySnapshot) -> Bool {
    switch deliveryChapter.phase {
    case .striking(let mutation), .awaitingConfirmation(let mutation):
      return mutation.deliveryID == delivery.id
    case .list, .sealing, .completed:
      return false
    }
  }

  private func synchronizeDeliveryChapter() {
    let deliveries = session.snapshot?.week.deliveries ?? []
    deliveryChapter.synchronize(
      allAuthoritativelyCompleted: !deliveries.isEmpty && deliveries.allSatisfy(\.isCompleted),
      repositoryGeneration: session.repositoryGeneration,
      hasPendingDelivery: session.pendingDeliveryCount > 0
    )
    if case .sealing(let mutation) = deliveryChapter.phase,
      deliveryChapterTask == nil
    {
      deliveryChapterTask = Task { @MainActor in
        await finishDeliverySeal(mutation)
        deliveryChapterTask = nil
      }
    }
  }

  private func finishDeliverySeal(_ mutation: MobileDeliveryMutation) async {
    do {
      try await Task.sleep(for: reduceMotion ? .milliseconds(200) : .milliseconds(800))
    } catch {
      return
    }
    if deliveryChapter.finishSeal(mutation) == .announceCompletion {
      MobileAccessibility.notifyWeeklyDeliveriesCompleted()
    }
  }

  private func requestTaskToggle(
    dayID: String,
    period: PeriodSnapshot,
    task: PeriodTaskSnapshot
  ) {
    let key = taskKey(dayID: dayID, periodID: period.id, taskID: task.id)
    if let task = periodTasks.removeValue(forKey: key) {
      task.cancel()
      periodTargets.removeValue(forKey: key)
      return
    }
    if session.isLegacyPeriodTogglePending(dayID: dayID, period: period) {
      session.presentLegacyPendingReview()
      return
    }
    if session.isTaskTogglePending(dayID: dayID, period: period, task: task) {
      if session.canCancelPendingTask(dayID: dayID, period: period, task: task) {
        session.cancelPendingTask(dayID: dayID, period: period, task: task)
      }
      return
    }
    let target =
      !(session.snapshot.map { effectiveTaskCompletion(for: period, task: task, home: $0.home, dayID: dayID) }
      ?? session.effectiveTaskCompletion(dayID: dayID, period: period, task: task))
    periodTargets[key] = target
    periodTasks[key] = Task { @MainActor in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      periodTasks.removeValue(forKey: key)
      periodTargets.removeValue(forKey: key)
      await session.toggleTask(dayID: dayID, period: period, task: task, isCompleted: target)
    }
  }

  private func matchingTaskKeys(for delivery: DeliverySnapshot) -> Set<String> {
    guard let week = session.snapshot?.week else { return [] }
    if let graph = week.linkage {
      let ids = Set(graph.children(of: delivery.id).map(\.id))
      return Set(week.days.flatMap(\.slots).flatMap { period in
        period.tasks.filter { ids.contains($0.logicalTaskID ?? "") }.map { taskMatchKey(periodID: period.id, taskID: $0.id) }
      })
    }
    guard let dateLabel = delivery.dateLabel else { return [] }
    let rows =
      week.days.map { ($0.dateLabel, $0.slots) }
      + week.historicalRows.map { ($0.dateLabel, $0.slots) }
      + week.futureRows.map { ($0.dateLabel, $0.slots) }
    guard
      let slots = rows.first(where: {
        Self.dateNumbers(in: $0.0) == Self.dateNumbers(in: dateLabel)
      })?.1
    else { return [] }
    return Set(slots.flatMap { period in
      period.tasks.compactMap { task in
        DeliveryPeriodMatcher.matches(deliveryText: delivery.text, periodText: task.text)
          ? taskMatchKey(periodID: period.id, taskID: task.id)
          : nil
      }
    })
  }

  private func taskMatchKey(periodID: String, taskID: String) -> String {
    "\(periodID)|\(taskID)"
  }

  private func taskKey(dayID: String, periodID: String, taskID: String) -> String {
    "\(dayID)|\(periodID)|\(taskID)"
  }

  private func periodKey(dayID: String, periodID: String) -> String {
    "\(dayID)|\(periodID)"
  }

  private static func dateNumbers(in value: String) -> [Int] {
    Array(value.split { !$0.isNumber }.compactMap { Int($0) }.suffix(2))
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

private struct MobileTimetableCard: View {
  let snapshot: TimetableSnapshot?
  let isOffline: Bool
  let cachedAt: Date

  var body: some View {
    MobileSurface {
      VStack(alignment: .leading, spacing: 12) {
        MobileSectionHeading(
          title: "今日课程",
          detail: snapshot.map(headerDetail) ?? "课表",
          icon: "calendar.badge.clock"
        )

        if isOffline, let snapshot {
          MobileInlineNotice(
            text: "离线缓存：课表日期 \(snapshot.referenceDate)，快照于 \(cachedAtText) 获取。",
            symbol: "icloud.slash",
            tint: .orange
          )
        }

        if let snapshot {
          timetableContent(snapshot)
        } else {
          MobileInlineNotice(
            text: isOffline
              ? "当前离线缓存来自旧版协议，不含课表数据。连接学业服务后刷新。"
              : "学业服务 尚未返回课表数据，请刷新后重试。",
            symbol: "calendar.badge.exclamationmark",
            tint: .orange
          )
        }
      }
    }
  }

  @ViewBuilder
  private func timetableContent(_ snapshot: TimetableSnapshot) -> some View {
    switch snapshot.status {
    case .notImported:
      MobileInlineNotice(
        text: "尚未找到 261 一班课表，请在 Mac 资料库中确认课表 Markdown 已存在。",
        symbol: "calendar.badge.exclamationmark",
        tint: .orange
      )
    case .invalid:
      MobileInlineNotice(
        text: "课表文件格式有误，今日课程暂不可用。请检查 Mac 资料库中的课表文件。",
        symbol: "exclamationmark.triangle.fill",
        tint: .orange
      )
    case .beforeTerm:
      MobileInlineNotice(
        text: "课表已接入，课程从 \(dateText(snapshot.firstImportedDate)) 开始。",
        symbol: "calendar.badge.clock",
        tint: .secondary
      )
    case .afterTerm:
      MobileInlineNotice(
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
            MobileInlineNotice(text: entry.title, symbol: "sun.max.fill", tint: .orange)
              .padding(.bottom, entries.isEmpty ? 8 : 10)
          }
          if entries.isEmpty {
            StudyLabel(
              "今日无课程安排", systemImage: holidays.isEmpty ? "calendar" : "calendar.badge.checkmark"
            )
            .studyTypography(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          } else {
            ForEach(entries) { entry in
              MobileTimetableRow(entry: entry)
            }
          }
        }
      } else {
        MobileInlineNotice(
          text: "今日课程快照缺少对应日期，请刷新后重试。",
          symbol: "arrow.clockwise",
          tint: .orange
        )
      }
    }
  }

  private func headerDetail(_ snapshot: TimetableSnapshot) -> String {
    [snapshot.classLabel, snapshot.weekLabel].compactMap { $0 }.joined(separator: " · ")
  }

  private func dateText(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "待定日期" }
    return value
  }

  private var cachedAtText: String {
    Self.cacheDateFormatter.string(from: cachedAt)
  }

  private static let cacheDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "M月d日 HH:mm"
    return formatter
  }()
}

private struct MobileTimetableRow: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let entry: TimetableEntrySnapshot

  private var confirmedLocation: String? {
    let value = entry.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  private var confirmedInstructor: String? {
    let value = entry.instructor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  private var locationText: String? {
    confirmedLocation ?? (entry.kind == .course ? "地点待确认" : nil)
  }

  private var instructorText: String? {
    confirmedInstructor ?? (entry.kind == .course ? "教师待确认" : nil)
  }

  var body: some View {
    let title = StudyRocketTimetableCourseCatalog.displayTitle(for: entry.title)
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: entry.symbol)
        .studyTypography(.body, weight: .medium)
        .foregroundStyle(entry.kind == .course ? MobileTheme.brand : .secondary)
        .frame(width: 22, height: 22)
        .padding(.top, 1)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        (dynamicTypeSize.isAccessibilitySize
          ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
          : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 9))) {
          Text(entry.timeText)
            .studyTypography(.footnote, weight: .semibold)
            .foregroundStyle(.secondary)
          if let periodLabel = entry.periodLabel, !periodLabel.isEmpty {
            Text(entry.periodText(periodLabel))
              .studyTypography(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        Text(title.primary)
          .studyTypography(.body, weight: entry.kind == .course ? .medium : .regular)
          .foregroundStyle(entry.kind == .course ? .primary : .secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let secondary = title.secondary {
          Text(secondary)
            .studyTypography(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let location = locationText {
          StudyLabel(location, systemImage: "mappin.and.ellipse")
            .studyTypography(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let instructor = instructorText {
          StudyLabel(instructor, systemImage: "person")
            .studyTypography(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let note = entry.note, !note.isEmpty {
          Text(note)
            .studyTypography(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 8)
    .overlay(alignment: .bottom) {
      Divider().padding(.leading, 32)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(entry.accessibilityText)
  }
}

extension TimetableEntrySnapshot {
  fileprivate var symbol: String {
    switch kind {
    case .course: return "book.closed"
    case .support: return "questionmark.circle"
    case .officeHour: return "person.crop.circle"
    case .event: return "calendar.badge.clock"
    case .holiday: return "sun.max.fill"
    }
  }

  fileprivate var timeText: String {
    switch (startTime, endTime) {
    case (let start?, let end?): return "\(start) - \(end)"
    case (let start?, nil): return "\(start) 开始"
    case (nil, let end?): return "\(end) 结束"
    case (nil, nil): return "时间待定"
    }
  }

  fileprivate func periodText(_ value: String) -> String {
    value.contains("节") ? value : "第\(value)节"
  }

  fileprivate var accessibilityText: String {
    var values = [timeText, title]
    if let periodLabel, !periodLabel.isEmpty { values.append(periodText(periodLabel)) }
    let confirmedLocation = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let confirmedInstructor = instructor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !confirmedLocation.isEmpty {
      values.append(confirmedLocation)
    } else if kind == .course {
      values.append("地点待确认")
    }
    if !confirmedInstructor.isEmpty {
      values.append(confirmedInstructor)
    } else if kind == .course {
      values.append("教师待确认")
    }
    if let note, !note.isEmpty { values.append(note) }
    return values.joined(separator: "，")
  }
}

private enum MobileTimetableWeekNavigationDirection {
  case previous
  case next

  var insertionEdge: Edge {
    switch self {
    case .previous: .leading
    case .next: .trailing
    }
  }

  var removalEdge: Edge {
    switch self {
    case .previous: .trailing
    case .next: .leading
    }
  }
}

private struct MobileTimetableView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var showingAccessibleDatePicker = false
  @ObservedObject var session: MobileSession
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var detail: DocumentDetail?
  @State private var showEventEditor = false
  @State private var viewingDate = Date()
  @State private var availableWeekRange: ClosedRange<Int>?
  @State private var displayedSnapshot: TimetableSnapshot?
  @State private var selectedWeek = 1
  @State private var selectedDayID = ""
  @State private var agendaDayID = ""
  @State private var isLoading = false
  @State private var agendaNavigationDirection: MobileTimetableWeekNavigationDirection = .next

  private func weekDateRange(for days: [TimetableDaySnapshot]) -> String {
    guard let first = days.first, let last = days.last else { return "日期待定" }
    let firstDate = first.dateLabel.components(separatedBy: " · ").first ?? first.dateLabel
    let lastDate = last.dateLabel.components(separatedBy: " · ").first ?? last.dateLabel
    return "\(firstDate) - \(lastDate)"
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          MobileSurface {
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 12) {
                StudyLabel("查看日期", systemImage: "calendar")
                  .studyTypography(.subheadline, weight: .medium)
                Spacer(minLength: 8)
                viewingDatePicker
              }
              VStack(alignment: .leading, spacing: 10) {
                StudyLabel("查看日期", systemImage: "calendar")
                  .studyTypography(.subheadline, weight: .medium)
                viewingDatePicker
              }
            }
          }
          if let detail, let range = availableWeekRange, let snapshot = displayedSnapshot {
            timetableContent(detail: detail, range: range, snapshot: snapshot)
          } else if let detail {
            let schedule = StudyRocketTimetableParser.snapshot(from: detail.markdown, now: viewingDate)
            if schedule.days.contains(where: { !$0.entries.isEmpty }) {
              MobileTimetableDateStrip(days: schedule.days, selectedDayID: selectedDayID, todayID: schedule.referenceDate, onSelect: { selectDay($0) })
              MobileTimetableAgendaTransitionContainer(snapshot: schedule, displayedDayID: selectedDayID.isEmpty ? schedule.referenceDate : selectedDayID, direction: .next, reduceMotion: reduceMotion)
            } else { unavailableContent }
          } else if isLoading {
            ProgressView("正在读取课表")
              .frame(maxWidth: .infinity, minHeight: 260)
          } else {
            unavailableContent
          }
        }
        .padding(MobileTheme.pageInset)
      }
      .background(MobileTheme.groupedBackground)
      .sheet(isPresented: $showingAccessibleDatePicker) {
        NavigationStack {
          DatePicker("查看日期", selection: $viewingDate, displayedComponents: .date)
            #if os(iOS)
              .datePickerStyle(.wheel)
            #else
              .datePickerStyle(.graphical)
            #endif
            .labelsHidden()
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.calendar, PlanningDate.calendar)
            .environment(\.timeZone, PlanningDate.calendar.timeZone)
            .accessibilityLabel("查看日期")
            .padding()
            .navigationTitle("查看日期")
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                StudyButton("完成") { showingAccessibleDatePicker = false }
              }
            }
        }
        .presentationDetents([.medium, .large])
      }
      .sheet(isPresented: $showEventEditor) {
        if let detail {
          OneOffEventEditor(source: detail.markdown) { events in
            guard await session.saveEvents(events, original: detail.markdown) else {
              throw PlanningChangeRouter.RoutingError(session.pendingToggleSyncIssue ?? "活动未保存，预览已保留，请重试。")
            }
            await load()
          }
        }
      }
      .navigationTitle("课表")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          StudyButton("单次活动", systemImage: "calendar.badge.plus") { showEventEditor = true }
            .disabled(detail == nil || session.state != .online)
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task {
              await session.refresh()
              await load()
            }
          } label: {
            Image(systemName: "arrow.clockwise")
              .frame(width: 44, height: 44)
          }
          .disabled(isLoading)
          .accessibilityLabel("刷新课表")
        }
      }
    }
    .task(id: session.repositoryGeneration) {
      await load()
    }
    .onChange(of: session.documentDetails["timetable"]?.revision) { _, _ in
      guard let value = session.documentDetails["timetable"] else { return }
      accept(value, selectCurrentWeek: detail?.revision != value.revision)
    }
  }

  private var viewingDatePicker: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        Button {
          showingAccessibleDatePicker = true
        } label: {
          Text(viewingDate.formatted(Date.FormatStyle(date: .long, time: .omitted,
                locale: Locale(identifier: "zh_CN"), calendar: PlanningDate.calendar,
                timeZone: PlanningDate.calendar.timeZone)))
            .studyTypography(.body)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("查看日期")
        .accessibilityValue(viewingDate.formatted(.dateTime.year().month().day()))
      } else {
        DatePicker("查看日期", selection: $viewingDate, displayedComponents: .date)
          .datePickerStyle(.compact)
          .labelsHidden()
          .tint(MobileTheme.brand)
          .environment(\.locale, Locale(identifier: "zh_CN"))
          .environment(\.calendar, PlanningDate.calendar)
          .environment(\.timeZone, PlanningDate.calendar.timeZone)
          .accessibilityLabel("查看日期")
      }
    }
    .onChange(of: viewingDate) { _, date in
      availableWeekRange = nil
      selectedDayID = PlanningDate.key(date)
      agendaDayID = selectedDayID
    }
  }

  @ViewBuilder
  private func timetableContent(
    detail: DocumentDetail,
    range: ClosedRange<Int>,
    snapshot: TimetableSnapshot
  ) -> some View {
    let displayedWeek = snapshot.teachingWeek ?? selectedWeek
    MobileSurface {
      VStack(alignment: .leading, spacing: 14) {
        MobileSectionHeading(
          title: "课表",
          detail: snapshot.classLabel,
          icon: "calendar.badge.clock"
        )

        MobileTimetableWeekNavigator(
          label: snapshot.weekLabel ?? "第\(displayedWeek)周",
          range: range,
          selectedWeek: displayedWeek,
          dateRange: weekDateRange(for: snapshot.days),
          onSelect: { selectWeek($0, within: range) }
        )

        MobileTimetableDateStrip(
          days: snapshot.days,
          selectedDayID: selectedDayID,
          todayID: snapshot.referenceDate,
          onSelect: { selectDay($0) }
        )
        .id(snapshot.weekStartDate ?? "week-\(displayedWeek)")

        if session.state != .online {
          MobileInlineNotice(
            text:
              "离线缓存：课表于 \(cacheDateText(detail.fetchedAt)) 获取；手机日期 \(snapshot.referenceDate)，当前查看 \(snapshot.weekLabel ?? "该周")。",
            symbol: "icloud.slash",
            tint: .orange
          )
        }
      }
    }

    MobileTimetableAgendaTransitionContainer(
      snapshot: snapshot,
      displayedDayID: agendaDayID,
      direction: agendaNavigationDirection,
      reduceMotion: reduceMotion
    )
  }

  private var unavailableContent: some View {
    MobileSurface {
      VStack(alignment: .leading, spacing: 12) {
        MobileSectionHeading(title: "课表", icon: "calendar.badge.exclamationmark")
        if let detail {
          let snapshot = StudyRocketTimetableParser.snapshot(from: detail.markdown)
          MobileInlineNotice(
            text: unavailableMessage(for: snapshot.status),
            symbol: unavailableSymbol(for: snapshot.status),
            tint: snapshot.status == .invalid ? .orange : .secondary
          )
        } else {
          MobileInlineNotice(
            text: "暂时无法读取完整课表。请连接 学业服务 后刷新；课表文件需要在 Mac 端的课表页面导入。",
            symbol: "calendar.badge.exclamationmark",
            tint: .orange
          )
        }
      }
    }
  }

  private func load() async {
    isLoading = true
    let value = await session.document(for: "timetable")
    guard !Task.isCancelled else { return }
    if let value {
      accept(value, selectCurrentWeek: detail?.revision != value.revision)
    }
    isLoading = false
  }

  private func accept(_ value: DocumentDetail, selectCurrentWeek: Bool) {
    let priorDayID = selectedDayID
    detail = value
    guard let range = StudyRocketTimetableParser.teachingWeekRange(from: value.markdown) else {
      availableWeekRange = nil
      displayedSnapshot = nil
      selectedDayID = ""
      agendaDayID = ""
      return
    }
    let current = StudyRocketTimetableParser.snapshot(from: value.markdown)
    if current.status == .beforeTerm || current.status == .afterTerm ||
        (current.days.contains(where: { $0.id == PlanningDate.key(.now) }) && current.teachingWeek == nil) {
      availableWeekRange = nil; displayedSnapshot = current
      selectedDayID = PlanningDate.key(.now); agendaDayID = selectedDayID
      return
    }
    availableWeekRange = range
    if selectCurrentWeek {
      let currentWeek =
        session.snapshot?.home.timetable?.teachingWeek
        ?? StudyRocketTimetableParser.snapshot(from: value.markdown).teachingWeek
        ?? range.lowerBound
      selectedWeek = min(max(currentWeek, range.lowerBound), range.upperBound)
    } else {
      selectedWeek = min(max(selectedWeek, range.lowerBound), range.upperBound)
    }

    let snapshot = StudyRocketTimetableParser.snapshot(
      from: value.markdown, teachingWeek: selectedWeek)
    displayedSnapshot = snapshot
    let resolvedDayID = dayID(
      in: snapshot,
      preferring: selectCurrentWeek ? snapshot.referenceDate : priorDayID
    )
    selectedDayID = resolvedDayID
    agendaDayID = resolvedDayID
  }

  private func selectWeek(_ week: Int, within range: ClosedRange<Int>) {
    let targetWeek = min(max(week, range.lowerBound), range.upperBound)
    guard targetWeek != selectedWeek else { return }
    guard let detail else { return }

    let preferredDayID = selectedDayID.isEmpty ? displayedSnapshot?.referenceDate : selectedDayID
    let targetSnapshot = StudyRocketTimetableParser.snapshot(
      from: detail.markdown, teachingWeek: targetWeek)
    let targetDayID = dayID(in: targetSnapshot, preferring: preferredDayID)
    withAnimation(reduceMotion ? .easeInOut(duration: 0.14) : .easeInOut(duration: 0.22)) {
      agendaNavigationDirection = targetWeek < selectedWeek ? .previous : .next
      selectedWeek = targetWeek
      displayedSnapshot = targetSnapshot
      selectedDayID = targetDayID
      agendaDayID = targetDayID
    }
  }

  private func selectDay(_ day: TimetableDaySnapshot) {
    guard selectedDayID != day.id else { return }
    let direction = dayNavigationDirection(for: day.id)

    var immediateSelection = Transaction()
    immediateSelection.disablesAnimations = true
    withTransaction(immediateSelection) {
      selectedDayID = day.id
    }

    withAnimation(reduceMotion ? .easeInOut(duration: 0.14) : .easeInOut(duration: 0.18)) {
      agendaNavigationDirection = direction
      agendaDayID = day.id
    }
  }

  private func dayNavigationDirection(for targetDayID: String)
    -> MobileTimetableWeekNavigationDirection
  {
    guard let days = displayedSnapshot?.days,
      let currentIndex = days.firstIndex(where: { $0.id == selectedDayID }),
      let targetIndex = days.firstIndex(where: { $0.id == targetDayID })
    else {
      return .next
    }
    return targetIndex < currentIndex ? .previous : .next
  }

  private func dayID(in snapshot: TimetableSnapshot, preferring preferredDayID: String?) -> String {
    guard let firstDay = snapshot.days.first else { return "" }
    if let preferredDayID, snapshot.days.contains(where: { $0.id == preferredDayID }) {
      return preferredDayID
    }
    if snapshot.days.contains(where: { $0.id == snapshot.referenceDate }) {
      return snapshot.referenceDate
    }
    return firstDay.id
  }

  private func unavailableMessage(for status: TimetableStatus) -> String {
    switch status {
    case .notImported:
      "尚未导入课表。请在 Mac 端的课表页面选择文件并保存。"
    case .invalid:
      "课表 Markdown 格式有误，无法显示。请在 Mac 端检查受管理课表区。"
    case .beforeTerm:
      "课表尚未到开始日期。"
    case .afterTerm:
      "课表已超过已导入范围。"
    case .available:
      "课表没有可显示的教学周。"
    }
  }

  private func unavailableSymbol(for status: TimetableStatus) -> String {
    switch status {
    case .invalid: "exclamationmark.triangle.fill"
    case .notImported: "calendar.badge.exclamationmark"
    default: "calendar"
    }
  }

  private func cacheDateText(_ value: Date) -> String {
    Self.cacheDateFormatter.string(from: value)
  }

  private static let cacheDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy年M月d日 HH:mm"
    return formatter
  }()
}

private struct MobileTimetableWeekNavigator: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let label: String
  let range: ClosedRange<Int>
  let selectedWeek: Int
  let dateRange: String
  let onSelect: (Int) -> Void

  var body: some View {
    VStack(spacing: 8) {
      if dynamicTypeSize.isAccessibilitySize {
        weekPicker
        navigationControls
      } else {
        HStack(spacing: 8) {
          previousButton
          weekPicker
          nextButton
        }
      }
      Text(dateRange)
        .studyTypography(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
  }

  private var weekPicker: some View {
    Menu {
      Picker("教学周", selection: Binding(get: { selectedWeek }, set: { onSelect($0) })) {
        ForEach(Array(range), id: \.self) { week in Text("第\(week)周").tag(week) }
      }
    } label: {
      HStack(spacing: 5) {
        Text(label).studyTypography(.headline).fixedSize(horizontal: false, vertical: true)
        Image(systemName: "chevron.up.chevron.down")
          .studyTypography(.caption, weight: .semibold).foregroundStyle(.secondary).accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("教学周")
    .accessibilityValue(label)
    .accessibilityHint("选择要查看的教学周")
  }

  private var navigationControls: some View {
    HStack { previousButton; Spacer(); nextButton }
  }
  private var previousButton: some View {
    navigationButton(symbol: "chevron.left", label: "上一教学周") { onSelect(selectedWeek - 1) }
      .disabled(selectedWeek <= range.lowerBound)
  }
  private var nextButton: some View {
    navigationButton(symbol: "chevron.right", label: "下一教学周") { onSelect(selectedWeek + 1) }
      .disabled(selectedWeek >= range.upperBound)
  }
  private func navigationButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).studyTypography(.body, weight: .semibold)
        .frame(minWidth: 44, minHeight: 44).contentShape(Circle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(MobileTheme.brand)
    .background(MobileTheme.brand.opacity(0.10), in: Circle())
    .accessibilityLabel(label)
  }
}

private struct MobileTimetableDateStrip: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let days: [TimetableDaySnapshot]
  let selectedDayID: String
  let todayID: String
  let onSelect: (TimetableDaySnapshot) -> Void

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(days) { day in
            dayButton(day)
              .id(day.id)
          }
        }
        .padding(.horizontal, 2)
      }
      .onAppear {
        scrollSelectedDay(with: proxy)
      }
    }
  }

  private func dayButton(_ day: TimetableDaySnapshot) -> some View {
    let isSelected = day.id == selectedDayID
    let isToday = day.id == todayID

    return Button {
      onSelect(day)
    } label: {
      VStack(spacing: 3) {
        Text(day.weekdayLabel)
          .studyTypography(.caption2, weight: .semibold)
          .lineLimit(1)
        Text(dayNumber(for: day))
          .studyTypography(.title3, weight: .bold)
          .lineLimit(1)
      }
      .fixedSize(horizontal: true, vertical: true)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? 70 : 52, minHeight: 58)
      .foregroundStyle(isSelected ? Color.white : (isToday ? MobileTheme.brand : Color.primary))
      .background(
        isSelected ? MobileTheme.brand : Color.secondary.opacity(0.08),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(isToday && !isSelected ? MobileTheme.brand.opacity(0.6) : .clear, lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(MobileTimetableDateButtonStyle())
    .accessibilityLabel(isToday ? "\(day.dateLabel)，今天" : day.dateLabel)
    .accessibilityValue(isSelected ? "已选择" : "未选择")
    .accessibilityHint("显示当天课程")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func dayNumber(for day: TimetableDaySnapshot) -> String {
    guard let value = day.id.split(separator: "-").last, let number = Int(value) else {
      return day.dateLabel.components(separatedBy: " · ").first ?? day.dateLabel
    }
    return String(number)
  }

  private func scrollSelectedDay(with proxy: ScrollViewProxy) {
    guard !selectedDayID.isEmpty else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      proxy.scrollTo(selectedDayID, anchor: .center)
    }
  }
}

private struct MobileTimetableDateButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.82 : 1)
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
      .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
  }
}

private struct MobileTimetableAgendaTransitionContainer: View {
  let snapshot: TimetableSnapshot
  let displayedDayID: String
  let direction: MobileTimetableWeekNavigationDirection
  let reduceMotion: Bool

  private var selectedDay: TimetableDaySnapshot? {
    snapshot.days.first(where: { $0.id == displayedDayID }) ?? snapshot.days.first
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      MobileSurface {
        if let selectedDay {
          MobileTimetableDayAgendaView(day: selectedDay)
        } else {
          MobileInlineNotice(
            text: "该教学周没有可显示的日期，请刷新课表后重试。",
            symbol: "calendar.badge.exclamationmark",
            tint: .orange
          )
        }
      }
      .id("\(snapshot.teachingWeek ?? 0)-\(displayedDayID)")
      .transition(contentTransition)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var contentTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .asymmetric(
      insertion: .move(edge: direction.insertionEdge).combined(with: .opacity),
      removal: .move(edge: direction.removalEdge).combined(with: .opacity)
    )
  }
}

private struct MobileTimetableDayAgendaView: View {
  let day: TimetableDaySnapshot

  private var holidays: [TimetableEntrySnapshot] {
    day.entries.filter { $0.kind == .holiday }
  }

  private var entries: [TimetableEntrySnapshot] {
    day.entries
      .filter { $0.kind != .holiday }
      .sorted { lhs, rhs in
        let leftTime = lhs.startTime ?? "99:99"
        let rightTime = rhs.startTime ?? "99:99"
        if leftTime != rightTime { return leftTime < rightTime }
        return lhs.title < rhs.title
      }
  }

  private var detail: String {
    if entries.isEmpty { return holidays.isEmpty ? "无课程" : "假期" }
    return "\(entries.count) 项安排"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      MobileSectionHeading(title: day.dateLabel, detail: detail, icon: "calendar")

      ForEach(holidays) { holiday in
        MobileInlineNotice(text: holiday.title, symbol: "sun.max.fill", tint: .orange)
      }

      if entries.isEmpty {
        StudyLabel(
          holidays.isEmpty ? "当天无课程安排" : "当天为假期",
          systemImage: holidays.isEmpty ? "calendar" : "calendar.badge.checkmark"
        )
        .studyTypography(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      } else {
        ForEach(entries) { entry in
          MobileTimetableRow(entry: entry)
        }
      }
    }
    .accessibilityElement(children: .contain)
  }
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
      Text("连接 学业服务")
        .studyTypography(.title2, weight: .bold)
      Text("首次使用填写学业服务 HTTPS 地址，并输入管理员提供的一次性配对码。")
        .studyTypography(.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      StudyButton("开始连接", action: startConnection)
        .buttonStyle(.borderedProminent)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: 340)
  }
}

private struct MobileQuickAction: View {
  let title: String
  let symbol: String
  var isWide = false
  let action: () -> Void

  var body: some View {
    let layout = isWide ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 6))
    return Button(action: action) {
      layout {
        Image(systemName: symbol)
          .studyTypography(.headline)
        Text(title)
          .studyTypography(isWide ? .body : .subheadline, weight: .medium)
          .fixedSize(horizontal: false, vertical: true)
          .multilineTextAlignment(.center)
      }
      .foregroundStyle(MobileTheme.brand)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: isWide ? .leading : .center)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(
        MobileTheme.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }
}

private struct MobileChatView: View {
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
              .background(MobileTheme.groupedBackground)
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
        HStack(alignment: .bottom, spacing: 10) {
          TextField("输入学业问题或今日事实", text: $session.inputDraft, axis: .vertical)
            .lineLimit(1...5)
            .studyChatTypography()
            .focused($isComposerFocused)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.primary.opacity(0.12)))
          Button {
            isComposerFocused = false
            Task {
              if session.isChatBusy {
                await session.interruptChat()
              } else {
                requestLatest()
                await session.sendDraft()
              }
            }
          } label: {
            Image(systemName: session.isChatBusy ? "stop.circle.fill" : "arrow.up.circle.fill")
              .font(.system(size: 31, weight: .semibold))
              .frame(width: 44, height: 44)
          }
          .disabled(
            session.retryingChat || (!session.isChatAvailable && !session.isChatBusy)
              || (!session.isChatBusy
                && session.inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          )
          .accessibilityLabel(session.isChatBusy ? "停止对话" : "发送")
        }
        .padding(.horizontal, MobileTheme.pageInset)
        .padding(.vertical, 8)
        .background(.bar)
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

  var body: some View {
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
          .foregroundStyle(.white)
          .background(MobileTheme.brand, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        MobileBrandMark(size: 22)
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
private struct MobileMarkdownView: View {
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
          MobileChatMessage(message: user, contentWidth: contentWidth).equatable()
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

private struct MobilePlanView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ObservedObject var session: MobileSession
  let onNavigate: (Int) -> Void
  @State private var completedDeliveriesExpanded = false
  @State private var futureRowsExpanded = false
  @State private var expandedEmptyDates = Set<String>()
  @State private var assignment: MobilePendingTaskAssignment?
  @State private var showLinkageEditor = false
  @State private var linkageTimetable = ""
  @State private var linkagePlan: WeeklyPlanSnapshot?
  @State private var linkageRevision: String?
  @State private var showOrganization = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          planHeader
          HStack {
            StudyButton("让 AI 整理", systemImage: "sparkles") {
              showOrganization = true
              Task { await session.startOrganization() }
            }
            .buttonStyle(.bordered)
            .disabled(session.pendingWeekDraft == nil && session.currentOrganization == nil && !session.canStartOrganization)
            .accessibilityHint("直接开始整理，在当前页面查看回复、补充信息和确认差异")
            Spacer()
            Menu {
              StudyButton(session.snapshot?.week.linkage == nil ? "手动配置任务联动" : "手动管理关联、改期与已完成") {
                Task {
                  linkageTimetable = await session.document(for: "timetable")?.markdown ?? ""
                  linkagePlan = session.snapshot?.week
                  linkageRevision = session.snapshot?.revision
                  showLinkageEditor = true
                }
              }
              .disabled(session.snapshot == nil)
            } label: {
              Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
            }
            .accessibilityLabel("周计划更多操作")
          }
          MobileSnapshotFreshness(session: session)
          if let week = session.snapshot?.week, !week.days.isEmpty {
            scheduleContent(week)
            TimelineView(.everyMinute) { clock in deliveriesContent(at: clock.date) }
            if !week.futureRows.isEmpty {
              futureContent(week.futureRows)
            }
          } else {
            MobileEmptyState(
              title: "暂无计划缓存",
              message: session.savedEndpoint == nil
                ? "先连接 学业服务，手机才会显示周计划。"
                : "当前没有可读取的周计划缓存，请刷新 学业服务。",
              symbol: "calendar.badge.exclamationmark",
              actionTitle: session.savedEndpoint == nil ? "前往配对" : "刷新数据",
              action: {
                if session.savedEndpoint == nil {
                  onNavigate(5)
                } else {
                  Task { await session.refresh() }
                }
              }
            )
            .frame(minHeight: 520)
          }
        }
        .padding(MobileTheme.pageInset)
        .safeAreaPadding(.bottom, 8)
      }
      .sheet(isPresented: $showLinkageEditor) {
        if let week = linkagePlan {
          TaskLinkageEditor(plan: week, timetableSource: linkageTimetable) { plan, events in
            guard await session.saveWeek(plan, events: events, originalTimetable: linkageTimetable, baseRevision: linkageRevision) else {
              throw PlanningChangeRouter.RoutingError(session.pendingToggleSyncIssue ?? "计划尚未提交，已保留本地草稿。")
            }
          }
        }
      }
      .sheet(isPresented: $showOrganization) {
        MobileOrganizationSheet(session: session)
      }
      .navigationTitle("周计划")
      .onChange(of: session.repositoryGeneration) { _, _ in expandedEmptyDates.removeAll() }
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .background(MobileTheme.groupedBackground)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task { await session.refresh() }
          } label: {
            Image(systemName: "arrow.clockwise")
              .frame(width: 44, height: 44)
          }
          .disabled(session.state == .connecting)
          .accessibilityLabel("刷新周计划")
        }
      }
      .refreshable { await session.refresh() }
      #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
      #endif
    }
    .sheet(item: $assignment) { assignment in
      MobilePendingTaskAssignmentSheet(
        assignment: assignment,
        days: session.snapshot?.week.days ?? [],
        session: session
      )
    }
  }

  private var planHeader: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top) {
        planHeaderText
        Spacer(minLength: 12)
        MobileStatusBanner(session: session)
      }
      VStack(alignment: .leading, spacing: 8) {
        planHeaderText
        MobileStatusBanner(session: session)
      }
    }
  }

  private var planHeaderText: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(session.snapshot?.home.dateLabel ?? "等待学业服务")
        .studyTypography(.headline)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private func scheduleContent(_ week: WeeklyPlanSnapshot) -> some View {
    MobileSurface {
      VStack(alignment: .leading, spacing: 16) {
        MobileSectionHeading(title: "近七日安排", detail: "从今天起", icon: "calendar")
        ForEach(Array(week.days.enumerated()), id: \.element.id) { index, day in
          if index > 0 {
            Rectangle()
              .fill(Color.primary.opacity(0.08))
              .frame(height: 1)
          }
          daySchedule(day)
        }
      }
    }
  }

  @ViewBuilder
  private func deliveriesContent(at date: Date) -> some View {
    let deliveries = session.currentWeekDeliveries(at: date)
    let openDeliveries = deliveries.filter { !session.effectiveDeliveryCompletion($0) }
    let completedDeliveries = deliveries.filter { session.effectiveDeliveryCompletion($0) }
    MobileSurface {
      VStack(alignment: .leading, spacing: 12) {
        MobileSectionHeading(title: "本周交付物", detail: "学习产出", icon: "checklist")
        if deliveries.isEmpty {
          MobileInlineNotice(text: "暂无学习交付物", symbol: "checklist", tint: .secondary)
        } else {
          if openDeliveries.isEmpty {
            MobileInlineNotice(text: "本周交付物已全部完成。", symbol: "checkmark.circle", tint: .teal)
          } else {
            ForEach(openDeliveries) { delivery in
              deliveryRow(delivery)
            }
          }
          DisclosureGroup(isExpanded: $completedDeliveriesExpanded) {
            VStack(alignment: .leading, spacing: 12) {
              if completedDeliveries.isEmpty {
                Text("暂无已完成交付物")
                  .studyTypography(.subheadline)
                  .foregroundStyle(.secondary)
                  .frame(minHeight: 44, alignment: .leading)
              } else {
                ForEach(completedDeliveries) { delivery in
                  deliveryRow(delivery)
                }
              }
            }
            .padding(.top, 8)
          } label: {
            HStack {
              Text("已完成").studyTypography(.subheadline, weight: .semibold)
              Spacer()
              Text("\(completedDeliveries.count)")
                .studyTypography(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func futureContent(_ rows: [ScheduledRowSnapshot]) -> some View {
    MobileSurface {
      DisclosureGroup(isExpanded: $futureRowsExpanded) {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            if index > 0 {
              Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
            }
            futureSchedule(row)
          }
        }
        .padding(.top, 12)
      } label: {
        HStack {
          StudyLabel("更远日期", systemImage: "calendar.badge.clock")
            .studyTypography(.subheadline, weight: .semibold)
          Spacer()
          Text("\(rows.count)")
            .studyTypography(.caption).monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .frame(minHeight: 44)
      }
    }
  }

  @ViewBuilder
  private func daySchedule(_ day: DaySnapshot) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      let empty = session.isEmptyPlanDay(day)
      dayHeading(day, empty: empty)
      if !empty || expandedEmptyDates.contains(day.id) {
        ForEach(Array(day.slots.enumerated()), id: \.element.id) { index, slot in
          scheduleSlot(slot, index: index, dayID: day.id)
        }
        pendingTasks(day)
      }
    }
  }

  @ViewBuilder
  private func dayHeading(_ day: DaySnapshot, empty: Bool) -> some View {
    let parts = day.dateLabel.components(separatedBy: " · ")
    let label = parts.count == 2 ? parts.reversed().joined(separator: " · ") : day.dateLabel
    let header = (dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
      : AnyLayout(HStackLayout(spacing: 8))) {
      Text(label).studyTypography(.headline)
      if day.id == Self.todayIDFormatter.string(from: .now) {
        Text("今天").studyTypography(.caption, weight: .semibold).foregroundStyle(MobileTheme.brand)
      }
      Spacer()
      if empty {
        Text("暂无安排").studyTypography(.subheadline).foregroundStyle(.secondary)
        Image(systemName: expandedEmptyDates.contains(day.id) ? "chevron.down" : "chevron.right")
          .studyTypography(.caption).foregroundStyle(.secondary)
      }
    }
    if empty {
      Button {
        if expandedEmptyDates.contains(day.id) { expandedEmptyDates.remove(day.id) }
        else { expandedEmptyDates.insert(day.id) }
      } label: { header.frame(minHeight: 44).contentShape(Rectangle()) }
        .buttonStyle(.plain)
        .accessibilityValue(expandedEmptyDates.contains(day.id) ? "已展开" : "已折叠")
    } else { header }
  }

  @ViewBuilder
  private func pendingTasks(_ day: DaySnapshot) -> some View {
    let tasks = PeriodTaskParser.tasks(from: day.unassigned)
    if !tasks.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        StudyLabel("待分时", systemImage: "tray.full")
          .studyTypography(.caption, weight: .semibold)
          .foregroundStyle(.secondary)
        ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
          Button {
            assignment = MobilePendingTaskAssignment(sourceDayID: day.id, sourceTaskIndex: index, text: task.text)
          } label: {
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: "calendar.badge.plus")
                .foregroundStyle(MobileTheme.brand)
                .frame(width: 20, height: 20)
              Text(task.text)
                .studyTypography(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
              Image(systemName: "chevron.right")
                .studyTypography(.caption, weight: .semibold)
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("待分时，\(task.text)")
          .accessibilityHint("选择日期和时段纳入安排")
        }
      }
    }
  }

  @ViewBuilder
  private func futureSchedule(_ row: ScheduledRowSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      let day = DaySnapshot(id: row.id, dateLabel: row.dateLabel, slots: row.slots, unassigned: row.unassigned)
      let empty = session.isEmptyPlanDay(day)
      dayHeading(day, empty: empty)
      if !empty || expandedEmptyDates.contains(day.id) {
        ForEach(Array(row.slots.enumerated()), id: \.element.id) { index, slot in
          scheduleSlot(slot, index: index, dayID: nil)
        }
        if !row.unassigned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Label {
            Text(PeriodTaskParser.displayText(from: row.unassigned))
              .studyTypography(.subheadline)
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "tray.full")
          }
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        }
      }
    }
  }

  @ViewBuilder
  private func scheduleSlot(
    _ slot: PeriodSnapshot,
    index: Int,
    dayID: String?
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      StudyLabel(slot.title, systemImage: slotSymbol(for: index))
        .studyTypography(.caption, weight: .semibold)
        .foregroundStyle(.secondary)
        .frame(minHeight: 28, alignment: .leading)
      if slot.tasks.isEmpty {
        Text("未安排")
          .studyTypography(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.leading, 30)
          .frame(minHeight: 44, alignment: .leading)
      } else {
        ForEach(Array(slot.tasks.enumerated()), id: \.element.id) { taskIndex, task in
          let completed = dayID.map {
            session.effectiveTaskCompletion(dayID: $0, period: slot, task: task)
          } ?? task.isCompleted
          let isPending = dayID.map {
            session.isTaskTogglePending(dayID: $0, period: slot, task: task)
          } ?? false
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: completed ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(completed ? MobileTheme.completion : MobileTheme.rail)
              .frame(width: 20, height: 20)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
              Text(task.text)
                .studyTypography(.subheadline)
                .foregroundStyle(completed ? .secondary : .primary)
                .strikethrough(completed)
                .fixedSize(horizontal: false, vertical: true)
              if isPending {
                Text("待同步")
                  .studyTypography(.caption2, weight: .semibold)
                  .foregroundStyle(.orange)
              }
            }
            Spacer(minLength: 0)
            if let dayID {
              Button {
                Task {
                  await session.returnScheduledTaskToUnassigned(
                    dayID: dayID,
                    periodID: slot.id,
                    taskID: task.id
                  )
                }
              } label: {
                Image(systemName: "tray.and.arrow.down")
                  .frame(width: 44, height: 44)
              }
              .buttonStyle(.borderless)
              .accessibilityLabel("将\(task.text)退回待分时")
            }
          }
          .padding(.leading, 20)
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .accessibilityElement(children: .combine)
          .accessibilityLabel("\(slot.title)，\(task.text)")
          .accessibilityValue(completed ? "已完成" : "未完成")
          if taskIndex < slot.tasks.count - 1 { Divider().padding(.leading, 32) }
        }
      }
    }
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
  }

  @ViewBuilder
  private func deliveryRow(_ delivery: DeliverySnapshot) -> some View {
    let completed = session.effectiveDeliveryCompletion(delivery)
    let pending = session.isDeliveryTogglePending(delivery)
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: completed ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(completed ? MobileTheme.completion : MobileTheme.rail)
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        if let dateLabel = delivery.dateLabel, !dateLabel.isEmpty {
          Text(dateLabel)
            .studyTypography(.caption, weight: .semibold)
            .foregroundStyle(.secondary)
        }
        Text(delivery.text)
          .studyTypography(.subheadline)
          .strikethrough(completed)
          .foregroundStyle(completed ? .secondary : .primary)
          .fixedSize(horizontal: false, vertical: true)
        if pending {
          Text("待同步")
            .studyTypography(.caption2, weight: .semibold)
            .foregroundStyle(.orange)
        }
      }
    }
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private func slotSymbol(for index: Int) -> String {
    switch index {
    case 0: "sun.max"
    case 1: "sun.and.horizon"
    default: "moon.stars"
    }
  }

  private static let todayIDFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()
}

private struct MobilePendingTaskAssignment: Identifiable {
  let sourceDayID: String
  let sourceTaskIndex: Int
  let text: String

  var id: String { "\(sourceDayID)-\(sourceTaskIndex)-\(text)" }
}

private struct MobilePendingTaskAssignmentSheet: View {
  let assignment: MobilePendingTaskAssignment
  let days: [DaySnapshot]
  @ObservedObject var session: MobileSession
  @Environment(\.dismiss) private var dismiss
  @State private var text: String
  @State private var targetDayID: String
  @State private var targetPeriodID = "morning"

  init(assignment: MobilePendingTaskAssignment, days: [DaySnapshot], session: MobileSession) {
    self.assignment = assignment
    self.days = days
    self.session = session
    _text = State(initialValue: assignment.text)
    _targetDayID = State(initialValue: days.contains(where: { $0.id == assignment.sourceDayID }) ? assignment.sourceDayID : days.first?.id ?? "")
  }

  private var targetDay: DaySnapshot? {
    days.first { $0.id == targetDayID }
  }

  private var targetPeriod: PeriodSnapshot? {
    targetDay?.slots.first { $0.id == targetPeriodID }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("事项") {
          TextField("事项", text: $text, axis: .vertical)
            .lineLimit(2...5)
        }
        Section("纳入安排") {
          Picker("日期", selection: $targetDayID) {
            ForEach(days) { day in
              Text(day.dateLabel).tag(day.id)
            }
          }
          Picker("时段", selection: $targetPeriodID) {
            ForEach(targetDay?.slots ?? []) { period in
              Text(period.title).tag(period.id)
            }
          }
          if let targetPeriod, !targetPeriod.tasks.isEmpty {
            StudyLabel("该时段已有 \(targetPeriod.tasks.count) 项安排", systemImage: "exclamationmark.triangle")
              .studyTypography(.footnote)
              .foregroundStyle(.orange)
          }
        }
      }
      .navigationTitle("安排待分时事项")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          StudyButton("取消") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          StudyButton("安排") {
            Task {
              await session.assignUnassignedTask(
                sourceDayID: assignment.sourceDayID,
                taskIndex: assignment.sourceTaskIndex,
                text: text,
                targetDayID: targetDayID,
                targetPeriodID: targetPeriodID
              )
              dismiss()
            }
          }
          .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || targetDay == nil || targetPeriod == nil)
        }
      }
    }
  }
}

private extension Notification.Name { static let focusStudyFact = Notification.Name("studyrocket.focusFact") }

private struct MobileDailyView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var session: MobileSession
  @State private var text = ""
  @State private var notice = ""
  @State private var lastFact: QuickFact?
  @State private var confirmingDiscard = false
  @ScaledMetric(relativeTo: .body) private var editorHeight: CGFloat = 100
  @FocusState private var focus: Bool

  var body: some View {
    NavigationStack {
      List {
        Section("写下今天做过的一件事") {
          TextEditor(text: $text)
            .studyTypography(.body)
            .frame(height: editorHeight)
            .scrollContentBackground(.hidden)
            .focused($focus)
            .overlay(alignment: .topLeading) {
              if text.isEmpty {
                Text("例如：完成高数第一章例题")
                  .studyTypography(.body).foregroundStyle(.secondary)
                  .padding(.top, 8).padding(.leading, 5)
                  .allowsHitTesting(false).accessibilityHidden(true)
              }
            }
            .accessibilityLabel("今天做过的一件事")
            .padding(.vertical, 6)
          MobilePrimaryButton(title: "保存", symbol: "square.and.arrow.down", action: save)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if !notice.isEmpty {
            MobileInlineNotice(text: notice, symbol: "exclamationmark.circle", tint: .orange)
          }
          if let fact = lastFact {
            let pending = session.pendingFacts.contains(fact)
            StudyLabel((pending ? "已存本机草稿：" : "已保存：") + fact.text,
                  systemImage: pending ? "clock" : "checkmark.circle")
              .studyTypography(.subheadline)
              .foregroundStyle(pending ? Color.secondary : MobileTheme.completion)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        if !session.pendingFacts.isEmpty {
          Section("本机草稿 · 待同步") {
            ForEach(session.pendingFacts) { fact in factRow(fact) }
            if let error = session.factSyncError {
              MobileInlineNotice(text: error, symbol: "arrow.triangle.2.circlepath", tint: .orange)
            }
            StudyButton("重新同步") { Task { await session.refresh() } }
          }
        }
        Section("近期记录") {
          let facts = session.snapshot?.recentFacts ?? []
          if facts.isEmpty {
            StudyLabel("还没有已保存的记录", systemImage: "text.badge.plus")
              .studyTypography(.subheadline).foregroundStyle(.secondary)
              .frame(minHeight: 44, alignment: .leading)
          }
          ForEach(facts) { fact in factRow(fact) }
        }
        if let old = session.pendingDailyDraft {
          Section("旧版五项草稿 · 尚未提交") {
            Text(verbatim: [old.date, old.deliverables, old.studyTime, old.sleep, old.exercise, old.firstTask].joined(separator: "\n")).textSelection(.enabled)
            Text("可复制原文追加为新记录，或在“更多”处理旧草稿。").studyTypography(.caption)
          }
        }
        if let old = session.snapshot?.legacyJournal, !old.isEmpty {
          DisclosureGroup("以往的五项记录") { Text(verbatim: old).textSelection(.enabled) }
        }
      }
      .toolbar { ToolbarItem(placement: .cancellationAction) {
        StudyButton("关闭") {
          if text.isEmpty { dismiss() } else { confirmingDiscard = true }
        }
      } }
      .interactiveDismissDisabled(!text.isEmpty)
      .confirmationDialog("放弃尚未保存的文字？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
        StudyButton("放弃并关闭", role: .destructive) { dismiss() }
        StudyButton("继续填写", role: .cancel) {}
      }
      .navigationTitle("记一件事")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
      #endif
      .onAppear { focus = true }
      .onReceive(NotificationCenter.default.publisher(for: .focusStudyFact)) { _ in focus = true }
      .onChange(of: session.repositoryGeneration) { _, _ in lastFact = nil; text = ""; notice = "" }
      .refreshable { await session.refresh() }
    }
  }
  private func factRow(_ fact: QuickFact) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(fact.date).studyTypography(.footnote).foregroundStyle(.secondary)
      Text(verbatim: fact.text)
        .studyTypography(.body)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }

  private func save() {
    do {
      let fact = QuickFact(text: text)
      try session.enqueueFact(fact)
      lastFact = fact; text = ""; notice = ""
      Task { await session.syncFacts() }
    } catch { notice = error.localizedDescription }
  }
}

private enum MobilePairingFocus: Hashable {
  case endpoint
  case code
  case deviceName
}

@MainActor
private struct MobileConnectionPresentation {
  let title: String
  let detail: String
  let symbol: String
  let tint: Color

  init(session: MobileSession) {
    switch session.state {
    case .online where session.isChatAvailable:
      title = "已连接学业服务"
      detail = "首页、计划与学业对话均可用"
      symbol = "checkmark.circle.fill"
      tint = MobileTheme.completion
    case .online:
      title = "首页可用 · 对话未就绪"
      detail = session.chatUnavailableMessage ?? "学业服务 正在重试学业对话协议自检"
      symbol = "bubble.left.and.exclamationmark.fill"
      tint = .orange
    case .offline:
      title = session.state.title
      detail = "正在使用本机缓存，可重新连接学业服务"
      symbol = "icloud.slash"
      tint = .secondary
    case .connecting:
      title = "正在连接学业服务"
      detail = "正在验证服务与配对身份"
      symbol = "arrow.triangle.2.circlepath"
      tint = .orange
    case .failed(let message):
      title = "连接失败"
      detail = session.lastConnectionIssue ?? message
      symbol = "exclamationmark.triangle.fill"
      tint = .red
    case .unconfigured:
      title = "尚未连接学业服务"
      detail = "输入 学业服务 的 HTTPS 地址和一次性配对码"
      symbol = "link.badge.plus"
      tint = MobileTheme.brand
    }
  }
}

private struct MobileConnectionSummary: View {
  @ObservedObject var session: MobileSession

  private var presentation: MobileConnectionPresentation { .init(session: session) }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: presentation.symbol)
        .studyTypography(.title3)
        .foregroundStyle(presentation.tint)
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(presentation.title)
          .studyTypography(.body, weight: .semibold)
          .fixedSize(horizontal: false, vertical: true)
        Text(presentation.detail)
          .studyTypography(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .frame(minHeight: 52, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(presentation.title)，\(presentation.detail)")
  }
}

private struct MobileConnectionStatusRow: View {
  let title: String
  let value: String
  let symbol: String
  let tint: Color

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .foregroundStyle(tint)
        .frame(width: 20)
        .accessibilityHidden(true)
      MobileAdaptiveValue(title: title, value: value, tint: tint)
    }
    .frame(minHeight: 44)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title)，\(value)")
  }
}

private struct MobileMoreView: View {
  @ObservedObject var session: MobileSession
  let openFact: () -> Void
  @State private var showDiscardDraftsConfirmation = false
  @State private var showClearCacheConfirmation = false
  #if os(iOS)
    @ObservedObject private var reminders = MobileReminderScheduler.shared
  #endif

  var body: some View {
    NavigationStack {
      List {
        Section { StudyButton("记一件事", systemImage: "square.and.pencil", action: openFact) }
        Section("计划") {
          NavigationLink {
            MobileBufferRulesView(session: session)
          } label: {
            StudyLabel("缓冲与降级", systemImage: "shield")
              .frame(minHeight: 44)
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
                      .studyTypography(.body, weight: .medium)
                    Spacer(minLength: 0)
                  }
                  .frame(minHeight: 44)
                }
              }
            }
          }
        }
        #if os(iOS)
          Section("提醒") {
            Toggle("记一件事 · 北京时间 21:30", isOn: Binding(get: { reminders.dailyEnabled }, set: { reminders.setDailyEnabled($0) }))
            Toggle("每周与每月复盘", isOn: Binding(get: { reminders.enabled }, set: { reminders.setEnabled($0) }))
            LabeledContent("通知权限", value: reminders.authorization == .denied ? "未允许" : reminders.authorization == .notDetermined ? "未请求" : "已允许")
            if let next = reminders.nextDaily {
              LabeledContent("下一次轻提醒", value: next.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute()))
            }
            if reminders.authorization == .notDetermined || reminders.authorization == .denied {
              StudyButton(reminders.authorization == .denied ? "打开系统通知设置" : "允许手机通知") { Task { await reminders.requestPermission() } }
            }
            Text("当天已记录就跳过晚间提醒；点击提醒直接记一件事。").studyTypography(.footnote).foregroundStyle(.secondary)
          }
        #endif
        Section("学业服务 连接") {
          MobileConnectionSummary(session: session)
          if let endpoint = session.savedEndpoint {
            MobileAdaptiveValue(title: "当前服务", value: endpoint, monospaced: true)
            StudyButton(session.state == .online ? "刷新数据" : "重新连接", systemImage: "arrow.clockwise") {
              Task { await session.refresh() }
            }
            .disabled(session.state == .connecting)
            NavigationLink {
              MobileConnectionDetailView(session: session)
            } label: {
              StudyLabel("连接详情", systemImage: "info.circle")
            }
            NavigationLink {
              MobilePairingView(session: session)
            } label: {
              StudyLabel("更换 学业服务", systemImage: "arrow.triangle.2.circlepath")
            }
          } else {
            NavigationLink {
              MobilePairingView(session: session)
            } label: {
              StudyLabel("连接 学业服务", systemImage: "link.badge.plus")
                .studyTypography(.body, weight: .semibold)
                .foregroundStyle(MobileTheme.brand)
                .frame(minHeight: 44)
            }
          }
        }
        if !session.preservedQueues.isEmpty {
          Section("旧服务待审核草稿") {
            Text("旧计划、勾选和记录已独立保留。核对原仓库后再在当前计划逐项处理；不会自动重放。")
              .studyTypography(.footnote).foregroundStyle(.secondary)
            ForEach(session.preservedQueues) { archive in
              NavigationLink(archive.createdAt.formatted(date: .abbreviated, time: .shortened)) {
                MobileQueueMigrationReview(session: session, archive: archive)
              }
            }
          }
        }
        if session.isCloudService {
          Section("学业历史") {
            NavigationLink("云文件版本历史") { MobileCloudVersionsView(session: session).id(session.repositoryGeneration) }
            NavigationLink("完整文字历史（只读）") {
              List {
                ForEach(session.archivedHistory) { message in
                  VStack(alignment: .leading, spacing: 6) {
                    Text("\(message.role) · \(message.date.formatted())").studyTypography(.caption).foregroundStyle(.secondary)
                    Text(message.text).textSelection(.enabled)
                  }
                }
                if session.archivedHistoryLoading { ProgressView() }
                else if !session.archivedHistoryLoaded || session.archivedHistoryCursor != nil {
                  StudyButton("加载更多") { Task { await session.loadArchivedHistory() } }
                }
                if let error = session.archivedHistoryError { Text(error).foregroundStyle(.secondary) }
              }.navigationTitle("完整文字历史")
                .task { if !session.archivedHistoryLoaded { await session.loadArchivedHistory() } }
            }
          }
        }
        if session.hasPendingDrafts {
          Section("本机待提交草稿") {
            Text("交付物与时段勾选会在连接恢复后按顺序补交；周计划正文和日结仍由你确认后提交。")
              .studyTypography(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if session.legacyPendingToggleCount > 0 {
              StudyButton("审核旧版勾选操作", systemImage: "checklist.checked") {
                session.presentLegacyPendingReview()
              }
            }
            if session.pendingWeekDraft != nil || session.pendingDailyDraft != nil {
              NavigationLink("比较周计划 / 日结草稿") { MobilePendingPlanComparison(session: session) }
            }
            if session.pendingDeliveryCount + session.pendingPeriodCount
              > session.legacyPendingToggleCount
            {
              LabeledContent("勾选同步") {
                Text(
                  session.isReplayingPendingToggles
                    ? "正在同步" : session.state == .online ? "等待重试" : "等待连接"
                )
                .foregroundStyle(session.isReplayingPendingToggles ? MobileTheme.rail : .orange)
              }
              if session.pendingToggleSyncIssue != nil {
                StudyButton("重新加载并重试", systemImage: "arrow.clockwise") {
                  Task { await session.retryPendingToggles() }
                }
                .disabled(session.isReplayingPendingToggles)
              }
            }
            StudyButton("放弃本机草稿", role: .destructive) {
              showDiscardDraftsConfirmation = true
            }
          }
        }
        Section("隐私与缓存") {
          Text("手机保存只读缓存和待提交草稿。云模式的正式 Markdown、完整文字历史和版本记录保存在云服务；PDF 继续单独备份。")
            .studyTypography(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          StudyButton("清除本机缓存", role: .destructive) {
            showClearCacheConfirmation = true
          }
        }
      }
      .navigationTitle("更多")
      .confirmationDialog(
        "放弃所有本机待提交草稿？", isPresented: $showDiscardDraftsConfirmation, titleVisibility: .visible
      ) {
        StudyButton("放弃草稿", role: .destructive) { session.discardPendingDrafts() }
        StudyButton("取消", role: .cancel) {}
      } message: {
        Text("尚未写入正式仓库的周计划、日结、交付物和时段完成修改将被删除。")
      }
      .confirmationDialog(
        "清除本机缓存？", isPresented: $showClearCacheConfirmation, titleVisibility: .visible
      ) {
        StudyButton("清除缓存", role: .destructive) { session.clearLocalCache() }
        StudyButton("取消", role: .cancel) {}
      } message: {
        Text("将删除快照、资料缓存、对话输入和旧版待提交修改。“记一件事”的待同步记录、服务地址和配对身份保留。")
      }
      #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
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

private struct MobileBufferRulesView: View {
  @ObservedObject var session: MobileSession

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        MobileSnapshotFreshness(session: session)
        if let rules = session.snapshot?.week.bufferRules {
          MobileSurface {
            VStack(alignment: .leading, spacing: 14) {
              MobileSectionHeading(title: "缓冲与降级", detail: "按顺序执行", icon: "shield")
              if rules.isEmpty {
                MobileInlineNotice(text: "暂无缓冲与降级规则", symbol: "shield", tint: .secondary)
              } else {
                ForEach(Array(orderedRules(rules).enumerated()), id: \.element.id) { index, rule in
                  bufferRule(rule, number: index + 1)
                }
              }
            }
          }
        } else if session.savedEndpoint == nil {
          MobileSurface {
            VStack(alignment: .leading, spacing: 12) {
              MobileSectionHeading(title: "缓冲与降级", icon: "shield.lefthalf.filled")
              MobileInlineNotice(
                text: "先连接 学业服务，手机才会显示缓冲与降级规则。", symbol: "link.badge.plus", tint: .orange)
              NavigationLink {
                MobilePairingView(session: session)
              } label: {
                StudyLabel("连接 学业服务", systemImage: "link.badge.plus")
                  .frame(minHeight: 44)
              }
            }
          }
        } else {
          MobileEmptyState(
            title: "暂无计划缓存",
            message: "当前没有可读取的计划缓存，请刷新 学业服务。",
            symbol: "shield.lefthalf.filled",
            actionTitle: "刷新数据",
            action: { Task { await session.refresh() } }
          )
          .frame(minHeight: 420)
        }
      }
      .padding(MobileTheme.pageInset)
      .safeAreaPadding(.bottom, 8)
    }
    .background(MobileTheme.groupedBackground)
    .navigationTitle("缓冲与降级")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          Task { await session.refresh() }
        } label: {
          Image(systemName: "arrow.clockwise")
            .frame(width: 44, height: 44)
        }
        .disabled(session.state == .connecting)
        .accessibilityLabel("刷新缓冲与降级规则")
      }
    }
    .refreshable { await session.refresh() }
  }

  @ViewBuilder
  private func bufferRule(_ rule: BufferRuleSnapshot, number: Int) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text("\(number)")
        .studyTypography(.caption, weight: .semibold).monospacedDigit()
        .foregroundStyle(categoryTint(rule.category))
        .frame(width: 20, height: 20)
        .background(categoryTint(rule.category).opacity(0.12), in: Circle())
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(categoryTitle(rule.category))
          .studyTypography(.caption, weight: .semibold)
          .foregroundStyle(categoryTint(rule.category))
        Text(rule.text)
          .studyTypography(.subheadline)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private func orderedRules(_ rules: [BufferRuleSnapshot]) -> [BufferRuleSnapshot] {
    rules.enumerated().sorted {
      let lhs = (categoryRank($0.element.category), $0.offset)
      let rhs = (categoryRank($1.element.category), $1.offset)
      return lhs < rhs
    }.map(\.element)
  }

  private func categoryRank(_ category: String) -> Int {
    switch category {
    case "collision": 1
    case "minimum": 2
    default: 0
    }
  }

  private func categoryTitle(_ category: String) -> String {
    switch category {
    case "collision": "撞车降级"
    case "minimum": "最低底线"
    default: "日常缓冲"
    }
  }

  private func categoryTint(_ category: String) -> Color {
    switch category {
    case "collision": .orange
    case "minimum": .red
    default: MobileTheme.rail
    }
  }
}

private struct MobileConnectionDetailView: View {
  @ObservedObject var session: MobileSession

  private var presentation: MobileConnectionPresentation { .init(session: session) }
  private var planStatus: (String, Color) {
    if session.state == .online { return ("可用", MobileTheme.completion) }
    if session.snapshot != nil { return ("本机缓存", .secondary) }
    return ("不可用", .red)
  }
  private var chatStatus: (String, Color) {
    guard let health = session.health else { return ("等待连接", .secondary) }
    return session.isChatAvailable
      ? ("已就绪", MobileTheme.completion)
      : (health.chatIssueCode == "provider_auth_failed" ? ("需要重新登录", .orange) : ("尚未就绪", .orange))
  }

  var body: some View {
    List {
      Section {
        MobileConnectionSummary(session: session)
        if let issue = session.lastConnectionIssue, session.state != .online {
          Text(issue)
            .studyTypography(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Section("功能状态") {
        MobileConnectionStatusRow(
          title: "首页与计划", value: planStatus.0, symbol: "checklist", tint: planStatus.1)
        MobileConnectionStatusRow(
          title: "学业对话", value: chatStatus.0, symbol: "bubble.left.and.bubble.right",
          tint: chatStatus.1)
        MobileConnectionStatusRow(
          title: "仓库",
          value: session.health?.repositoryBound == true ? "已绑定" : "未绑定",
          symbol: "folder",
          tint: session.health?.repositoryBound == true ? MobileTheme.completion : .orange
        )
        MobileConnectionStatusRow(
          title: "已配对设备",
          value: session.health.map { "\($0.pairedDeviceCount) 台" } ?? "待连接",
          symbol: "iphone.and.arrow.forward",
          tint: session.health == nil ? .secondary : MobileTheme.brand
        )
      }
      Section("学业服务") {
        MobileAdaptiveValue(title: "连接地址", value: session.savedEndpoint ?? "尚未设置", monospaced: true)
        if let health = session.health {
          LabeledContent("服务版本", value: health.hostVersion)
          LabeledContent("API 版本", value: "v\(health.apiVersion)")
        }
      }
      if let health = session.health {
        Section {
          DisclosureGroup("技术信息") {
            if let threadID = health.activeThreadID {
              MobileAdaptiveValue(title: "固定学业任务", value: threadID, monospaced: true)
            }
            if let repositoryID = health.repositoryID {
              MobileAdaptiveValue(title: "仓库 ID", value: repositoryID, monospaced: true)
            }
          }
        }
      }
      Section("操作") {
        if session.savedEndpoint != nil {
          StudyButton("刷新数据", systemImage: "arrow.clockwise") {
            Task { await session.refresh() }
          }
        }
        NavigationLink(session.savedEndpoint == nil ? "连接 学业服务" : "更换 学业服务") {
          MobilePairingView(session: session)
        }
      }
    }
    .navigationTitle("连接详情")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}

private struct MobilePairingView: View {
  @ObservedObject var session: MobileSession
  @Environment(\.dismiss) private var dismiss
  @State private var endpoint: String
  @State private var pairingCode = ""
  @State private var deviceName = "我的 iPhone"
  @State private var pairingMessage: String?
  @State private var isPairing = false
  @State private var showDraftsConfirmation = false
  @FocusState private var focusedField: MobilePairingFocus?

  init(session: MobileSession) {
    self.session = session
    _endpoint = State(initialValue: session.savedEndpoint ?? "https://studyrocket.soulcourse.cn")
  }

  var body: some View {
    List {
      Section {
        Text(
          session.savedEndpoint == nil
            ? "填写云服务 HTTPS 地址和一次性配对码。"
            : "切换前会持久备份旧仓库的待提交草稿，保留在“旧服务待审核草稿”；不会自动写入新仓库。"
        )
        .studyTypography(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Section("配对信息") {
        TextField("学业服务 HTTPS 地址", text: $endpoint)
          .accessibilityLabel("服务地址")
          .focused($focusedField, equals: .endpoint)
          #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .submitLabel(.next)
          #endif
          .autocorrectionDisabled()
          .onSubmit { focusedField = .code }
        TextField("一次性配对码", text: $pairingCode)
          .accessibilityLabel("配对码")
          .focused($focusedField, equals: .code)
          #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .submitLabel(.next)
          #endif
          .autocorrectionDisabled()
          .onSubmit { focusedField = .deviceName }
        TextField("设备名称", text: $deviceName)
          .accessibilityLabel("设备名称")
          .focused($focusedField, equals: .deviceName)
          #if os(iOS)
            .submitLabel(.done)
          #endif
          .onSubmit { focusedField = nil }
      }
      Section {
        MobilePrimaryButton(
          title: isPairing ? "正在配对并连接" : "配对并连接",
          symbol: isPairing ? nil : "link.badge.plus"
        ) {
          requestPairing()
        }
        .disabled(isPairing)
        if isPairing {
          ProgressView("正在检查 学业服务 并配对")
            .frame(maxWidth: .infinity)
        }
        if let pairingMessage {
          Text(pairingMessage)
            .studyTypography(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .navigationTitle(session.savedEndpoint == nil ? "连接 学业服务" : "更换 学业服务")
    .confirmationDialog(
      "更换 学业服务？", isPresented: $showDraftsConfirmation, titleVisibility: .visible
    ) {
      StudyButton("继续更换", role: .destructive) { pair() }
      StudyButton("取消", role: .cancel) {}
    } message: {
      Text("本机待提交草稿属于当前仓库。切换前会保留完整副本供逐项审核，不会自动提交到新仓库。")
    }
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      .scrollDismissesKeyboard(.interactively)
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          StudyButton("完成") { focusedField = nil }
        }
      }
    #endif
  }

  private func requestPairing() {
    guard !isPairing else { return }
    focusedField = nil
    pairingMessage = nil
    guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
      MobileEndpointError.accepts(url)
    else {
      pairingMessage = MobileEndpointError.invalidEndpoint.localizedDescription
      return
    }
    guard !pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      pairingMessage = "请输入 学业服务 窗口中的一次性配对码。"
      return
    }
    if session.hasPendingDrafts && session.savedEndpoint != nil {
      showDraftsConfirmation = true
    } else {
      pair()
    }
  }

  private func pair() {
    guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return
    }
    isPairing = true
    Task {
      defer { isPairing = false }
      do {
        try await session.pair(
          endpoint: url,
          code: pairingCode.trimmingCharacters(in: .whitespacesAndNewlines),
          deviceName: deviceName.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
      } catch {
        pairingMessage = error.localizedDescription
      }
    }
  }
}

private struct MobileDocumentDetailView: View {
  @ObservedObject var session: MobileSession
  let documentKey: String
  let title: String
  @State private var isLoading = false
  @State private var showsSource = false

  private var detail: DocumentDetail? { session.documentDetails[documentKey] }

  var body: some View {
    GeometryReader { container in
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let detail {
          VStack(alignment: .leading, spacing: 6) {
            StudyLabel("本机可读副本", systemImage: "doc.text")
              .studyTypography(.subheadline, weight: .medium)
            Text("获取于 \(detail.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
              .studyTypography(.footnote).foregroundStyle(.secondary)
            Text(session.state == .online
                 ? "刷新会从学业服务读取内容；更新成功后自动显示。"
                 : "当前离线，显示上次获取的内容。")
              .studyTypography(.footnote).foregroundStyle(.secondary)
          }
          .fixedSize(horizontal: false, vertical: true)
          if showsSource {
            Text(verbatim: detail.markdown)
              .studyTypography(.callout).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            MobileMarkdownView(text: detail.markdown, availableWidth: max(1, container.size.width - 2 * MobileTheme.pageInset)).textSelection(.enabled)
          }
        } else if isLoading {
          ProgressView("正在读取资料")
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
          MobileEmptyState(
            title: "暂时无法读取",
            message: "连接学业服务后重试；之前打开过的资料可从本机副本读取。",
            symbol: "doc.text.magnifyingglass",
            actionTitle: "重新读取",
            action: { Task { await load() } }
          )
        }
      }
      .padding(MobileTheme.pageInset)
    }
    .background(MobileTheme.groupedBackground)
    .navigationTitle(title)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        StudyButton(showsSource ? "阅读正文" : "查看原文", systemImage: showsSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right") {
          showsSource.toggle()
        }.disabled(detail == nil)
        StudyButton("刷新资料", systemImage: "arrow.clockwise") { Task { await load() } }
          .disabled(isLoading)
      }
    }
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .refreshable { await load() }
    .task(id: session.repositoryGeneration) { await load() }
    }
  }

  private func load() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    _ = await session.document(for: documentKey)
  }
}

extension Array {
  fileprivate subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

private struct MobileCloudVersionsView: View {
  @ObservedObject var session: MobileSession
  @State private var versions: [CloudVersionEntry] = []
  @State private var cursor: Int?
  @State private var loaded = false
  @State private var loading = false
  @State private var error = ""
  @State private var selectedText = ""
  @State private var showingText = false
  var body: some View {
    List {
      Text("查看已确认保存后的云版本。历史只读，恢复内容须重新编辑并通过版本校验保存。")
        .studyTypography(.footnote).foregroundStyle(.secondary)
      ForEach(versions) { version in
        DisclosureGroup(version.date.formatted()) {
          ForEach(version.paths, id: \.self) { path in
            StudyButton(path) { Task {
              do { selectedText = try await session.cloudVersion(id: version.id, path: path).content; showingText = true }
              catch { self.error = error.localizedDescription }
            } }
          }
        }
      }
      if loading { ProgressView() }
      else if !loaded || cursor != nil { StudyButton("加载更多版本") { Task { await load() } } }
      if !error.isEmpty { Text(error).studyTypography(.caption) }
    }.navigationTitle("云版本历史")
      .task { if !loaded { await load() } }
      .sheet(isPresented: $showingText) { NavigationStack {
        ScrollView { Text(selectedText).textSelection(.enabled).padding() }
          .navigationTitle("历史版本（只读）")
          .toolbar { StudyButton("关闭") { showingText = false } }
      } }
  }
  private func load() async {
    guard !loading else { return }; loading = true; defer { loading = false }
    do { let page = try await session.cloudVersions(after: cursor ?? 0); versions.append(contentsOf: page.versions); cursor = page.nextCursor; loaded = true }
    catch { self.error = error.localizedDescription }
  }
}


private struct MobileQueueMigrationReview: View {
  @ObservedObject var session: MobileSession
  let archive: MobileSession.PreservedQueue
  @State private var selected: MobileQueueMigrationItem?
  @State private var submitting = false
  @State private var issue: String?
  var body: some View {
    List {
      Section("原服务与仓库") {
        Text(archive.endpoint?.absoluteString ?? "地址待核实").textSelection(.enabled)
        Text(archive.repositoryID ?? "身份待核实").studyTypography(.caption).textSelection(.enabled)
        Text("每项单独确认。原始归档始终保留；没有可靠基线的整份草稿只供对照。").studyTypography(.footnote).foregroundStyle(.secondary)
      }
      if let issue { Section { Text(issue).foregroundStyle(.orange) } }
      ForEach(session.queueMigrationItems(archive)) { item in
        Section(item.title) {
          DisclosureGroup("原始内容与目标") { Text(item.original).studyTypography(.callout).textSelection(.enabled) }
          DisclosureGroup("当前云内容") { Text(item.current).studyTypography(.callout).textSelection(.enabled) }
          Text(item.reason).studyTypography(.footnote).foregroundStyle(.secondary)
          if item.canSubmit {
            StudyButton("审核并处理这一项") { selected = item }.disabled(submitting)
          }
        }
      }
      Section {
        DisclosureGroup("完整原始归档（只读）") {
          Text(session.preservedQueueText(archive)).studyTypography(.callout).textSelection(.enabled)
        }
      }
    }
    .navigationTitle("旧队列逐项审核")
    .confirmationDialog("确认迁移这一项到当前云仓库？", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
      if let item = selected {
        StudyButton("确认提交这一项") {
          submitting = true; issue = nil; selected = nil
          Task { @MainActor in
            defer { submitting = false }
            do { try await session.submitQueueMigrationItem(archive, itemID: item.id) }
            catch { issue = error.localizedDescription }
          }
        }
      }
      StudyButton("取消", role: .cancel) { selected = nil }
    } message: { Text(selected?.original ?? "") }
  }
}


private struct MobilePendingPlanComparison: View {
  @ObservedObject var session: MobileSession
  @State private var confirming = false
  @State private var submitting = false
  private func readable<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
      return "无法显示此内容，请查看原始草稿。"
    }
    return text
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("请对照原稿与云内容。提交始终使用原始基线，发生冲突会保留草稿；不会把旧稿套用新版本。")
        if let draft = session.pendingWeekDraft {
          Text("周计划").studyTypography(.headline)
          if let current = session.snapshot?.week {
            StudyProposalDiffView(original: readable(draft), proposed: readable(current),
                                  originalTitle: "本机草稿", proposedTitle: "当前服务版本")
          } else {
            Text(readable(draft)).studyTypography(.callout).textSelection(.enabled)
            Text("当前服务版本尚未读取，暂时无法比较。").studyTypography(.footnote).foregroundStyle(.secondary)
          }
        }
        if let draft = session.pendingDailyDraft {
          Text("旧版日结").studyTypography(.headline)
          if let current = session.snapshot?.daily {
            StudyProposalDiffView(original: readable(draft), proposed: readable(current),
                                  originalTitle: "本机草稿", proposedTitle: "当前服务版本")
          } else {
            Text(readable(draft)).studyTypography(.callout).textSelection(.enabled)
            Text("当前服务版本尚未读取，暂时无法比较。").studyTypography(.footnote).foregroundStyle(.secondary)
          }
        }
        DisclosureGroup("原始草稿与基线校验说明") {
          Text(session.pendingPlanComparison).studyTypography(.callout).textSelection(.enabled)
        }
        if let issue = session.pendingToggleSyncIssue { Text(issue).foregroundStyle(.orange) }
        StudyButton("确认按原基线提交") { confirming = true }.disabled(submitting || session.state != .online)
      }.padding()
    }.navigationTitle("草稿内容对照")
    .confirmationDialog("按原始基线提交以上草稿？", isPresented: $confirming, titleVisibility: .visible) {
      StudyButton("确认提交") {
        submitting = true
        Task { @MainActor in await session.commitPendingDrafts(); submitting = false }
      }
      StudyButton("取消", role: .cancel) {}
    }
  }
}

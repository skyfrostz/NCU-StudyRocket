import Foundation
import MarkdownUI
import StudyRocketShared
import SwiftUI

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
      MobileTimetableView(session: session)
        .tabItem { Label("课表", systemImage: "calendar.badge.clock") }
        .tag(2)
      MobilePlanView(session: session) { selectedTab = $0 }
        .tabItem { Label("计划", systemImage: "calendar.badge.clock") }
        .tag(3)
      MobileDailyView(session: session)
        .tabItem { Label("复盘", systemImage: "checkmark.circle.fill") }
        .tag(4)
      MobileMoreView(session: session)
        .tabItem { Label("更多", systemImage: "ellipsis.circle") }
        .tag(5)
    }
    .tint(MobileTheme.brand)
    .onOpenURL { url in
      guard let destination = MobileWidgetDestination.parse(url) else { return }
      selectedTab = destination.tabIndex
    }
    #if os(iOS)
      .task {
        await reminders.configure()
        await session.refresh()
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
          Text("这些操作来自旧版手机缓存。请确认后再写入 Mac；任务已变化的项目不会自动同步。")
            .font(.footnote)
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
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                  Text(item.detail)
                    .font(.caption)
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
          Button("全部丢弃", role: .destructive) {
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
          Button("暂不处理") {
            session.deferLegacyPendingReview()
            dismiss()
          }
          .disabled(isApplying)
        }
      }
      .confirmationDialog(
        "丢弃全部旧版操作？", isPresented: $showDiscardConfirmation, titleVisibility: .visible
      ) {
        Button("全部丢弃", role: .destructive) {
          session.discardLegacyPendingToggles()
          dismiss()
        }
        Button("取消", role: .cancel) {}
      } message: {
        Text("只会删除这些尚未写入 Mac 的旧版勾选操作，无法撤销。")
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
          .font(.caption2.weight(.medium))
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
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Button {
          Task { await session.refresh() }
        } label: {
          Image(systemName: "arrow.clockwise")
            .font(.body.weight(.semibold))
            .frame(width: 36, height: 36)
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

private struct MobileHomeView: View {
  @ObservedObject var session: MobileSession
  let onNavigate: (Int) -> Void
  @State private var deliveryChapter = MobileDeliveryChapterState()
  @State private var deliveryChapterTask: Task<Void, Never>?
  @State private var periodTargets: [String: Bool] = [:]
  @State private var periodTasks: [String: Task<Void, Never>] = [:]
  @State private var deliveryNotice: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
      VStack(alignment: .leading, spacing: 18) {
        homeHeader
        quickActions

        Spacer(minLength: 0)

        MobileUnframedConnectionPrompt {
          onNavigate(5)
        }
        .frame(maxWidth: .infinity)

        Spacer(minLength: 0)
      }
      .padding(MobileTheme.pageInset)
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
    }
  }

  private var homeContent: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          homeHeader
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
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                  Button {
                    onNavigate(1)
                  } label: {
                    Label("和学业助理确认下一步", systemImage: "arrow.right")
                      .font(.subheadline.weight(.medium))
                      .frame(minHeight: 44)
                      .contentShape(Rectangle())
                  }
                  .buttonStyle(.borderless)
                case .completed:
                  Label("今日安排已完成", systemImage: "checkmark.seal.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(MobileTheme.completion)
                    .frame(minHeight: 44, alignment: .leading)
                case .unplanned:
                  MobileInlineNotice(text: "今日尚未安排首要任务，可在周计划中补充。", symbol: "calendar.badge.plus")
                }
              }
            }

            MobileSurface {
              VStack(alignment: .leading, spacing: 14) {
                MobileSectionHeading(
                  title: "今日安排", detail: "上午 · 中午 · 晚上",
                  icon: "point.3.connected.trianglepath.dotted")
                MobileTodayChecklist(
                  periods: home.periods,
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
                if let issue = session.lastConnectionIssue, session.state != .online {
                  MobileInlineNotice(
                    text: issue,
                    symbol: "exclamationmark.arrow.triangle.2.circlepath",
                    tint: .orange
                  )
                }
              }
            }

            MobileSurface {
              VStack(alignment: .leading, spacing: 10) {
                MobileSectionHeading(title: "本周交付物", detail: "显示全部真实交付物", icon: "checklist")
                if let deliveryNotice {
                  MobileInlineNotice(text: deliveryNotice, symbol: "link.badge.plus", tint: .orange)
                }
                MobileDeliveryOverview(
                  deliveries: snapshot.week.deliveries,
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
                    ?? "暂时无法连接 Mac Host。确认 Host 已启动、Tailscale 已连接并已启用 Serve。",
                  symbol: "wifi.exclamationmark",
                  tint: .orange
                )
                HStack {
                  Button("刷新") { Task { await session.refresh() } }
                  Button("检查连接设置") { onNavigate(5) }
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
      }
      .refreshable { await session.refresh() }
    }
  }

  private var homeHeader: some View {
    HStack(alignment: .top, spacing: 12) {
      MobileBrandMark(size: 46)
      VStack(alignment: .leading, spacing: 3) {
        Text("NCU StudyRocket")
          .font(.system(.title2, design: .rounded, weight: .bold))
          .lineLimit(2)
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
      MobileQuickAction(
        title: "学业对话", symbol: "bubble.left.and.bubble.right", action: { onNavigate(1) })
      MobileQuickAction(title: "周计划", symbol: "calendar", action: { onNavigate(3) })
      MobileQuickAction(title: "写日结", symbol: "checkmark.circle", action: { onNavigate(4) })
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
        && Self.dateNumbers(in: delivery.dateLabel ?? "") == Self.dateNumbers(in: home.dateLabel)
        && matchingTaskKeys(for: delivery).contains(taskMatchKey(periodID: period.id, taskID: task.id))
    }) {
      return true
    }
    guard let dayID else { return task.isCompleted }
    return session.effectiveTaskCompletion(dayID: dayID, period: period, task: task)
  }

  private func requestDeliveryToggle(_ delivery: DeliverySnapshot) {
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
    let hasMatch = !matchingTaskKeys(for: delivery).isEmpty
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
      let result = await session.toggleDelivery(delivery, isCompleted: true, mutation: mutation)
      guard !Task.isCancelled else { return }
      deliveryChapter.resolve(
        result,
        for: mutation,
        queuedOfflineCompletesAll: completesAll
      )

      switch result {
      case .confirmed(let snapshot):
        if !hasMatch,
          snapshot.week.deliveries.first(where: { $0.id == delivery.id })?.isCompleted == true
        {
          deliveryNotice = "交付物已完成，但未找到同日可联动的时段安排。"
        }
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
    guard let dateLabel = delivery.dateLabel, let week = session.snapshot?.week else { return [] }
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
              ? "当前离线缓存来自旧版协议，不含课表数据。连接 Mac 后刷新。"
              : "Mac Host 尚未返回课表数据，请刷新后重试。",
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
            Label(
              "今日无课程安排", systemImage: holidays.isEmpty ? "calendar" : "calendar.badge.checkmark"
            )
            .font(.body)
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
        .font(.body.weight(.medium))
        .foregroundStyle(entry.kind == .course ? MobileTheme.brand : .secondary)
        .frame(width: 22, height: 22)
        .padding(.top, 1)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
          Text(entry.timeText)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          if let periodLabel = entry.periodLabel, !periodLabel.isEmpty {
            Text(entry.periodText(periodLabel))
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
        }
        Text(title.primary)
          .font(.body.weight(entry.kind == .course ? .medium : .regular))
          .foregroundStyle(entry.kind == .course ? .primary : .secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let secondary = title.secondary {
          Text(secondary)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let location = locationText {
          Label(location, systemImage: "mappin.and.ellipse")
            .font(.caption)
            .foregroundStyle(confirmedLocation == nil ? .tertiary : .secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let instructor = instructorText {
          Label(instructor, systemImage: "person")
            .font(.caption)
            .foregroundStyle(confirmedInstructor == nil ? .tertiary : .secondary)
            .fixedSize(horizontal: false, vertical: true)
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
  @ObservedObject var session: MobileSession
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var detail: DocumentDetail?
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
          if let detail, let range = availableWeekRange, let snapshot = displayedSnapshot {
            timetableContent(detail: detail, range: range, snapshot: snapshot)
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
      .navigationTitle("课表")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
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
            text: "暂时无法读取完整课表。请连接 Mac Host 后刷新；课表文件需要在 Mac 端的课表页面导入。",
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
  let label: String
  let range: ClosedRange<Int>
  let selectedWeek: Int
  let dateRange: String
  let onSelect: (Int) -> Void

  var body: some View {
    VStack(spacing: 4) {
      ZStack {
        Menu {
          ForEach(Array(range), id: \.self) { week in
            Button {
              onSelect(week)
            } label: {
              if week == selectedWeek {
                Label("第\(week)周", systemImage: "checkmark")
              } else {
                Text("第\(week)周")
              }
            }
          }
        } label: {
          HStack(spacing: 5) {
            Text(label)
              .font(.headline)
              .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
          .frame(maxWidth: .infinity, minHeight: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 52)
        .accessibilityLabel("教学周")
        .accessibilityValue(label)
        .accessibilityHint("选择要查看的教学周")

        HStack(spacing: 0) {
          navigationButton(symbol: "chevron.left", label: "上一教学周") {
            onSelect(selectedWeek - 1)
          }
          .disabled(selectedWeek <= range.lowerBound)

          Spacer(minLength: 0)

          navigationButton(symbol: "chevron.right", label: "下一教学周") {
            onSelect(selectedWeek + 1)
          }
          .disabled(selectedWeek >= range.upperBound)
        }
      }
      .frame(maxWidth: .infinity, minHeight: 44)

      Text(dateRange)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  private func navigationButton(symbol: String, label: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.body.weight(.semibold))
        .frame(width: 44, height: 44)
        .contentShape(Circle())
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
          .font(.caption2.weight(.semibold))
          .lineLimit(1)
        Text(dayNumber(for: day))
          .font(.system(.title3, design: .rounded, weight: .bold))
          .lineLimit(1)
      }
      .frame(
        width: dynamicTypeSize.isAccessibilitySize ? 70 : 52,
        height: dynamicTypeSize.isAccessibilitySize ? 76 : 58
      )
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
        Label(
          holidays.isEmpty ? "当天无课程安排" : "当天为假期",
          systemImage: holidays.isEmpty ? "calendar" : "calendar.badge.checkmark"
        )
        .font(.subheadline)
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
          .lineLimit(2)
          .multilineTextAlignment(.center)
      }
      .foregroundStyle(MobileTheme.brand)
      .frame(maxWidth: .infinity, minHeight: 60)
      .background(
        MobileTheme.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
              .frame(width: 44, height: 44)
              .contentShape(Rectangle())
          }
          .accessibilityLabel("快捷报告")
        }
        .padding(.horizontal, MobileTheme.pageInset)
        .padding(.vertical, 8)
        if let message = session.chatUnavailableMessage ?? session.lastChatIssue {
          HStack(spacing: 10) {
            MobileInlineNotice(
              text: message, symbol: "bubble.left.and.exclamationmark", tint: .orange)
            if session.lastFailedChatText != nil {
              Button("重新编辑并发送") { session.restoreFailedChatDraft() }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
                .padding(.horizontal, MobileTheme.pageInset)
                .padding(.vertical, 18)
              }
              .background(MobileTheme.groupedBackground)
              #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                  max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
                } action: { _, distance in
                  let shouldShow = distance > (showJumpToLatest ? 48 : 120)
                  if shouldShow != showJumpToLatest { showJumpToLatest = shouldShow }
                }
              #else
                .coordinateSpace(name: "mobile-chat-scroll")
                .onPreferenceChange(MobileChatBottomPreference.self) { bottomY in
                  showJumpToLatest = bottomY > container.size.height + 72
                }
              #endif
              .simultaneousGesture(TapGesture().onEnded { isComposerFocused = false })
              .onChange(of: session.chatRevision) { _, _ in
                guard !showJumpToLatest else { return }
                proxy.scrollTo("chat-bottom", anchor: .bottom)
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
            .disabled(!session.isChatAvailable && !session.isChatBusy)
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
                await session.sendDraft()
              }
            }
          } label: {
            Image(systemName: session.isChatBusy ? "stop.circle.fill" : "arrow.up.circle.fill")
              .font(.system(size: 31, weight: .semibold))
              .frame(width: 44, height: 44)
          }
          .disabled(
            (!session.isChatAvailable && !session.isChatBusy)
              || (!session.isChatBusy
                && session.inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          )
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
        Button("Face ID 确认并应用") {
          Task { await session.applyProposals(ids: Array(selectedIDs)) }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(selectedIDs.isEmpty || !session.canApplyProposals)
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
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        isSelected ? "取消选择 \(proposal.relativePath)" : "选择 \(proposal.relativePath)")
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
            .font(.subheadline.weight(.medium))
        }
        Text(progress.detail)
          .font(.footnote)
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
        Label(
          isExpanded ? "收起过程（\(messages.count)）" : "查看过程（\(messages.count)）",
          systemImage: isExpanded ? "chevron.down" : "chevron.right"
        )
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
  @State private var completedDeliveriesExpanded = false
  @State private var futureRowsExpanded = false
  @State private var assignment: MobilePendingTaskAssignment?

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          planHeader
          MobileSnapshotFreshness(session: session)
          if let week = session.snapshot?.week, !week.days.isEmpty {
            scheduleContent(week)
            deliveriesContent(week)
            if !week.futureRows.isEmpty {
              futureContent(week.futureRows)
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
      .navigationTitle("周计划")
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
      Text("周计划")
        .font(.system(.title2, design: .rounded, weight: .bold))
      Text(session.snapshot?.home.dateLabel ?? "等待 Mac Host")
        .font(.subheadline)
        .foregroundStyle(.secondary)
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
  private func deliveriesContent(_ week: WeeklyPlanSnapshot) -> some View {
    let openDeliveries = week.deliveries.filter { !session.effectiveDeliveryCompletion($0) }
    let completedDeliveries = week.deliveries.filter { session.effectiveDeliveryCompletion($0) }
    MobileSurface {
      VStack(alignment: .leading, spacing: 12) {
        MobileSectionHeading(title: "本周交付物", detail: "学习产出", icon: "checklist")
        if week.deliveries.isEmpty {
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
                  .font(.subheadline)
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
              Text("已完成").font(.subheadline.weight(.semibold))
              Spacer()
              Text("\(completedDeliveries.count)")
                .font(.caption.monospacedDigit())
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
          Label("更远日期", systemImage: "calendar.badge.clock")
            .font(.subheadline.weight(.semibold))
          Spacer()
          Text("\(rows.count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(minHeight: 44)
      }
    }
  }

  @ViewBuilder
  private func daySchedule(_ day: DaySnapshot) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text(day.dateLabel)
          .font(.system(.title3, design: .rounded, weight: .semibold))
        if day.id == Self.todayIDFormatter.string(from: .now) {
          Text("今日")
            .font(.caption.weight(.semibold))
            .foregroundStyle(MobileTheme.brand)
        }
        Spacer(minLength: 0)
      }
      ForEach(Array(day.slots.enumerated()), id: \.element.id) { index, slot in
        scheduleSlot(slot, index: index, dayID: day.id)
      }
      pendingTasks(day)
    }
  }

  @ViewBuilder
  private func pendingTasks(_ day: DaySnapshot) -> some View {
    let tasks = PeriodTaskParser.tasks(from: day.unassigned)
    if !tasks.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Label("待分时", systemImage: "tray.full")
          .font(.caption.weight(.semibold))
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
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
              Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
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
      Text(row.dateLabel)
        .font(.system(.title3, design: .rounded, weight: .semibold))
      ForEach(Array(row.slots.enumerated()), id: \.element.id) { index, slot in
        scheduleSlot(slot, index: index, dayID: nil)
      }
      if !row.unassigned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Label {
          Text(PeriodTaskParser.displayText(from: row.unassigned))
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "tray.full")
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
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
      Label(slot.title, systemImage: slotSymbol(for: index))
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(minHeight: 28, alignment: .leading)
      if slot.tasks.isEmpty {
        Text("未安排")
          .font(.subheadline)
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
                .font(.subheadline)
                .foregroundStyle(completed ? .secondary : .primary)
                .strikethrough(completed)
                .fixedSize(horizontal: false, vertical: true)
              if isPending {
                Text("待同步")
                  .font(.caption2.weight(.semibold))
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
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        Text(delivery.text)
          .font(.subheadline)
          .strikethrough(completed)
          .foregroundStyle(completed ? .secondary : .primary)
          .fixedSize(horizontal: false, vertical: true)
        if pending {
          Text("待同步")
            .font(.caption2.weight(.semibold))
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
            Label("该时段已有 \(targetPeriod.tasks.count) 项安排", systemImage: "exclamationmark.triangle")
              .font(.footnote)
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
          Button("取消") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("安排") {
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
              MobileFactField(
                title: "完成交付物", symbol: "checklist", placeholder: "完成了什么", text: $deliverables,
                field: .deliverables, focus: $focusedField, multiline: true)
              MobileFactField(
                title: "净学习时长", symbol: "clock", placeholder: "例如 3 小时 20 分钟", text: $studyTime,
                field: .studyTime, focus: $focusedField)
              MobileFactField(
                title: "睡眠", symbol: "bed.double", placeholder: "入睡 / 起床时间", text: $sleep,
                field: .sleep, focus: $focusedField)
              MobileFactField(
                title: "运动", symbol: "figure.run", placeholder: "项目和时长", text: $exercise,
                field: .exercise, focus: $focusedField)
              MobileFactField(
                title: "明日第一任务", symbol: "arrow.right.circle", placeholder: "从哪一步开始",
                text: $firstTask, field: .firstTask, focus: $focusedField, multiline: true)
              Button("保存行为账") {
                guard incomingRevision == nil else { return }
                focusedField = nil
                let date = currentDailyDate
                guard !date.isEmpty else {
                  saveMessage = "尚未取得有效日期，请先连接并刷新 Mac Host。"
                  return
                }
                let entry = DailySnapshot(
                  date: date, deliverables: deliverables, studyTime: studyTime, sleep: sleep,
                  exercise: exercise, firstTask: firstTask)
                isSaving = true
                Task {
                  await session.saveDaily(entry)
                  if session.state == .online { loadLatestSnapshot() }
                  saveMessage = session.state == .online ? "已提交保存。" : "已保存到本机草稿，联网后可比较并提交。"
                  isSaving = false
                }
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
              .disabled(incomingRevision != nil || isSaving || currentDailyDate.isEmpty)
              if let saveMessage {
                MobileInlineNotice(
                  text: saveMessage, symbol: "checkmark.circle",
                  tint: session.state == .online ? .teal : .orange)
              }
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
    guard !isSaving, let snapshot = session.snapshot, snapshot.revision != loadedRevision else {
      return
    }
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

@MainActor
private struct MobileConnectionPresentation {
  let title: String
  let detail: String
  let symbol: String
  let tint: Color

  init(session: MobileSession) {
    switch session.state {
    case .online where session.isChatAvailable:
      title = "已连接 Mac"
      detail = "首页、计划与学业对话均可用"
      symbol = "checkmark.circle.fill"
      tint = MobileTheme.completion
    case .online:
      title = "首页可用 · 对话未就绪"
      detail = session.chatUnavailableMessage ?? "Mac Host 正在重试学业对话协议自检"
      symbol = "bubble.left.and.exclamationmark.fill"
      tint = .orange
    case .offline:
      title = session.state.title
      detail = "正在使用本机缓存，可重新连接 Mac"
      symbol = "icloud.slash"
      tint = .secondary
    case .connecting:
      title = "正在连接 Mac"
      detail = "正在验证 Host 与配对身份"
      symbol = "arrow.triangle.2.circlepath"
      tint = .orange
    case .failed(let message):
      title = "连接失败"
      detail = session.lastConnectionIssue ?? message
      symbol = "exclamationmark.triangle.fill"
      tint = .red
    case .unconfigured:
      title = "尚未连接 Mac"
      detail = "输入 Mac Host 的 HTTPS 地址和一次性配对码"
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
        .font(.title3)
        .foregroundStyle(presentation.tint)
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(presentation.title)
          .font(.body.weight(.semibold))
        Text(presentation.detail)
          .font(.footnote)
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
      Text(title)
      Spacer(minLength: 8)
      Text(value)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(tint)
        .multilineTextAlignment(.trailing)
    }
    .frame(minHeight: 36)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title)，\(value)")
  }
}

private struct MobileMoreView: View {
  @ObservedObject var session: MobileSession
  @State private var showDiscardDraftsConfirmation = false
  @State private var showClearCacheConfirmation = false
  #if os(iOS)
    @ObservedObject private var reminders = MobileReminderScheduler.shared
  #endif

  var body: some View {
    NavigationStack {
      List {
        Section("Mac Host 连接") {
          MobileConnectionSummary(session: session)
          if let endpoint = session.savedEndpoint {
            LabeledContent("当前 Host") {
              Text(endpoint)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            }
            Button(session.state == .online ? "刷新数据" : "重新连接", systemImage: "arrow.clockwise") {
              Task { await session.refresh() }
            }
            .disabled(session.state == .connecting)
            NavigationLink {
              MobileConnectionDetailView(session: session)
            } label: {
              Label("连接详情", systemImage: "info.circle")
            }
            NavigationLink {
              MobilePairingView(session: session)
            } label: {
              Label("更换 Mac Host", systemImage: "arrow.triangle.2.circlepath")
            }
          } else {
            NavigationLink {
              MobilePairingView(session: session)
            } label: {
              Label("连接 Mac Host", systemImage: "link.badge.plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(MobileTheme.brand)
                .frame(minHeight: 44)
            }
          }
        }
        Section("计划") {
          NavigationLink {
            MobileBufferRulesView(session: session)
          } label: {
            Label("缓冲与降级", systemImage: "shield")
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
                      .font(.body.weight(.medium))
                    Spacer(minLength: 0)
                  }
                  .frame(minHeight: 44)
                }
              }
            }
          }
        }
        if session.hasPendingDrafts {
          Section("本机待提交草稿") {
            Text("交付物与时段勾选会在连接恢复后按顺序补交；周计划正文和日结仍由你确认后提交。")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if session.legacyPendingToggleCount > 0 {
              Button("审核旧版勾选操作", systemImage: "checklist.checked") {
                session.presentLegacyPendingReview()
              }
            }
            if session.pendingWeekDraft != nil || session.pendingDailyDraft != nil {
              Button("比较并提交周计划 / 日结", systemImage: "arrow.up.doc") {
                Task { await session.commitPendingDrafts() }
              }
              .disabled(session.state != .online)
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
                Button("重新加载并重试", systemImage: "arrow.clockwise") {
                  Task { await session.retryPendingToggles() }
                }
                .disabled(session.isReplayingPendingToggles)
              }
            }
            Button("放弃本机草稿", role: .destructive) {
              showDiscardDraftsConfirmation = true
            }
          }
        }
        Section("隐私与缓存") {
          Text("手机只保留最近一次快照、当前输入草稿、待提交草稿，以及你打开过的只读学习资料和课表缓存；PDF、Git 和完整聊天历史留在 Mac。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button("清除本机缓存", role: .destructive) {
            showClearCacheConfirmation = true
          }
        }
        #if os(iOS)
          Section("提醒") {
            Toggle(
              "手机日 / 周 / 月复盘提醒",
              isOn: Binding(get: { reminders.enabled }, set: { reminders.setEnabled($0) }))
            Text("每日 21:30、每周日 19:30、每月最后一天 19:30 独立提醒；点击后只预填问题，不自动发送。")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        #endif
      }
      .navigationTitle("更多")
      .confirmationDialog(
        "放弃所有本机待提交草稿？", isPresented: $showDiscardDraftsConfirmation, titleVisibility: .visible
      ) {
        Button("放弃草稿", role: .destructive) { session.discardPendingDrafts() }
        Button("取消", role: .cancel) {}
      } message: {
        Text("尚未写入 Mac 的周计划、日结、交付物和时段完成修改将被删除。")
      }
      .confirmationDialog(
        "清除本机缓存？", isPresented: $showClearCacheConfirmation, titleVisibility: .visible
      ) {
        Button("清除缓存", role: .destructive) { session.clearLocalCache() }
        Button("取消", role: .cancel) {}
      } message: {
        Text("将删除快照、已读资料缓存、输入草稿和待提交草稿；Host 地址与配对身份保留。")
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
                text: "先连接 Mac Host，手机才会显示缓冲与降级规则。", symbol: "link.badge.plus", tint: .orange)
              NavigationLink {
                MobilePairingView(session: session)
              } label: {
                Label("连接 Mac Host", systemImage: "link.badge.plus")
                  .frame(minHeight: 44)
              }
            }
          }
        } else {
          MobileEmptyState(
            title: "暂无计划缓存",
            message: "当前没有可读取的计划缓存，请刷新 Mac Host。",
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
        .font(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(categoryTint(rule.category))
        .frame(width: 20, height: 20)
        .background(categoryTint(rule.category).opacity(0.12), in: Circle())
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(categoryTitle(rule.category))
          .font(.caption.weight(.semibold))
          .foregroundStyle(categoryTint(rule.category))
        Text(rule.text)
          .font(.subheadline)
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
            .font(.footnote)
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
      Section("Mac Host") {
        LabeledContent("连接地址") {
          Text(session.savedEndpoint ?? "尚未设置")
            .font(.caption.monospaced())
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
        }
        if let health = session.health {
          LabeledContent("Host 版本", value: health.hostVersion)
          LabeledContent("API 版本", value: "v\(health.apiVersion)")
        }
      }
      if let health = session.health {
        Section {
          DisclosureGroup("技术信息") {
            if let threadID = health.activeThreadID {
              LabeledContent("固定学业任务") {
                Text(threadID)
                  .font(.caption2.monospaced())
                  .multilineTextAlignment(.trailing)
                  .textSelection(.enabled)
              }
            }
            if let repositoryID = health.repositoryID {
              LabeledContent("仓库 ID") {
                Text(repositoryID)
                  .font(.caption2.monospaced())
                  .multilineTextAlignment(.trailing)
                  .textSelection(.enabled)
              }
            }
          }
        }
      }
      Section("操作") {
        if session.savedEndpoint != nil {
          Button("刷新数据", systemImage: "arrow.clockwise") {
            Task { await session.refresh() }
          }
        }
        NavigationLink(session.savedEndpoint == nil ? "连接 Mac Host" : "更换 Mac Host") {
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
  @State private var showDraftsConfirmation = false
  @FocusState private var focusedField: MobilePairingFocus?

  init(session: MobileSession) {
    self.session = session
    _endpoint = State(initialValue: session.savedEndpoint ?? "https://")
  }

  var body: some View {
    List {
      Section {
        Text(
          session.savedEndpoint == nil
            ? "在 Mac Host 窗口复制私有 HTTPS 地址和一次性配对码。"
            : "新 Host 配对成功后，旧仓库的快照、聊天和待提交草稿会被清除，避免内容串到新仓库。"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Section("配对信息") {
        TextField("Mac Host HTTPS 地址", text: $endpoint)
          .focused($focusedField, equals: .endpoint)
          #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .submitLabel(.next)
          #endif
          .autocorrectionDisabled()
          .onSubmit { focusedField = .code }
        TextField("一次性配对码", text: $pairingCode)
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
          .focused($focusedField, equals: .deviceName)
          #if os(iOS)
            .submitLabel(.done)
          #endif
          .onSubmit { focusedField = nil }
      }
      Section {
        MobilePrimaryButton(title: "配对并连接", symbol: "link.badge.plus") {
          requestPairing()
        }
        if let pairingMessage {
          Text(pairingMessage)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .navigationTitle(session.savedEndpoint == nil ? "连接 Mac Host" : "更换 Mac Host")
    .confirmationDialog(
      "更换 Mac Host？", isPresented: $showDraftsConfirmation, titleVisibility: .visible
    ) {
      Button("继续更换", role: .destructive) { pair() }
      Button("取消", role: .cancel) {}
    } message: {
      Text("本机待提交草稿属于当前仓库。新 Host 配对成功后将清除这些草稿，避免写入错误仓库。")
    }
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      .scrollDismissesKeyboard(.interactively)
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("完成") { focusedField = nil }
        }
      }
    #endif
  }

  private func requestPairing() {
    focusedField = nil
    guard URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else {
      pairingMessage = "地址格式不正确。"
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
    Task {
      do {
        try await session.pair(endpoint: url, code: pairingCode, deviceName: deviceName)
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

extension Array {
  fileprivate subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

import Foundation
import StudyRocketShared
import SwiftUI

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

enum MobileTheme {
  static let brand = Color(red: 0.03, green: 0.42, blue: 0.86)
  static let rail = Color.teal
  static let completion = Color.teal
  #if os(iOS)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
  #else
    static let groupedBackground = Color(nsColor: .windowBackgroundColor)
  #endif
  static let pageInset: CGFloat = 20
  static let cardRadius: CGFloat = 16

  static func statusColor(_ state: MobileConnectionState) -> Color {
    switch state {
    case .online: completion
    case .connecting: .orange
    case .unconfigured, .offline: .secondary
    case .failed: .red
    }
  }
}

enum MobileTodayFocus: Equatable {
  case task(String, completed: Int, total: Int)
  case completed(total: Int)
  case unplanned

  static func resolve(
    periods: [PeriodSnapshot],
    timetable: TimetableSnapshot? = nil,
    now: Date = .now,
    completion: (PeriodSnapshot, PeriodTaskSnapshot) -> Bool
  ) -> MobileTodayFocus {
    let assigned = periods.flatMap { period in
      period.tasks.map { (period, $0) }
    }
    let completed = assigned.filter { completion($0.0, $0.1) }.count
    if let next = orderedTasks(
      periods: periods, timetable: timetable, now: now, completion: completion
    ).first {
      return .task(next, completed: completed, total: assigned.count)
    }
    return assigned.isEmpty ? .unplanned : .completed(total: assigned.count)
  }

  static func resolve(
    periods: [PeriodSnapshot],
    timetable: TimetableSnapshot? = nil,
    now: Date = .now,
    completion: (PeriodSnapshot) -> Bool
  ) -> MobileTodayFocus {
    resolve(periods: periods, timetable: timetable, now: now) { period, _ in completion(period) }
  }

  var progressLabel: String {
    switch self {
    case .task(_, let completed, let total) where total == 0 || completed == total:
      return "今日课表"
    case .task(_, let completed, let total): return "今日 \(completed)/\(total)"
    case .completed(let total): return "今日 \(total)/\(total)"
    case .unplanned: return "今日未安排"
    }
  }

  static func orderedTasks(
    periods: [PeriodSnapshot],
    timetable: TimetableSnapshot?,
    now: Date = .now,
    completion: (PeriodSnapshot, PeriodTaskSnapshot) -> Bool
  ) -> [String] {
    let nowMinutes = currentMinutes(now)
    let periodCandidates = periods.enumerated().flatMap { periodOffset, period in
      period.tasks.enumerated().compactMap { taskOffset, task -> Candidate? in
        let text = task.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !completion(period, task) else { return nil }
        return Candidate(
          minutes: firstClockMinutes(in: text) ?? periodAnchor(for: period),
          sourceRank: 1,
          stableID: "period:\(period.id):\(periodOffset):\(task.id):\(taskOffset)",
          text: text
        )
      }
    }
    let timetableCandidates = todayTimetableCandidates(timetable, now: now, nowMinutes: nowMinutes)
    return (periodCandidates + timetableCandidates)
      .sorted(by: Candidate.isOrdered)
      .map(\.text)
  }

  static func orderedTasks(
    periods: [PeriodSnapshot],
    timetable: TimetableSnapshot?,
    now: Date = .now,
    completion: (PeriodSnapshot) -> Bool
  ) -> [String] {
    orderedTasks(periods: periods, timetable: timetable, now: now) { period, _ in completion(period) }
  }

  private struct Candidate {
    let minutes: Int
    let sourceRank: Int
    let stableID: String
    let text: String

    static func isOrdered(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
      if lhs.minutes != rhs.minutes { return lhs.minutes < rhs.minutes }
      if lhs.sourceRank != rhs.sourceRank { return lhs.sourceRank < rhs.sourceRank }
      return lhs.stableID < rhs.stableID
    }
  }

  private static func todayTimetableCandidates(
    _ timetable: TimetableSnapshot?, now: Date, nowMinutes: Int
  ) -> [Candidate] {
    guard let timetable,
      timetable.status == .available,
      timetable.referenceDate == shanghaiDateID(now),
      let today = timetable.days.first(where: { $0.id == timetable.referenceDate })
    else {
      return []
    }

    return today.entries.enumerated().compactMap { offset, entry -> Candidate? in
      guard entry.kind != .holiday else { return nil }
      let start = firstClockMinutes(in: entry.startTime)
      let note = firstClockMinutes(in: entry.note)
      guard let actionMinutes = [start, note].compactMap({ $0 }).min() else { return nil }

      if let end = firstClockMinutes(in: entry.endTime) {
        guard end > nowMinutes else { return nil }
      } else {
        guard actionMinutes >= nowMinutes else { return nil }
      }

      return Candidate(
        minutes: actionMinutes,
        sourceRank: 0,
        stableID: "timetable:\(entry.id):\(offset)",
        text: "\(clockText(actionMinutes)) · \(entry.title)"
      )
    }
  }

  private static func periodAnchor(for period: PeriodSnapshot) -> Int {
    switch period.id {
    case "morning": return 8 * 60
    case "noon": return 12 * 60
    case "evening": return 18 * 60
    default: return Int.max
    }
  }

  private static func currentMinutes(_ date: Date) -> Int {
    let values = shanghaiCalendar.dateComponents([.hour, .minute], from: date)
    return (values.hour ?? 0) * 60 + (values.minute ?? 0)
  }

  private static func shanghaiDateID(_ date: Date) -> String {
    let values = shanghaiCalendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", values.year ?? 0, values.month ?? 0, values.day ?? 0)
  }

  private static func firstClockMinutes(in value: String?) -> Int? {
    guard let value,
      let range = value.range(
        of: #"(?:^|[^0-9])([0-2]?[0-9])\s*[:：]\s*([0-5][0-9])(?:$|[^0-9])"#,
        options: .regularExpression)
    else {
      return nil
    }
    let values = String(value[range]).split { !$0.isNumber }.compactMap { Int($0) }
    guard values.count >= 2, values[0] < 24 else { return nil }
    return values[0] * 60 + values[1]
  }

  private static func clockText(_ minutes: Int) -> String {
    String(format: "%02d:%02d", minutes / 60, minutes % 60)
  }

  private static let shanghaiCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    return calendar
  }()
}

enum MobileDeliveryChapterPhase: Equatable, Sendable {
  case list
  case striking(MobileDeliveryMutation)
  case awaitingConfirmation(MobileDeliveryMutation)
  case sealing(MobileDeliveryMutation)
  case completed

  var mutation: MobileDeliveryMutation? {
    switch self {
    case .striking(let mutation), .awaitingConfirmation(let mutation), .sealing(let mutation):
      return mutation
    case .list, .completed:
      return nil
    }
  }
}

enum MobileDeliveryChapterEffect: Equatable, Sendable {
  case none
  case submit(MobileDeliveryMutation)
  case announceCompletion
}

struct MobileDeliveryChapterState: Equatable, Sendable {
  private(set) var phase: MobileDeliveryChapterPhase
  private(set) var repositoryGeneration: UInt64
  private(set) var queuedFinalMutation: MobileDeliveryMutation?

  init(allAuthoritativelyCompleted: Bool = false, repositoryGeneration: UInt64 = 0) {
    phase = allAuthoritativelyCompleted ? .completed : .list
    self.repositoryGeneration = repositoryGeneration
    queuedFinalMutation = nil
  }

  mutating func synchronize(
    allAuthoritativelyCompleted: Bool,
    repositoryGeneration: UInt64,
    hasPendingDelivery: Bool = false
  ) {
    if self.repositoryGeneration != repositoryGeneration {
      self.repositoryGeneration = repositoryGeneration
      queuedFinalMutation = nil
      phase = allAuthoritativelyCompleted ? .completed : .list
      return
    }
    switch phase {
    case .list, .completed:
      if allAuthoritativelyCompleted, let mutation = queuedFinalMutation {
        if hasPendingDelivery {
          phase = .list
        } else {
          queuedFinalMutation = nil
          phase = .sealing(mutation)
        }
      } else {
        if !hasPendingDelivery { queuedFinalMutation = nil }
        phase = allAuthoritativelyCompleted ? .completed : .list
      }
    case .striking, .awaitingConfirmation, .sealing:
      break
    }
  }

  mutating func begin(deliveryID: String, token: UUID = UUID()) -> MobileDeliveryMutation? {
    guard phase == .list else { return nil }
    let mutation = MobileDeliveryMutation(
      deliveryID: deliveryID,
      token: token,
      repositoryGeneration: repositoryGeneration
    )
    phase = .striking(mutation)
    return mutation
  }

  mutating func undo(_ mutation: MobileDeliveryMutation) -> Bool {
    guard phase == .striking(mutation) else { return false }
    phase = .list
    return true
  }

  mutating func finishStrike(_ mutation: MobileDeliveryMutation) -> MobileDeliveryChapterEffect {
    guard phase == .striking(mutation),
      mutation.repositoryGeneration == repositoryGeneration
    else { return .none }
    phase = .awaitingConfirmation(mutation)
    return .submit(mutation)
  }

  mutating func resolve(
    _ result: MobileDeliveryToggleResult,
    for mutation: MobileDeliveryMutation,
    queuedOfflineCompletesAll: Bool = false
  ) {
    guard phase == .awaitingConfirmation(mutation),
      mutation.repositoryGeneration == repositoryGeneration
    else { return }
    switch result {
    case .confirmed(let snapshot):
      queuedFinalMutation = nil
      let deliveries = snapshot.week.deliveries
      let targetConfirmed =
        deliveries.first(where: { $0.id == mutation.deliveryID })?.isCompleted == true
      phase =
        targetConfirmed && !deliveries.isEmpty && deliveries.allSatisfy(\.isCompleted)
        ? .sealing(mutation)
        : .list
    case .queuedOffline:
      queuedFinalMutation = queuedOfflineCompletesAll ? mutation : nil
      phase = .list
    case .failed, .staleGeneration:
      if queuedFinalMutation == mutation { queuedFinalMutation = nil }
      phase = .list
    }
  }

  mutating func finishSeal(_ mutation: MobileDeliveryMutation) -> MobileDeliveryChapterEffect {
    guard phase == .sealing(mutation),
      mutation.repositoryGeneration == repositoryGeneration
    else { return .none }
    queuedFinalMutation = nil
    phase = .completed
    return .announceCompletion
  }
}

enum MobileDeliveryChapterBody: Equatable, Sendable {
  case empty
  case list
  case awaitingFinalConfirmation
  case waitingForOfflineSync
  case sealing
  case completed
}

enum MobilePendingTogglePresentation: Equatable, Sendable {
  case none
  case replaying
  case offline
  case legacyReview
  case blocked
  case waiting
}

enum MobileDeliveryChapterPresentation {
  static let completionTitle = "本周交付物已完成"

  static func body(
    phase: MobileDeliveryChapterPhase,
    total: Int,
    completed: Int,
    allAuthoritativelyCompleted: Bool,
    hasPending: Bool
  ) -> MobileDeliveryChapterBody {
    guard total > 0 else { return .empty }
    if case .sealing = phase { return .sealing }
    if phase == .completed { return .completed }
    if phase == .list, allAuthoritativelyCompleted {
      return hasPending ? .waitingForOfflineSync : .completed
    }
    if case .awaitingConfirmation = phase,
      completed == total,
      !allAuthoritativelyCompleted
    {
      return .awaitingFinalConfirmation
    }
    if completed == total, !allAuthoritativelyCompleted, hasPending {
      return .waitingForOfflineSync
    }
    return .list
  }
}

struct MobileBrandMark: View {
  var size: CGFloat = 38

  var body: some View {
    Image("NCUStudyRocketMark")
      .resizable()
      .scaledToFill()
      .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

struct MobileSurface<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        .background, in: RoundedRectangle(cornerRadius: MobileTheme.cardRadius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: MobileTheme.cardRadius, style: .continuous)
          .stroke(.primary.opacity(0.08), lineWidth: 1)
      }
  }
}

struct MobileSectionHeading: View {
  let title: String
  var detail: String? = nil
  var icon: String? = nil

  var body: some View {
    if let detail {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          headingLabel
            .fixedSize(horizontal: true, vertical: false)
          Spacer(minLength: 8)
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
        }
        VStack(alignment: .leading, spacing: 4) {
          headingLabel
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } else {
      headingLabel
    }
  }

  private var headingLabel: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if let icon {
        Image(systemName: icon)
          .foregroundStyle(MobileTheme.rail)
          .accessibilityHidden(true)
      }
      Text(title)
        .font(.system(.headline, design: .rounded, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct MobileConnectionPill: View {
  let state: MobileConnectionState

  var body: some View {
    Label(state.title, systemImage: state == .online ? "checkmark.circle.fill" : "circle.dotted")
      .font(.caption.weight(.medium))
      .foregroundStyle(MobileTheme.statusColor(state))
      .padding(.horizontal, 9)
      .padding(.vertical, 6)
      .background(MobileTheme.statusColor(state).opacity(0.10), in: Capsule(style: .continuous))
      .accessibilityLabel(state.title)
  }
}

/// A full-width primary action whose label is measured inside the hit target.
/// Keeping the centering container inside the Button avoids intrinsic-width
/// surprises in List rows and remains readable with larger Dynamic Type sizes.
struct MobilePrimaryButton: View {
  let title: String
  var symbol: String? = nil
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if let symbol {
          Image(systemName: symbol)
            .accessibilityHidden(true)
        }
        Text(title)
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
      .contentShape(Rectangle())
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.regular)
    .frame(maxWidth: .infinity)
    .accessibilityLabel(title)
  }
}

struct MobileTodayChecklist: View {
  let periods: [PeriodSnapshot]
  var canToggle = true
  var completion: (PeriodSnapshot, PeriodTaskSnapshot) -> Bool = { _, task in task.isCompleted }
  var isPending: (PeriodSnapshot, PeriodTaskSnapshot) -> Bool = { _, _ in false }
  var canCancelPending: (PeriodSnapshot, PeriodTaskSnapshot) -> Bool = { _, _ in false }
  var pendingLabel: (PeriodSnapshot, PeriodTaskSnapshot) -> String? = { _, _ in "待同步" }
  var hasLegacyPending: (PeriodSnapshot) -> Bool = { _ in false }
  let onToggle: (PeriodSnapshot, PeriodTaskSnapshot) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 8) {
      ForEach(periods) { period in
        VStack(alignment: .leading, spacing: 4) {
          Label(period.title, systemImage: periodSymbol(period.id))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minHeight: 28, alignment: .leading)
          if period.tasks.isEmpty {
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: "circle")
                .foregroundStyle(Color.secondary)
                .font(.body)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
              Text("未安排")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minHeight: 44, alignment: .leading)
              Spacer(minLength: 0)
            }
            .padding(.leading, 20)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(period.title)，未安排")
          } else {
            ForEach(Array(period.tasks.enumerated()), id: \.element.id) { index, task in
              let isCompleted = completion(period, task)
              let pending = isPending(period, task)
              let canCancel = canCancelPending(period, task)
              Button {
                onToggle(period, task)
              } label: {
                HStack(alignment: .top, spacing: 10) {
                  Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isCompleted ? MobileTheme.completion : MobileTheme.rail)
                    .font(.body)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                  VStack(alignment: .leading, spacing: 3) {
                    MobileInterruptibleStrikeText(
                      text: task.text,
                      isStruck: isCompleted,
                      font: .subheadline
                    )
                    if pending, let label = pendingLabel(period, task) {
                      Text(label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(label == "正在同步" ? MobileTheme.rail : Color.orange)
                    }
                  }
                  Spacer(minLength: 0)
                }
                .padding(.leading, 20)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .disabled(!canToggle || (pending && !canCancel))
              .accessibilityLabel("\(period.title)，\(task.text)")
              .accessibilityValue(
                "\(isCompleted ? "已完成" : "未完成")\(pending ? (canCancel ? "，可撤销" : "，正在保存") : "")"
              )
              .accessibilityHint(
                pending && canCancel
                  ? "轻点处理待同步修改"
                  : canToggle && !pending ? (isCompleted ? "轻点标记为未完成" : "轻点标记为已完成") : ""
              )
              .accessibilityAddTraits(isCompleted ? .isSelected : [])
              .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isCompleted)
              if index < period.tasks.count - 1 { Divider().padding(.leading, 32) }
            }
          }
          if hasLegacyPending(period) {
            Label("此时段有旧版待确认操作", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.orange)
              .padding(.leading, 20)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if period.id != (periods.last?.id ?? "") {
          Divider()
            .padding(.vertical, 4)
        }
      }
    }
  }

  private func periodSymbol(_ id: String) -> String {
    switch id {
    case "morning": "sun.max"
    case "noon": "sun.and.horizon"
    default: "moon.stars"
    }
  }
}

struct MobileDeliveryOverview: View {
  let deliveries: [DeliverySnapshot]
  let phase: MobileDeliveryChapterPhase
  var completion: (DeliverySnapshot) -> Bool = { $0.isCompleted }
  var isPending: (DeliverySnapshot) -> Bool = { _ in false }
  var canCancelPending: (DeliverySnapshot) -> Bool = { _ in false }
  var pendingLabel: (DeliverySnapshot) -> String = { _ in "待同步" }
  var pendingSyncState: MobilePendingTogglePresentation = .none
  var onPendingAction: (() -> Void)? = nil
  let onToggle: (DeliverySnapshot) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AccessibilityFocusState private var completedSealFocused: Bool

  private var orderedDeliveries: [DeliverySnapshot] {
    deliveries.enumerated().sorted { lhs, rhs in
      let leftDate = Self.deliveryDate(lhs.element.dateLabel)
      let rightDate = Self.deliveryDate(rhs.element.dateLabel)
      let leftRank = Self.deliveryRank(lhs.element, date: leftDate)
      let rightRank = Self.deliveryRank(rhs.element, date: rightDate)
      if leftRank != rightRank { return leftRank < rightRank }
      if leftDate != rightDate {
        if let leftDate, let rightDate { return leftDate < rightDate }
        return leftDate != nil
      }
      return lhs.offset < rhs.offset
    }.map(\.element)
  }

  private var visibleDeliveries: [DeliverySnapshot] {
    orderedDeliveries.filter {
      !$0.isCompleted || isPending($0) || phase.mutation?.deliveryID == $0.id
    }
  }
  private var completed: Int { deliveries.filter(completion).count }
  private var authoritativeCompleted: Int { deliveries.filter(\.isCompleted).count }
  private var total: Int { deliveries.count }
  private var hasPending: Bool { deliveries.contains(where: isPending) }
  private var displayedCompleted: Int { hasPending ? authoritativeCompleted : completed }
  private var allAuthoritativelyCompleted: Bool {
    !deliveries.isEmpty && deliveries.allSatisfy(\.isCompleted)
  }
  private var chapterBody: MobileDeliveryChapterBody {
    MobileDeliveryChapterPresentation.body(
      phase: phase,
      total: total,
      completed: completed,
      allAuthoritativelyCompleted: allAuthoritativelyCompleted,
      hasPending: hasPending
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Text(
          total == 0
            ? "暂无交付物"
            : hasPending
              ? "Mac 已完成 \(authoritativeCompleted) / \(total) 项"
              : "已完成 \(completed) / \(total) 项"
        )
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(total == 0 ? .secondary : .primary)
        Spacer(minLength: 8)
        if total > 0 {
          MobileProgressSegmentedRing(total: total, completed: displayedCompleted)
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
        }
      }
      switch chapterBody {
      case .empty:
        Text("本周暂无交付物")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
          .frame(minHeight: 44, alignment: .leading)
          .transition(.opacity)
      case .sealing:
        MobileDeliveryChapterSeal(total: total, animated: true)
          .transition(.opacity)
      case .completed:
        MobileDeliveryChapterSeal(total: total, animated: false)
          .accessibilityFocused($completedSealFocused)
          .transition(.opacity)
      case .awaitingFinalConfirmation:
        MobileDeliverySyncPlaceholder(
          total: total,
          text: "等待 Mac 确认",
          tint: MobileTheme.rail
        )
        .transition(.opacity)
      case .waitingForOfflineSync:
        VStack(spacing: 10) {
          MobileDeliverySyncPlaceholder(
            total: total,
            text: pendingStatus.text,
            tint: pendingStatus.tint
          )
          if let actionTitle = pendingStatus.actionTitle, let onPendingAction {
            Button(actionTitle, action: onPendingAction)
              .buttonStyle(.bordered)
              .controlSize(.regular)
          }
        }
        .transition(.opacity)
      case .list:
        VStack(spacing: 0) {
          ForEach(Array(visibleDeliveries.enumerated()), id: \.element.id) { index, delivery in
            let isCompleted = completion(delivery)
            let overdue = !isCompleted && Self.isOverdue(delivery)
            let pending = isPending(delivery)
            let queueLabel = pendingLabel(delivery)
            let nodeState = nodeState(
              for: delivery, completed: isCompleted, pending: pending, overdue: overdue)
            let canUndo = isStriking(delivery)
            let canCancel = pending && canCancelPending(delivery)
            let canStart = phase == .list && !pending && !isCompleted
            Button {
              onToggle(delivery)
            } label: {
              HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 4) {
                  MobileDeliveryRailNode(state: nodeState)
                    .frame(width: 20, height: 22)
                    .accessibilityHidden(true)
                  if index < visibleDeliveries.count - 1 {
                    Capsule(style: .continuous)
                      .fill(MobileTheme.rail.opacity(0.34))
                      .frame(width: 2)
                      .frame(maxHeight: .infinity)
                  }
                }
                .frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                  HStack(spacing: 6) {
                    if let dateLabel = delivery.dateLabel {
                      Text(dateLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(overdue ? Color.orange : Color.secondary)
                    }
                    if overdue {
                      Text("已逾期")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                    }
                  }
                  MobileInterruptibleStrikeText(
                    text: Self.presentationText(for: delivery),
                    isStruck: isCompleted,
                    font: .subheadline
                  )
                  if nodeState == .awaitingConfirmation {
                    Text("等待 Mac 确认")
                      .font(.caption2.weight(.semibold))
                      .foregroundStyle(MobileTheme.rail)
                  } else if nodeState == .queuedOffline {
                    Text(queueLabel)
                      .font(.caption2.weight(.semibold))
                      .foregroundStyle(queueLabel == "正在同步" ? MobileTheme.rail : Color.orange)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, index == visibleDeliveries.count - 1 ? 0 : 14)
              }
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!(canStart || canUndo || canCancel))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
              Self.accessibilityLabel(for: delivery, overdue: overdue, completed: isCompleted)
            )
            .accessibilityValue(accessibilityValue(for: nodeState))
            .accessibilityHint(
              canUndo
                ? "轻点撤销"
                : canCancel
                  ? "轻点处理待同步修改" : nodeState == .open || nodeState == .overdue ? "轻点标记为完成" : "")
          }
        }
        .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: reduceMotion ? 0.2 : 0.24), value: phase)
    .onChange(of: phase) { _, value in
      if case .completed = value {
        completedSealFocused = true
      } else {
        completedSealFocused = false
      }
    }
  }

  private var pendingStatus: (text: String, tint: Color, actionTitle: String?) {
    switch pendingSyncState {
    case .replaying:
      return ("正在同步完成状态", MobileTheme.rail, nil)
    case .offline:
      return ("等待连接后同步", .orange, nil)
    case .legacyReview:
      return ("有待确认的旧版操作", .orange, "审核待同步操作")
    case .blocked:
      return ("同步未完成", .orange, "重新加载并重试")
    case .waiting:
      return ("等待同步", .orange, "重新加载并重试")
    case .none:
      return ("等待同步", .secondary, nil)
    }
  }

  private func nodeState(
    for delivery: DeliverySnapshot,
    completed: Bool,
    pending: Bool,
    overdue: Bool
  ) -> MobileDeliveryRailNode.State {
    if phase.mutation?.deliveryID == delivery.id {
      if case .awaitingConfirmation = phase { return .awaitingConfirmation }
      if case .striking = phase { return .striking }
    }
    if pending { return .queuedOffline }
    if completed { return .striking }
    return overdue ? .overdue : .open
  }

  private func isStriking(_ delivery: DeliverySnapshot) -> Bool {
    guard case .striking(let mutation) = phase else { return false }
    return mutation.deliveryID == delivery.id
  }

  private func accessibilityValue(for state: MobileDeliveryRailNode.State) -> String {
    switch state {
    case .open, .overdue: return "未完成"
    case .striking: return "已标记完成，可撤销"
    case .awaitingConfirmation: return "正在等待 Mac 确认"
    case .queuedOffline: return "已完成，待同步"
    }
  }

  private static func deliveryRank(_ delivery: DeliverySnapshot, date: Date?) -> Int {
    if !delivery.isCompleted, let date, date < calendar.startOfDay(for: .now) { return 0 }
    return date == nil ? 2 : 1
  }

  private static func isOverdue(_ delivery: DeliverySnapshot) -> Bool {
    guard !delivery.isCompleted, let date = deliveryDate(delivery.dateLabel) else { return false }
    return date < calendar.startOfDay(for: .now)
  }

  private static func deliveryDate(_ label: String?) -> Date? {
    guard let label,
      let range = label.range(
        of: #"(?:(\d{4})\s*[-年]\s*)?(\d{1,2})\s*月\s*(\d{1,2})\s*日?"#, options: .regularExpression)
    else { return nil }
    let numbers = label[range].split { !$0.isNumber }.compactMap { Int($0) }
    guard numbers.count >= 2 else { return nil }
    let now = Date.now
    var components = calendar.dateComponents([.year, .month, .day], from: now)
    if numbers.count == 3 {
      components.year = numbers[0]
      components.month = numbers[1]
      components.day = numbers[2]
    } else {
      components.month = numbers[0]
      components.day = numbers[1]
    }
    guard let date = calendar.date(from: components) else { return nil }
    if numbers.count == 2,
      let sixMonthsAgo = calendar.date(byAdding: .month, value: -6, to: now),
      date < sixMonthsAgo
    {
      return calendar.date(byAdding: .year, value: 1, to: date)
    }
    return calendar.startOfDay(for: date)
  }

  private static func presentationText(for delivery: DeliverySnapshot) -> String {
    guard let label = delivery.dateLabel,
      let prefix = delivery.text.range(
        of: #"^\s*(?:(?:\d{4})\s*[-年]\s*)?\d{1,2}\s*月\s*\d{1,2}\s*日(?:\s*[·•]\s*周[一二三四五六日天])?"#,
        options: .regularExpression),
      dateNumbers(in: String(delivery.text[prefix])) == dateNumbers(in: label)
    else { return delivery.text }
    let remainder = String(delivery.text[prefix.upperBound...])
      .replacingOccurrences(of: #"^\s*[：:·•\-—]?\s*"#, with: "", options: .regularExpression)
    return remainder.isEmpty ? delivery.text : remainder
  }

  private static func accessibilityLabel(
    for delivery: DeliverySnapshot, overdue: Bool, completed: Bool
  ) -> String {
    [
      delivery.dateLabel, presentationText(for: delivery), overdue ? "已逾期" : nil,
      completed ? "已完成" : "未完成",
    ]
    .compactMap { $0 }
    .joined(separator: "，")
  }

  private static func dateNumbers(in value: String) -> [Int] {
    let values = value.split { !$0.isNumber }.compactMap { Int($0) }
    return Array(values.suffix(2))
  }

  private static var calendar: Calendar = {
    var value = Calendar(identifier: .gregorian)
    value.locale = Locale(identifier: "zh_CN")
    value.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    return value
  }()
}

private struct MobileProgressSegmentedRing: View {
  let total: Int
  let completed: Int
  var tint: Color = MobileTheme.completion

  var body: some View {
    Canvas { context, size in
      guard total > 0 else { return }
      let center = CGPoint(x: size.width / 2, y: size.height / 2)
      let radius = max(0, min(size.width, size.height) / 2 - 1.5)
      let step = Double.pi * 2 / Double(total)
      let gap = min(0.18, step * 0.28)
      for index in 0..<total {
        let start = -Double.pi / 2 + Double(index) * step + gap / 2
        let end = -Double.pi / 2 + Double(index + 1) * step - gap / 2
        var segment = Path()
        segment.addArc(
          center: center,
          radius: radius,
          startAngle: .radians(start),
          endAngle: .radians(end),
          clockwise: false
        )
        context.stroke(
          segment,
          with: .color(index < completed ? tint : Color.secondary.opacity(0.22)),
          style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
        )
      }
    }
  }
}

private struct MobileDeliverySyncPlaceholder: View {
  let total: Int
  let text: String
  let tint: Color

  var body: some View {
    VStack(spacing: 10) {
      MobileProgressSegmentedRing(total: total, completed: total, tint: tint)
        .frame(width: 58, height: 58)
        .accessibilityHidden(true)
      Text(text)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(tint)
    }
    .frame(maxWidth: .infinity, minHeight: 112, alignment: .center)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
  }
}

private struct MobileDeliveryRailNode: View {
  enum State: Equatable {
    case open
    case overdue
    case striking
    case awaitingConfirmation
    case queuedOffline
  }

  let state: State

  private var tint: Color {
    switch state {
    case .overdue, .queuedOffline: return .orange
    case .open, .striking, .awaitingConfirmation: return MobileTheme.rail
    }
  }

  var body: some View {
    ZStack {
      switch state {
      case .awaitingConfirmation, .queuedOffline:
        MobileSegmentedRing()
          .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
      case .striking:
        Circle().fill(tint)
      case .open, .overdue:
        Circle().stroke(tint, lineWidth: 2)
      }
      if state == .striking || state == .awaitingConfirmation || state == .queuedOffline {
        MobileCheckmarkShape()
          .trim(from: 0, to: 1)
          .stroke(
            state == .striking ? Color.white : tint,
            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
          )
          .padding(5)
      }
    }
    .padding(1)
  }
}

private struct MobileSegmentedRing: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let radius = min(rect.width, rect.height) / 2
    for index in 0..<8 {
      let start = Angle.degrees(Double(index) * 45 - 86)
      let end = Angle.degrees(Double(index) * 45 - 64)
      path.addArc(
        center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
    }
    return path
  }
}

private struct MobileCheckmarkShape: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    return path
  }
}

private struct MobileSealOrbitShape: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let sealRadius = min(rect.height * 0.34, rect.width * 0.2)
    let center = CGPoint(x: rect.maxX - sealRadius - 4, y: rect.midY)
    path.move(to: CGPoint(x: rect.minX + 4, y: rect.minY + 4))
    path.addLine(to: CGPoint(x: rect.minX + 4, y: rect.midY))
    path.addCurve(
      to: CGPoint(x: center.x, y: center.y - sealRadius),
      control1: CGPoint(x: rect.width * 0.28, y: rect.maxY - 2),
      control2: CGPoint(x: rect.width * 0.58, y: rect.minY + 2)
    )
    path.addArc(
      center: center,
      radius: sealRadius,
      startAngle: .degrees(-90),
      endAngle: .degrees(270),
      clockwise: false
    )
    return path
  }
}

private struct MobileDeliveryChapterSeal: View {
  let total: Int
  let animated: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var progress: CGFloat = 0
  @State private var handoff: CGFloat = 0

  var body: some View {
    HStack(spacing: 14) {
      ZStack {
        Group {
          MobileSealOrbitShape()
            .trim(from: 0, to: progress)
            .stroke(
              MobileTheme.rail.opacity(0.72),
              style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
            )
          Circle()
            .trim(from: 0, to: progress)
            .stroke(MobileTheme.completion, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: 54, height: 54)
            .offset(x: 32)
          MobileCheckmarkShape()
            .trim(from: 0, to: progress)
            .stroke(
              MobileTheme.completion,
              style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round)
            )
            .frame(width: 24, height: 18)
            .offset(x: 32)
        }
        .opacity(animated ? 1 - handoff : 0)

        Image(systemName: "checkmark.seal.fill")
          .font(.system(size: 54, weight: .semibold))
          .foregroundStyle(MobileTheme.completion)
          .offset(x: 32)
          .opacity(animated ? handoff : 1)
      }
      .frame(width: 124, height: 76)
      .accessibilityHidden(true)

      Text(MobileDeliveryChapterPresentation.completionTitle)
        .font(.system(.headline, design: .rounded, weight: .bold))
        .foregroundStyle(MobileTheme.completion)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("本周交付物已完成，共 \(total) 项")
    .task {
      progress = animated && !reduceMotion ? 0 : 1
      handoff = animated && !reduceMotion ? 0 : 1
      guard animated, !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 0.8)) { progress = 1 }
      try? await Task.sleep(for: .milliseconds(620))
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 0.18)) { handoff = 1 }
    }
  }
}

@MainActor
enum MobileAccessibility {
  static func notifyWeeklyDeliveriesCompleted() {
    #if os(iOS)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    #endif
  }
}

private struct MobileInterruptibleStrikeText: View {
  let text: String
  let isStruck: Bool
  var font: Font = .body
  var inactiveColor: Color = .primary
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var progress: CGFloat = 0

  var body: some View {
    Group {
      if reduceMotion {
        ZStack(alignment: .leading) {
          Text(text)
            .font(font)
            .foregroundStyle(inactiveColor)
            .opacity(isStruck ? 0 : 1)
          Text(text)
            .font(font)
            .foregroundStyle(.secondary)
            .strikethrough(true, color: .secondary)
            .opacity(isStruck ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.2), value: isStruck)
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
    .fixedSize(horizontal: false, vertical: true)
  }
}

struct MobileInlineNotice: View {
  let text: String
  let symbol: String
  var tint: Color = .secondary

  var body: some View {
    Label(text, systemImage: symbol)
      .font(.footnote)
      .foregroundStyle(tint)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

enum MobileDailyField: Hashable {
  case deliverables
  case studyTime
  case sleep
  case exercise
  case firstTask
}

struct MobileFactField: View {
  let title: String
  let symbol: String
  let placeholder: String
  @Binding var text: String
  let field: MobileDailyField
  let focus: FocusState<MobileDailyField?>.Binding
  var multiline: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      HStack(alignment: .top, spacing: 9) {
        Image(systemName: symbol)
          .font(.body.weight(.medium))
          .foregroundStyle(MobileTheme.rail)
          .frame(width: 22)
          .padding(.top, 3)
          .accessibilityHidden(true)
        TextField(placeholder, text: $text, axis: multiline ? .vertical : .horizontal)
          .font(.body)
          .lineLimit(multiline ? 4 : 1)
          .focused(focus, equals: field)
          #if os(iOS)
            .textInputAutocapitalization(.sentences)
          #endif
          .padding(.vertical, 1)
      }
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.primary.opacity(0.11)))
  }
}

struct MobileEmptyState: View {
  let title: String
  let message: String
  let symbol: String
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    VStack(spacing: 12) {
      VStack(spacing: 12) {
        Image(systemName: symbol)
          .font(.system(size: 42, weight: .medium))
          .foregroundStyle(MobileTheme.rail)
          .symbolRenderingMode(.hierarchical)
          .accessibilityHidden(true)
        Text(title)
          .font(.title3.weight(.semibold))
          .multilineTextAlignment(.center)
        Text(message)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
      if let actionTitle, let action {
        MobilePrimaryButton(title: actionTitle, action: action)
          .padding(.top, 4)
      }
    }
    .frame(maxWidth: 320)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .padding(.horizontal, MobileTheme.pageInset)
    .padding(.vertical, 48)
    .accessibilityElement(children: .contain)
  }
}

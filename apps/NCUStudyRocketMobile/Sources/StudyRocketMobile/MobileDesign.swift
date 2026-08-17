import Foundation
import SwiftUI
import StudyRocketShared
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
            .background(.background, in: RoundedRectangle(cornerRadius: MobileTheme.cardRadius, style: .continuous))
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

struct MobileDayRail: View {
    let periods: [PeriodSnapshot]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(periods.enumerated()), id: \.element.id) { index, period in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(period.text.isEmpty ? Color.secondary.opacity(0.3) : MobileTheme.rail)
                            .frame(width: 10, height: 10)
                            .padding(.top, 5)
                        if index < periods.count - 1 {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.18))
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(period.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(period.text.isEmpty ? "未安排" : period.text)
                            .font(.subheadline)
                            .foregroundStyle(period.text.isEmpty ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, index == periods.count - 1 ? 0 : 16)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct MobileTodayChecklist: View {
    let periods: [PeriodSnapshot]
    var canToggle = true
    var completion: (PeriodSnapshot) -> Bool = { $0.isCompleted }
    var isPending: (PeriodSnapshot) -> Bool = { _ in false }
    let onToggle: (PeriodSnapshot) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(periods.enumerated()), id: \.element.id) { index, period in
                let hasText = !period.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let isCompleted = completion(period)
                let pending = isPending(period)
                Button {
                    onToggle(period)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: pending ? "clock" : isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isCompleted ? MobileTheme.completion : hasText ? MobileTheme.rail : Color.secondary)
                            .font(.body)
                            .frame(width: 22, height: 22)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(period.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(hasText ? period.text : "未安排")
                                .font(.subheadline)
                                .foregroundStyle(isCompleted || !hasText ? .secondary : .primary)
                                .strikethrough(isCompleted, color: .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasText || !canToggle || pending)
                .accessibilityLabel("\(period.title)，\(hasText ? period.text : "未安排")")
                .accessibilityValue(pending ? "正在同步" : isCompleted ? "已完成" : "未完成")
                .accessibilityHint(hasText && canToggle ? (isCompleted ? "轻点标记为未完成" : "轻点标记为已完成") : "")
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isCompleted)
                if index < periods.count - 1 { Divider().padding(.leading, 32) }
            }
        }
    }
}

struct MobileDeliveryOverview: View {
    let deliveries: [DeliverySnapshot]
    let completed: Int
    let total: Int

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
        Array(orderedDeliveries.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(total == 0 ? "暂无其他交付物" : "已完成 \(completed) / \(total) 项")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(total == 0 ? .secondary : .primary)
            if deliveries.isEmpty {
                Text("除今日安排外，本周暂无其他交付物")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleDeliveries.enumerated()), id: \.element.id) { index, delivery in
                        let overdue = Self.isOverdue(delivery)
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 0) {
                                Image(systemName: delivery.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(delivery.isCompleted ? MobileTheme.completion : overdue ? Color.orange : MobileTheme.rail)
                                    .frame(width: 20, height: 22)
                                if index < visibleDeliveries.count - 1 {
                                    Rectangle()
                                        .fill(MobileTheme.rail.opacity(0.18))
                                        .frame(width: 1)
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
                                Text(Self.presentationText(for: delivery))
                                    .font(.subheadline)
                                    .foregroundStyle(delivery.isCompleted ? .secondary : .primary)
                                    .strikethrough(delivery.isCompleted, color: .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, index == visibleDeliveries.count - 1 ? 0 : 14)
                        }
                    }
                }
                if orderedDeliveries.count > visibleDeliveries.count {
                    Text("还有 \(orderedDeliveries.count - visibleDeliveries.count) 项，前往周计划查看")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 32)
                }
            }
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
        guard let label, let range = label.range(of: #"(?:(\d{4})\s*[-年]\s*)?(\d{1,2})\s*月\s*(\d{1,2})\s*日?"#, options: .regularExpression) else { return nil }
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
           date < sixMonthsAgo {
            return calendar.date(byAdding: .year, value: 1, to: date)
        }
        return calendar.startOfDay(for: date)
    }

    private static func presentationText(for delivery: DeliverySnapshot) -> String {
        guard let label = delivery.dateLabel,
              let prefix = delivery.text.range(of: #"^\s*(?:(?:\d{4})\s*[-年]\s*)?\d{1,2}\s*月\s*\d{1,2}\s*日(?:\s*[·•]\s*周[一二三四五六日天])?"#, options: .regularExpression),
              dateNumbers(in: String(delivery.text[prefix])) == dateNumbers(in: label)
        else { return delivery.text }
        let remainder = String(delivery.text[prefix.upperBound...])
            .replacingOccurrences(of: #"^\s*[：:·•\-—]?\s*"#, with: "", options: .regularExpression)
        return remainder.isEmpty ? delivery.text : remainder
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

import SwiftUI
import StudyRocketShared

enum MobileTheme {
    static let brand = Color(red: 0.03, green: 0.42, blue: 0.86)
    static let rail = Color(red: 0.00, green: 0.67, blue: 0.69)
    static let completion = Color.teal
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(MobileTheme.rail)
            }
            Text(title)
                .font(.system(.headline, design: .rounded, weight: .semibold))
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .allowsTightening(true)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .center)
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

struct MobileFactField: View {
    let title: String
    let symbol: String
    let placeholder: String
    @Binding var text: String
    var multiline: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(MobileTheme.rail)
                    .frame(width: 22)
                    .padding(.top, 3)
                TextField(placeholder, text: $text, axis: multiline ? .vertical : .horizontal)
                    .font(.body)
                    .lineLimit(multiline ? 4 : 1)
                    .textInputAutocapitalization(.sentences)
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
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(MobileTheme.rail)
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                MobilePrimaryButton(title: actionTitle, action: action)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, MobileTheme.pageInset)
        .padding(.vertical, 48)
        .accessibilityElement(children: .combine)
    }
}

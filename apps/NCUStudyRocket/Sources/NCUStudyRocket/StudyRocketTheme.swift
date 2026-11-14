import SwiftUI
import StudyRocketShared

enum StudyRocketTheme {
    static let pageMaxWidth: CGFloat = 1120
    static let readingMaxWidth: CGFloat = 800
    static let chatMaxWidth: CGFloat = 800
    static let pageInset: CGFloat = 24
    static let compactInset: CGFloat = 18
    static let sectionGap: CGFloat = 24
    static let controlHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 8
    static let bodySize: CGFloat = 15
    static let captionSize: CGFloat = 12
    static let bodyLineSpacing: CGFloat = 5
    static let planRowSpacing: CGFloat = 0
}

struct PageScaffold<Content: View>: View {
    let maxWidth: CGFloat
    @ViewBuilder let content: Content

    init(maxWidth: CGFloat = StudyRocketTheme.pageMaxWidth, @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .padding(geometry.size.width < 760 ? StudyRocketTheme.compactInset : StudyRocketTheme.pageInset)
                    .frame(maxWidth: maxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, StudyRocketTheme.sectionGap)
            }
        }
    }
}

struct PageTitleBar<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: Trailing

    init(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                heading.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                HStack(spacing: 8) { trailing }.fixedSize()
            }
            VStack(alignment: .leading, spacing: 14) {
                heading
                HStack(spacing: 8) { trailing }
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).studyTypography(size: 24, weight: .semibold)
            Text(subtitle).studyTypography(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StudySurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: StudyRocketTheme.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: StudyRocketTheme.cornerRadius, style: .continuous)
                    .strokeBorder(.quaternary)
            }
    }
}

struct ResponsiveColumns<First: View, Second: View>: View {
    @ViewBuilder let first: First
    @ViewBuilder let second: Second
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        StudyAdaptiveColumnsLayout(prefersStacked: dynamicTypeSize.isAccessibilitySize) {
            first.frame(maxWidth: .infinity, alignment: .leading)
            second.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Measure long content at its actual column width. ViewThatFits otherwise
/// tests unwrapped ideal text widths and can stack even a wide desktop page.
private struct StudyAdaptiveColumnsLayout: Layout {
    let prefersStacked: Bool
    private let spacing: CGFloat = 16
    private let minimumColumnWidth: CGFloat = 320

    private func horizontal(at width: CGFloat, count: Int) -> Bool {
        !prefersStacked && width >= minimumColumnWidth * CGFloat(count) + spacing * CGFloat(max(0, count - 1))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? minimumColumnWidth
        let sideBySide = horizontal(at: width, count: subviews.count)
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        let columnWidth = sideBySide ? max(0, width - gaps) / CGFloat(max(1, subviews.count)) : width
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)) }
        return CGSize(width: width, height: sideBySide ? (sizes.map(\.height).max() ?? 0) : sizes.reduce(0) { $0 + $1.height } + gaps)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sideBySide = horizontal(at: bounds.width, count: subviews.count)
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        let columnWidth = sideBySide ? max(0, bounds.width - gaps) / CGFloat(max(1, subviews.count)) : bounds.width
        let childProposal = ProposedViewSize(width: columnWidth, height: nil)
        var position = bounds.origin
        for subview in subviews {
            subview.place(at: position, anchor: .topLeading, proposal: childProposal)
            if sideBySide { position.x += columnWidth + spacing }
            else { position.y += subview.sizeThatFits(childProposal).height + spacing }
        }
    }
}

struct StudyIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    var disabled = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: StudyRocketTheme.controlHeight, height: StudyRocketTheme.controlHeight)
        }
        .buttonStyle(.bordered)
        .labelStyle(.iconOnly)
        .help(label)
        .accessibilityLabel(label)
        .disabled(disabled)
    }
}

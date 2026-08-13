import SwiftUI

enum StudyRocketTheme {
    static let pageMaxWidth: CGFloat = 1120
    static let readingMaxWidth: CGFloat = 800
    static let chatMaxWidth: CGFloat = 920
    static let pageInset: CGFloat = 24
    static let compactInset: CGFloat = 18
    static let sectionGap: CGFloat = 24
    static let controlHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 8
    static let bodySize: CGFloat = 15
    static let captionSize: CGFloat = 12
}

struct PageScaffold<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .padding(geometry.size.width < 760 ? StudyRocketTheme.compactInset : StudyRocketTheme.pageInset)
                    .frame(maxWidth: StudyRocketTheme.pageMaxWidth, alignment: .leading)
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
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 24, weight: .semibold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            trailing
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

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                first.frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
                second.frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 16) {
                first
                second
            }
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

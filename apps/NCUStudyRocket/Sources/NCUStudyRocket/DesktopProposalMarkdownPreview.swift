import SwiftUI
import MarkdownUI
import StudyRocketShared

/// Uses the app's existing full Markdown renderer; tables scroll only inside
/// their comparison column and checklist markers are read-only images.
struct DesktopProposalMarkdownPreview: View {
    let source: String
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var cellWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(StudyRocketMarkdownParser.blocks(from: source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let value):
                    markdown(value)
                case .table(let value, let columns):
                    ScrollView(.horizontal, showsIndicators: true) {
                        markdown(value, isTable: true)
                            .frame(width: cellWidth * CGFloat(columns), alignment: .leading)
                    }
                    .accessibilityHint("表格可左右滚动")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func markdown(_ value: String, isTable: Bool = false) -> some View {
        Markdown(value)
            .markdownTheme(.gitHub)
            .markdownTextStyle { FontFamily(.system()); FontSize(size); ForegroundColor(.primary) }
            .markdownBlockStyle(\.taskListMarker) { configuration in
                Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isCompleted ? Color.secondary : Color.primary)
                    .accessibilityLabel(configuration.isCompleted ? "已完成" : "未完成")
            }
            .markdownBlockStyle(\.tableCell) { configuration in
                Markdown(ProposalMarkdownExcerpt.tableCellMarkdown(configuration.content.renderMarkdown()))
                    .markdownTheme(.basic)
                    .markdownTextStyle { if configuration.row == 0 { FontWeight(.semibold) } }
                    .frame(width: isTable ? max(1, cellWidth - 20) : nil, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            }
            .textSelection(.enabled)
    }
}

#if canImport(SwiftUI) && canImport(CoreText)
import SwiftUI
import CoreText

private struct StudyChatTypographyModifier: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 17
    init(size: CGFloat) { _size = ScaledMetric(wrappedValue: size, relativeTo: .body) }
    func body(content: Content) -> some View {
        content.font(StudyChatTypography.font(size: size)).lineSpacing(max(3, size * 0.18))
    }
}

public extension View {
    func studyChatTypography(size: CGFloat = 17) -> some View {
        modifier(StudyChatTypographyModifier(size: size))
    }
}

/// Changes are computed off the main actor once per content pair. Range-based
/// identities remain stable through layout changes and disclosure expansion.
public struct StudyProposalDiffView: View {
    private struct Input: Equatable, Sendable {
        let original: String
        let proposed: String
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.original.utf8.elementsEqual(rhs.original.utf8) && lhs.proposed.utf8.elementsEqual(rhs.proposed.utf8)
        }
    }
    private struct Loaded { let input: Input; let diff: ProposalLineDiff }
    private let input: Input
    private let originalTitle: String
    private let proposedTitle: String
    private let renderMarkdown: ((String) -> AnyView)?
    @State private var loaded: Loaded?
    @State private var showsFullFile = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(original: String, proposed: String,
                originalTitle: String = "修改前", proposedTitle: String = "修改后",
                renderMarkdown: ((String) -> AnyView)? = nil) {
        input = Input(original: original, proposed: proposed)
        self.originalTitle = originalTitle
        self.proposedTitle = proposedTitle
        self.renderMarkdown = renderMarkdown
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let loaded, loaded.input == input {
                let diff = loaded.diff
                if diff.hunks.isEmpty {
                    Text("内容没有变化").foregroundStyle(.secondary)
                } else {
                    Text("仅显示变化 · 移除 \(diff.removedLineCount) 行，新增 \(diff.addedLineCount) 行")
                        .studyTypography(.callout).foregroundStyle(.secondary)
                    if renderMarkdown != nil {
                        Text("按排版阅读变化；表头与列表上文仅用于理解。源码可展开核对。")
                            .studyTypography(.caption).foregroundStyle(.secondary)
                    }
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(diff.hunks) { hunk in
                            VStack(alignment: .leading, spacing: 8) {
                                if hunk.isCoarse {
                                    Text("此段改动较多，显示整段对照。")
                                        .studyTypography(.caption).foregroundStyle(.secondary)
                                }
                                comparison(diff, original: hunk.originalRange, proposed: hunk.proposedRange)
                            }
                        }
                    }
                }
                DisclosureGroup("查看完整文件", isExpanded: $showsFullFile) {
                    if showsFullFile {
                        comparison(diff, original: diff.originalLines.indices, proposed: diff.proposedLines.indices,
                                   isFullFile: true)
                    }
                }
                .studyTypography(.callout)
            } else {
                ProgressView("正在比较变化…").controlSize(.small)
            }
        }
        .task(id: input) {
            let requested = input
            let worker = Task.detached(priority: .userInitiated) {
                ProposalLineDiff.compare(original: requested.original, proposed: requested.proposed)
            }
            let diff = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            loaded = Loaded(input: requested, diff: diff)
        }
    }

    private func comparison(_ diff: ProposalLineDiff, original: Range<Int>, proposed: Range<Int>, isFullFile: Bool = false) -> some View {
        ProposalDiffComparisonLayout(prefersStacked: dynamicTypeSize.isAccessibilitySize) {
            ProposalDiffSide(title: originalTitle, lines: diff.originalLines, range: original, added: false, isFullFile: isFullFile, renderMarkdown: renderMarkdown)
            ProposalDiffSide(title: proposedTitle, lines: diff.proposedLines, range: proposed, added: true, isFullFile: isFullFile, renderMarkdown: renderMarkdown)
        }
    }
}

/// Choose from the parent's actual width, never the text's unwrapped ideal
/// width. Equal column proposals make long Markdown wrap within each side.
/// Measuring and placing use the same rule without geometry/state feedback.
private struct ProposalDiffComparisonLayout: Layout {
    let prefersStacked: Bool
    private let spacing: CGFloat = 12

    private func horizontal(at width: CGFloat) -> Bool {
        !prefersStacked && width >= 680
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // A nil/infinite proposal is an ideal-size probe, not a wide container.
        // The real parent proposal determines the final arrangement.
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 320
        let sideBySide = horizontal(at: width)
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        let columnWidth = sideBySide ? max(0, width - gaps) / CGFloat(max(1, subviews.count)) : width
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)) }
        let height = sideBySide ? (sizes.map(\.height).max() ?? 0) : sizes.reduce(0) { $0 + $1.height } + gaps
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sideBySide = horizontal(at: bounds.width)
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        let columnWidth = sideBySide ? max(0, bounds.width - gaps) / CGFloat(max(1, subviews.count)) : bounds.width
        let childProposal = ProposedViewSize(width: columnWidth, height: nil)
        var position = bounds.origin
        for subview in subviews {
            subview.place(at: position, anchor: .topLeading, proposal: childProposal)
            if sideBySide {
                position.x += columnWidth + spacing
            } else {
                position.y += subview.sizeThatFits(childProposal).height + spacing
            }
        }
    }
}

private struct ProposalDiffSide: View {
    let title: String
    let lines: [String]
    let range: Range<Int>
    let added: Bool
    let isFullFile: Bool
    let renderMarkdown: ((String) -> AnyView)?
    @State private var showsSource = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StudyLabel(title, systemImage: added ? "plus.circle" : "minus.circle")
                .studyTypography(.callout, weight: .semibold)
            if range.isEmpty {
                Text("无内容").studyTypography(.callout).foregroundStyle(.secondary)
            } else {
                if let renderMarkdown {
                    let excerpt = ProposalMarkdownExcerpt.renderable(lines: lines, range: visibleRange)
                    if excerpt.isEmpty {
                        Text("此处仅有管理标记或空白变化，请展开源码核对。")
                            .studyTypography(.callout).foregroundStyle(.secondary)
                    } else {
                        renderMarkdown(excerpt)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    DisclosureGroup("查看 Markdown 源码", isExpanded: $showsSource) {
                        if showsSource { sourceLines }
                    }
                    .studyTypography(.caption)
                } else { sourceLines }
                if !expanded, range.count > 80 {
                    StudyButton("展开其余 \(range.count - 80) 行") { expanded = true }
                        .studyTypography(.callout)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background((isFullFile ? Color.secondary : added ? Color.green : Color.red).opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var sourceLines: some View {
        LazyVStack(alignment: .leading, spacing: 3) {
            ForEach(visibleRange, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)").studyTypography(.caption).monospacedDigit()
                        .foregroundStyle(.secondary).frame(minWidth: 24, alignment: .trailing)
                        .accessibilityHidden(true)
                    Text(verbatim: lines[index].isEmpty ? " " : lines[index])
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.textSelection(.enabled)
    }

    private var visibleRange: Range<Int> {
        expanded ? range : range.lowerBound..<min(range.upperBound, range.lowerBound + 80)
    }
}
#endif

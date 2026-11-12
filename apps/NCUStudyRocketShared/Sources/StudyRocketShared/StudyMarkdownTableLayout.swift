#if canImport(SwiftUI)
import SwiftUI

/// Equal-width table columns use the scroll viewport's actual proposal. Rows
/// measure wrapped text before placement so short and long cells share borders.
public struct StudyMarkdownTableLayout: Layout {
    public let columnCount: Int
    public init(columnCount: Int) { self.columnCount = max(1, columnCount) }

    private func rowHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        let columnWidth = width / CGFloat(columnCount)
        var heights = [CGFloat](repeating: 0, count: (subviews.count + columnCount - 1) / columnCount)
        for (index, subview) in subviews.enumerated() {
            heights[index / columnCount] = max(heights[index / columnCount],
                subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height)
        }
        return heights
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? CGFloat(columnCount) * 140
        return CGSize(width: width, height: rowHeights(width: width, subviews: subviews).reduce(0, +))
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = rowHeights(width: bounds.width, subviews: subviews)
        let columnWidth = bounds.width / CGFloat(columnCount)
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let row = index / columnCount, column = index % columnCount
            if column == 0 && row > 0 { y += heights[row - 1] }
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(column) * columnWidth, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: columnWidth, height: heights[row]))
        }
    }
}
#endif

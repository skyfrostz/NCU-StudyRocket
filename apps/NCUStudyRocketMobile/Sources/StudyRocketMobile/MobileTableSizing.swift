import Foundation

/// Short tables wrap within the reading column. Wider multi-column tables
/// scroll only when their readable minimum actually exceeds that column.
struct MobileTableSizing: Equatable {
    let width: CGFloat
    let cellWidth: CGFloat
    let scrollsHorizontally: Bool

    init(columns: Int, availableWidth: CGFloat, preferredColumnWidth: CGFloat) {
        let count = max(1, columns)
        let available = max(1, availableWidth)
        width = count <= 2 ? available : max(available, CGFloat(count) * preferredColumnWidth)
        cellWidth = max(1, (width - CGFloat(count + 1)) / CGFloat(count) - 16)
        scrollsHorizontally = width > available + 1
    }
}

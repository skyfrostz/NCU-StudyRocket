import Foundation

/// Line ranges use zero-based offsets into the exact, newline-preserving input.
public struct ProposalDiffHunk: Equatable, Sendable, Identifiable {
    public let originalRange: Range<Int>
    public let proposedRange: Range<Int>
    /// A bounded fallback may include unchanged lines within a large replacement.
    public let isCoarse: Bool
    public var id: String { "\(originalRange.lowerBound):\(originalRange.count):\(proposedRange.lowerBound):\(proposedRange.count)" }
}

public struct ProposalLineDiff: Equatable, Sendable {
    public let originalLines: [String]
    public let proposedLines: [String]
    public let hunks: [ProposalDiffHunk]
    public let removedLineCount: Int
    public let addedLineCount: Int

    /// Unique-line anchors (patience diff) keep separated edits separate. Small
    /// gaps use exact LCS, with a shared cell budget across the entire document.
    /// Work is O(n log n + budget), never an unbounded n*m table.
    public static func compare(original: String, proposed: String) -> Self {
        let old = original.isEmpty ? [] : original.components(separatedBy: "\n")
        let new = proposed.isEmpty ? [] : proposed.components(separatedBy: "\n")
        var builder = Builder(old: old.map { Data($0.utf8) }, new: new.map { Data($0.utf8) })
        builder.compare(0..<old.count, 0..<new.count)
        return Self(originalLines: old, proposedLines: new, hunks: builder.hunks,
                    removedLineCount: builder.hunks.reduce(0) { $0 + $1.originalRange.count },
                    addedLineCount: builder.hunks.reduce(0) { $0 + $1.proposedRange.count })
    }

    private struct Builder {
        let old: [Data]
        let new: [Data]
        var hunks: [ProposalDiffHunk] = []
        var remainingCells = 262_144

        mutating func compare(_ original: Range<Int>, _ proposed: Range<Int>, useAnchors: Bool = true) {
            var a = original.lowerBound, b = proposed.lowerBound
            var endA = original.upperBound, endB = proposed.upperBound
            while a < endA, b < endB, old[a] == new[b] { a += 1; b += 1 }
            while a < endA, b < endB, old[endA - 1] == new[endB - 1] { endA -= 1; endB -= 1 }
            guard a < endA || b < endB else { return }
            if a == endA || b == endB { append(a..<endA, b..<endB); return }
            if useAnchors {
                let anchors = uniqueAnchors(a..<endA, b..<endB)
                if !anchors.isEmpty {
                    for (x, y) in anchors {
                        compare(a..<x, b..<y, useAnchors: false)
                        a = x + 1; b = y + 1
                    }
                    compare(a..<endA, b..<endB, useAnchors: false)
                    return
                }
            }
            let rows = endA - a + 1, columns = endB - b + 1
            guard rows <= 65_536 / columns, rows * columns <= remainingCells else {
                append(a..<endA, b..<endB, coarse: true)
                return
            }
            remainingCells -= rows * columns
            var lcs = [Int](repeating: 0, count: rows * columns)
            for i in stride(from: rows - 2, through: 0, by: -1) {
                for j in stride(from: columns - 2, through: 0, by: -1) {
                    lcs[i * columns + j] = old[a + i] == new[b + j]
                        ? 1 + lcs[(i + 1) * columns + j + 1]
                        : max(lcs[(i + 1) * columns + j], lcs[i * columns + j + 1])
                }
            }
            var x = a, y = b, startA = a, startB = b
            while x < endA || y < endB {
                if x < endA, y < endB, old[x] == new[y] {
                    append(startA..<x, startB..<y)
                    x += 1; y += 1; startA = x; startB = y
                } else if y < endB && (x == endA || lcs[(x - a) * columns + y - b + 1] >= lcs[(x - a + 1) * columns + y - b]) {
                    y += 1
                } else { x += 1 }
            }
            append(startA..<x, startB..<y)
        }

        mutating func append(_ a: Range<Int>, _ b: Range<Int>, coarse: Bool = false) {
            guard !a.isEmpty || !b.isEmpty else { return }
            hunks.append(ProposalDiffHunk(originalRange: a, proposedRange: b, isCoarse: coarse))
        }

        func uniqueAnchors(_ a: Range<Int>, _ b: Range<Int>) -> [(Int, Int)] {
            var oldPositions: [Data: Int] = [:], newPositions: [Data: Int] = [:]
            for i in a { oldPositions[old[i]] = oldPositions[old[i]] == nil ? i : -1 }
            for i in b { newPositions[new[i]] = newPositions[new[i]] == nil ? i : -1 }
            let pairs = a.compactMap { i -> (Int, Int)? in
                guard oldPositions[old[i]] == i, let j = newPositions[old[i]], j >= 0 else { return nil }
                return (i, j)
            }
            var tails: [Int] = [], previous = [Int](repeating: -1, count: pairs.count)
            for i in pairs.indices {
                var low = 0, high = tails.count
                while low < high {
                    let mid = (low + high) / 2
                    if pairs[tails[mid]].1 < pairs[i].1 { low = mid + 1 } else { high = mid }
                }
                if low > 0 { previous[i] = tails[low - 1] }
                if low == tails.count { tails.append(i) } else { tails[low] = i }
            }
            var result: [(Int, Int)] = [], index = tails.last ?? -1
            while index >= 0 { result.append(pairs[index]); index = previous[index] }
            return result.reversed()
        }
    }
}

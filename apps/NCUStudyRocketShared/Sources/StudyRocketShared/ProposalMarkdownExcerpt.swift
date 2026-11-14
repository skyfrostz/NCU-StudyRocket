import Foundation

/// Presentation only: the exact diff and stored proposal bytes remain untouched.
public enum ProposalMarkdownExcerpt {
    /// Table cells are inline in GFM. Promote saved checkbox prefixes and <br>
    /// separators to read-only block content inside the native rendered cell.
    public static func tableCellMarkdown(_ source: String) -> String {
        let checkbox = try! NSRegularExpression(pattern: #"^\s*(?:[-+*]\s+)?\\?\[([ xX])\\?\]\s+"#)
        return source.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
            .components(separatedBy: "\n")
            .map { line in
                guard let match = checkbox.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let whole = Range(match.range, in: line), let state = Range(match.range(at: 1), in: line) else { return line }
                return "- [" + line[state] + "] " + line[whole.upperBound...]
            }.joined(separator: "\n")
    }

    public static func renderable(lines: [String], range: Range<Int>) -> String {
        guard !range.isEmpty else { return "" }
        let cleaned = visibleLines(lines)
        var selected = Set(range)
        var openFence: (index: Int, marker: String)?
        for index in 0..<range.upperBound {
            let text = cleaned[index].trimmingCharacters(in: .whitespaces)
            if let fence = openFence {
                if text.hasPrefix(fence.marker) {
                    if index >= range.lowerBound { selected.insert(fence.index) }
                    openFence = nil
                } else if range.contains(index) { selected.insert(fence.index) }
            } else if text.hasPrefix("```") || text.hasPrefix("~~~") {
                openFence = (index, String(text.prefix(3)))
            }
        }
        var closingFence: String?
        if let fence = openFence, selected.contains(fence.index) { closingFence = fence.marker }

        var tableStart: Int?
        for index in 0..<range.upperBound {
            guard isTableRow(cleaned[index]) else { tableStart = nil; continue }
            if tableStart == nil { tableStart = index }
            if range.contains(index), let start = tableStart, start + 1 < cleaned.count,
               isTableDelimiter(cleaned[start + 1]) {
                selected.insert(start); selected.insert(start + 1)
            }
        }
        if let first = range.first, indentation(cleaned[first]) > 0 {
            var currentIndent = indentation(cleaned[first])
            var cursor = first
            while cursor > 0 {
                cursor -= 1
                let line = cleaned[cursor]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
                let indent = indentation(line)
                if indent < currentIndent, isListItem(line) {
                    selected.insert(cursor); currentIndent = indent
                    if indent == 0 { break }
                }
            }
        }
        var result: [String] = [], previous: Int?
        for index in selected.sorted() {
            if let previous, index > previous + 1,
               !cleaned[previous...index].allSatisfy(isTableRow) { result.append("") }
            result.append(cleaned[index]); previous = index
        }
        if let closingFence { result.append(closingFence) }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Preserve code examples, but hide HTML comments (including managed markers)
    // in the rendered presentation. Keep one output line per input line.
    private static func visibleLines(_ lines: [String]) -> [String] {
        var inComment = false, fence: String?
        return lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                if trimmed.hasPrefix(marker) { fence = nil }
                return line
            }
            if !inComment, trimmed.hasPrefix("```") || (!inComment && trimmed.hasPrefix("~~~")) {
                fence = String(trimmed.prefix(3)); return line
            }
            var remainder = line[...], output = ""
            while !remainder.isEmpty {
                if inComment {
                    guard let end = remainder.range(of: "-->") else { break }
                    remainder = remainder[end.upperBound...]; inComment = false
                } else if let start = remainder.range(of: "<!--") {
                    output += remainder[..<start.lowerBound]
                    remainder = remainder[start.upperBound...]; inComment = true
                } else { output += remainder; break }
            }
            return output
        }
    }
    private static func indentation(_ line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.count }
    private static func isListItem(_ line: String) -> Bool {
        line.range(of: #"^\s*(?:[-+*]|\d+[.)])\s+"#, options: .regularExpression) != nil
    }
    private static func isTableRow(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).contains("|")
    }
    private static func isTableDelimiter(_ line: String) -> Bool {
        let cells = line.trimmingCharacters(in: .whitespaces).split(separator: "|", omittingEmptySubsequences: true)
        return !cells.isEmpty && cells.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }
}

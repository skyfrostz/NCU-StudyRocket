import Foundation
import StudyRocketShared

func runProposalLineDiffChecks() {
    @discardableResult
    func checked(_ before: String, _ after: String) -> ProposalLineDiff {
        let diff = ProposalLineDiff.compare(original: before, proposed: after)
        var reconstructed = diff.originalLines
        var lastOld = 0, lastNew = 0
        for hunk in diff.hunks {
            precondition(hunk.originalRange.lowerBound >= lastOld && hunk.proposedRange.lowerBound >= lastNew)
            precondition(!hunk.originalRange.isEmpty || !hunk.proposedRange.isEmpty)
            precondition(Array(diff.originalLines[lastOld..<hunk.originalRange.lowerBound]) ==
                         Array(diff.proposedLines[lastNew..<hunk.proposedRange.lowerBound]))
            lastOld = hunk.originalRange.upperBound; lastNew = hunk.proposedRange.upperBound
        }
        for hunk in diff.hunks.reversed() {
            reconstructed.replaceSubrange(hunk.originalRange, with: diff.proposedLines[hunk.proposedRange])
        }
        precondition(Data(reconstructed.joined(separator: "\n").utf8) == Data(after.utf8), "Diff must reconstruct exact target bytes")
        precondition(Set(diff.hunks.map(\.id)).count == diff.hunks.count)
        return diff
    }

    precondition(checked("", "").hunks.isEmpty)
    precondition(checked("相同😀\n", "相同😀\n").hunks.isEmpty)
    precondition(checked("", "新增\n第二行\n").hunks.first?.originalRange.isEmpty == true)
    precondition(checked("删除\n", "").hunks.first?.proposedRange.isEmpty == true)
    precondition(checked("a", "a\n").hunks.count == 1)
    precondition(checked("a\n", "a").hunks.count == 1)
    precondition(checked("é", "e\u{301}").hunks.count == 1, "Canonical Unicode equivalence must not hide changed file bytes")
    checked("\r\nA\r\n", "\nA\n")
    let separated = checked("开始\n旧甲\n保持\n旧乙\n结尾", "开始\n新甲\n保持\n新乙\n结尾")
    precondition(separated.hunks.count == 2)
    precondition(separated.hunks[0].originalRange == 1..<2 && separated.hunks[1].originalRange == 3..<4)
    let repeated = checked("same\na\nsame\nb\nsame", "same\nx\nsame\ny\nsame")
    precondition(repeated.hunks.count == 2)
    let markers = checked("<!-- studyrocket:weekly:start -->\nA\n<!-- studyrocket:weekly:end -->",
                          "<!-- studyrocket:weekly:start -->\nB\n<!-- studyrocket:weekly:end -->")
    precondition(markers.hunks.count == 1 && markers.hunks[0].originalRange == 1..<2)
    let changedMarker = checked("<!-- studyrocket:weekly:start -->\nA", "<!-- changed -->\nA")
    precondition(changedMarker.hunks.first?.originalRange == 0..<1)

    var longLines = (0..<20_000).map { "资料第 \($0) 行" }
    let original = longLines.joined(separator: "\n")
    longLines[20] = "替换首处"; longLines[19_980] = "替换末处"
    let longDiff = checked(original, longLines.joined(separator: "\n"))
    precondition(longDiff.hunks.count == 2 && longDiff.removedLineCount == 2 && longDiff.addedLineCount == 2)
    let coarse = checked(Array(repeating: "旧重复行", count: 8_000).joined(separator: "\n"),
                         Array(repeating: "新重复行", count: 8_000).joined(separator: "\n"))
    precondition(coarse.hunks.count == 1 && coarse.hunks[0].isCoarse)

    // Deterministic edit histories exercise insertion/deletion/repetition without
    // embedding another copy of the diff algorithm as the test oracle.
    var seed: UInt64 = 13
    func random(_ maximum: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1
        return Int((seed >> 32) % UInt64(maximum))
    }
    let vocabulary = ["A", "B", "重复", "😀", "", "<!-- marker -->"]
    for _ in 0..<300 {
        var before: [String] = []
        for _ in 0..<random(25) { before.append(vocabulary[random(vocabulary.count)]) }
        var after = before
        for _ in 0..<8 {
            switch random(3) {
            case 0: after.insert(vocabulary[random(vocabulary.count)], at: random(after.count + 1))
            case 1: if !after.isEmpty { after.remove(at: random(after.count)) }
            default: if !after.isEmpty { after[random(after.count)] = vocabulary[random(vocabulary.count)] }
            }
        }
        checked(before.joined(separator: "\n"), after.joined(separator: "\n"))
    }
    precondition(ProposalMarkdownExcerpt.tableCellMarkdown("[x] 完成<br>- [ ] 下一项") == "- [x] 完成\n\n- [ ] 下一项")
    precondition(ProposalMarkdownExcerpt.tableCellMarkdown(#"\[x\] 完成<br>- \[ \] 下一项"#) == "- [x] 完成\n\n- [ ] 下一项")
    let markdown = [
        "## 计划", "<!-- studyrocket:weekly:start -->",
        "| 日期 | 任务 |", "| --- | --- |", "| 周一 | 不应带入 |", "| 周二 | **修改任务**<br>第二项 |",
        "<!-- studyrocket:weekly:end -->", "- [x] 完成报告", "  附上 **证据**", "",
        "<!-- studyrocket:metadata:start", "隐藏内容", "-->", "## 下一节"
    ]
    let rowExcerpt = ProposalMarkdownExcerpt.renderable(lines: markdown, range: 5..<6)
    precondition(rowExcerpt == "| 日期 | 任务 |\n| --- | --- |\n| 周二 | **修改任务**<br>第二项 |")
    precondition(!rowExcerpt.contains("不应带入"))
    let renderedBlocks = StudyRocketMarkdownParser.blocks(from: rowExcerpt)
    precondition(renderedBlocks.count == 1)
    if case .table(_, let columns) = renderedBlocks[0] { precondition(columns == 2) }
    else { preconditionFailure("Changed table rows require a renderable table header") }
    precondition(ProposalMarkdownExcerpt.renderable(lines: markdown, range: 8..<9) == "- [x] 完成报告\n  附上 **证据**")
    precondition(ProposalMarkdownExcerpt.renderable(lines: markdown, range: 10..<13).isEmpty)
    precondition(ProposalMarkdownExcerpt.renderable(lines: markdown, range: 13..<14) == "## 下一节")
    precondition(ProposalMarkdownExcerpt.renderable(lines: ["```html", "<!-- literal -->", "```"], range: 1..<2) == "```html\n<!-- literal -->\n```")
    precondition(ProposalMarkdownExcerpt.renderable(lines: markdown, range: 1..<2).isEmpty)
    precondition(ProposalMarkdownExcerpt.renderable(lines: markdown, range: 0..<0).isEmpty)
    print("Proposal Markdown excerpts passed: isolated table rows, context, multiline checklist, headings, hidden comments and literal fenced code")

    print("Proposal diff checks passed: exact reconstruction, separated edits, Unicode, blank/newline, repeated lines, 20k lines and bounded fallback")
}

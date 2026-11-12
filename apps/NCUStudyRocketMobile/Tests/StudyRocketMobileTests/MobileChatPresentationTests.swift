import Foundation
import XCTest
import SwiftUI
import StudyRocketShared
@testable import StudyRocketMobile

final class MobileChatPresentationTests: XCTestCase {
    func testShortTablesFitReadingWidthAndWideTablesScrollOnlyWhenNecessary() {
        for width: CGFloat in [220, 280, 353, 700] {
            let short = MobileTableSizing(columns: 2, availableWidth: width, preferredColumnWidth: 144)
            XCTAssertEqual(short.width, width)
            XCTAssertFalse(short.scrollsHorizontally)
            XCTAssertEqual((short.cellWidth + 16) * 2 + 3, width, accuracy: 0.001)
        }
        let wide = MobileTableSizing(columns: 4, availableWidth: 320, preferredColumnWidth: 144)
        XCTAssertTrue(wide.scrollsHorizontally)
        XCTAssertEqual(wide.width, 576)
        XCTAssertFalse(MobileTableSizing(columns: 4, availableWidth: 700, preferredColumnWidth: 144).scrollsHorizontally)
        XCTAssertFalse(MobileTableSizing(columns: 2, availableWidth: 280, preferredColumnWidth: 300).scrollsHorizontally)
    }

    @MainActor
    func testSystemTypographyPreservesInlineTraitsLinksAndText() {
        let parsed = MobileMarkdownLeaf.inlineContent(source: "**中文 Bold** [来源](https://example.com) `code`", heading: false)
        let styled = MobileMarkdownLeaf.styledContent(parsed, size: 17)
        XCTAssertEqual(String(styled.characters), String(parsed.characters))
        let bold = styled.runs.first { String(styled[$0.range].characters).contains("中文 Bold") }
        XCTAssertEqual(bold?.font, Font.system(size: 17, weight: .semibold, design: .default))
        let code = styled.runs.first { String(styled[$0.range].characters) == "code" }
        XCTAssertEqual(code?.font, Font.system(size: 17 * 0.94, weight: .regular, design: .monospaced))
        XCTAssertTrue(styled.runs.contains { $0.link?.absoluteString == "https://example.com" })
    }

    func testDelayedRefreshCannotOverrideNewerNavigationIntent() {
        var intent = MobileChatScrollIntent()
        let automaticStart = intent.version
        XCTAssertFalse(intent.shouldNavigateAfterRefresh(startedAt: automaticStart, explicit: false, succeeded: true))
        let explicitStart = intent.version
        XCTAssertTrue(intent.shouldNavigateAfterRefresh(startedAt: explicitStart, explicit: true, succeeded: true))
        intent.noteNavigation() // The user starts reading older messages while the request waits.
        XCTAssertFalse(intent.shouldNavigateAfterRefresh(startedAt: explicitStart, explicit: true, succeeded: true))
        XCTAssertFalse(intent.shouldNavigateAfterRefresh(startedAt: intent.version, explicit: true, succeeded: false))
    }

    @MainActor
    func testImagesKeepMarkdownUIRendererInEveryLeafShape() {
        for source in ["示意 ![结构](https://example.com/diagram.png)",
                       "## 示意 ![结构](https://example.com/diagram.png)",
                       "| 单元格 ![结构](https://example.com/diagram.png) |"] {
            XCTAssertTrue(MobileMarkdownLeaf.requiresImageRenderer(source))
        }
        XCTAssertFalse(MobileMarkdownLeaf.requiresImageRenderer("[普通链接](https://example.com)"))
    }

    @MainActor
    func testNativeMarkdownLeafPreservesInlineMeaningAndLineBreaks() {
        let value = MobileMarkdownLeaf.inlineContent(source: "中文 **bold** and *italic*\n第二行 [来源](https://example.com) `code`\n")
        XCTAssertEqual(String(value.characters), "中文 bold and italic\n第二行 来源 code")
        XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertTrue(value.runs.contains { $0.link?.absoluteString == "https://example.com" })
    }

    @MainActor
    func testHeadingRemovesSyntaxWithoutDroppingInlineFormatting() {
        let value = MobileMarkdownLeaf.inlineContent(source: "## 中文 **Heading**\n", heading: true)
        XCTAssertEqual(String(value.characters), "中文 Heading")
        XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }
}

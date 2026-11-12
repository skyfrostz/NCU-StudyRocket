import Foundation
import SwiftUI
import StudyRocketShared

/// MarkdownUI owns block layout; native Text preserves inline semantics while
/// following the app's system typography and Dynamic Type.
struct MobileMarkdownLeaf: View {
    private let parsed: AttributedString
    private let baseBold: Bool
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 17

    init(source: String, size: CGFloat = 17, heading: Bool = false, bold: Bool = false) {
        baseBold = heading || bold
        parsed = Self.inlineContent(source: source, heading: heading)
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    /// Native Text cannot render Markdown images; those leaves stay with
    /// MarkdownUI's image-capable renderer, including headings and table cells.
    static func requiresImageRenderer(_ source: String) -> Bool { source.contains("![") }

    static func inlineContent(source: String, heading: Bool = false) -> AttributedString {
        let inline = heading
            ? source.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
            : source
        let value = inline.trimmingCharacters(in: .newlines)
        return (try? AttributedString(markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
    }

    var body: some View {
        Text(styled)
            .lineSpacing(max(3, size * 0.18))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var styled: AttributedString {
        Self.styledContent(parsed, size: size, baseBold: baseBold)
    }

    /// Apply traits once to the system font. Links and non-font intents survive;
    /// code retains its monospaced face without changing prose typography.
    static func styledContent(_ parsed: AttributedString, size: CGFloat, baseBold: Bool = false) -> AttributedString {
        var value = parsed
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            let bold = baseBold || intent.contains(.stronglyEmphasized)
            let italic = intent.contains(.emphasized)
            var font = Font.system(size: intent.contains(.code) ? size * 0.94 : size,
                                   weight: bold ? .semibold : .regular,
                                   design: intent.contains(.code) ? .monospaced : .default)
            if italic { font = font.italic() }
            value[run.range].font = font
            value[run.range].inlinePresentationIntent = intent.subtracting([.stronglyEmphasized, .emphasized, .code])
        }
        return value
    }
}

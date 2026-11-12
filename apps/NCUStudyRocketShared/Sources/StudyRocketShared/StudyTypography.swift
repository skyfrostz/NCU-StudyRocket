#if canImport(SwiftUI) && canImport(CoreText)
import SwiftUI
import CoreText
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum StudyTypography {
    /// Explicit size is already scaled. Semantic controls use studyTypography.
    public static func font(size: CGFloat = 17, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        let font = Font.system(size: size, weight: weight)
        return italic ? font.italic() : font
    }

    /// Native controls use the platform font and its normal language fallback.
    public static func ctFont(size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> CTFont {
        let value: CGFloat
        switch weight {
        case .ultraLight: value = -0.8
        case .thin: value = -0.6
        case .light: value = -0.4
        case .medium: value = 0.23
        case .semibold: value = 0.3
        case .bold: value = 0.4
        case .heavy: value = 0.56
        case .black: value = 0.62
        default: value = 0
        }
        #if os(macOS)
        let native = NSFont.systemFont(ofSize: size, weight: NSFont.Weight(rawValue: value)) as CTFont
        #elseif canImport(UIKit)
        let native = UIFont.systemFont(ofSize: size, weight: UIFont.Weight(rawValue: value)) as CTFont
        #else
        let native = CTFontCreateUIFontForLanguage(.system, size, nil)!
        #endif
        return italic ? CTFontCreateCopyWithSymbolicTraits(native, size, nil, .traitItalic, .traitItalic) ?? native : native
    }

    public static func baseSize(for style: Font.TextStyle) -> CGFloat {
        #if os(macOS)
        switch style {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline, .body: return 13
        case .callout: return 12
        case .subheadline: return 11
        case .footnote, .caption, .caption2: return 10
        @unknown default: return 13
        }
        #else
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline, .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 17
        }
        #endif
    }

    /// Compatibility for attributed CJK runs: follow system language fallback.
    public static func chineseCTFont(size: CGFloat, weight: Font.Weight = .regular) -> CTFont {
        CTFontCreateForString(ctFont(size: size, weight: weight), "中文" as CFString, CFRange(location: 0, length: 2))
    }

    public static func chineseFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(size: size, weight: weight)
    }

    /// Songti is an explicit editorial choice reserved for the seasonal verse.
    public static func poetryCTFont(size: CGFloat, weight: Font.Weight = .regular) -> CTFont {
        let base = chineseFace ?? ctFont(size: size, weight: weight)
        let sized = CTFontCreateCopyWithAttributes(base, size, nil, nil)
        return [.semibold, .bold, .heavy, .black].contains(weight)
            ? CTFontCreateCopyWithSymbolicTraits(sized, size, nil, .traitBold, .traitBold) ?? sized : sized
    }

    public static func poetryFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(poetryCTFont(size: size, weight: weight))
    }

    private static let chineseFace: CTFont? = {
        #if os(macOS)
        let system = CTFontCreateWithName("Songti SC" as CFString, 17, nil)
        // Core Text silently returns Helvetica when an optional font is absent.
        if (CTFontCopyFamilyName(system) as String).contains("Songti") { return system }
        #endif
        for name in ["SourceHanSerifCN-Regular", "SourceHanSerifCN-Bold"] {
            if let url = Bundle.module.url(forResource: name, withExtension: "otf", subdirectory: "Fonts") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
        let font = CTFontCreateWithName("SourceHanSerifCN-Regular" as CFString, 17, nil)
        guard CTFontCopyPostScriptName(font) as String == "SourceHanSerifCN-Regular" else { return nil }
        return font
    }()
}

/// Compatibility for rich chat inline runs; the same font family is now app-wide.
public enum StudyChatTypography {
    public static func font(size: CGFloat = 17, bold: Bool = false, italic: Bool = false) -> Font {
        StudyTypography.font(size: size, weight: bold ? .bold : .regular, italic: italic)
    }
}

private struct StudyTypographyModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let poetry: Bool
    init(size: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight, poetry: Bool = false) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.poetry = poetry
    }
    func body(content: Content) -> some View {
        let font = poetry ? StudyTypography.poetryFont(size: size, weight: weight) : StudyTypography.font(size: size, weight: weight)
        content.font(font).environment(\.studyControlFont, font)
    }
}

public extension View {
    func studyTypography(_ style: Font.TextStyle = .body, weight: Font.Weight? = nil) -> some View {
        let font = weight.map { Font.system(style).weight($0) } ?? Font.system(style)
        return self.font(font).environment(\.studyControlFont, font)
    }
    func studyTypography(size: CGFloat, relativeTo style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> some View {
        modifier(StudyTypographyModifier(size: size, relativeTo: style, weight: weight))
    }
    func studyPoetryTypography(size: CGFloat = 24, relativeTo style: Font.TextStyle = .title2,
                               weight: Font.Weight = .semibold) -> some View {
        modifier(StudyTypographyModifier(size: size, relativeTo: style, weight: weight, poetry: true))
    }
}
#endif

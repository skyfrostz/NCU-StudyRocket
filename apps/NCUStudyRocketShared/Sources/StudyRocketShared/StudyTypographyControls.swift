#if canImport(SwiftUI) && canImport(CoreText)
import SwiftUI

struct StudyControlFontKey: EnvironmentKey {
    static let defaultValue: Font = .body
}
extension EnvironmentValues {
    var studyControlFont: Font {
        get { self[StudyControlFontKey.self] }
        set { self[StudyControlFontKey.self] = newValue }
    }
}

/// Native buttons may synthesize a system-font title even when their parent
/// has a custom font. An explicitly styled Text label keeps the native control
/// while using the same semantic typography as the surrounding app.
public struct StudyControlText: View {
    private let title: String
    @Environment(\.studyControlFont) private var font
    public init(_ title: String) { self.title = title }
    public var body: some View { Text(title).font(font) }
}

public struct StudyLabel: View {
    private let title: String
    private let systemImage: String
    public init(_ title: String, systemImage: String) { self.title = title; self.systemImage = systemImage }
    public var body: some View {
        Label { StudyControlText(title) } icon: { Image(systemName: systemImage) }
    }
}

public struct StudyButton: View {
    private let title: String
    private let systemImage: String?
    private let role: ButtonRole?
    private let action: () -> Void
    public init(_ title: String, systemImage: String? = nil, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.role = role; self.action = action
    }
    public var body: some View {
        Button(role: role, action: action) {
            if let systemImage { StudyLabel(title, systemImage: systemImage) }
            else { StudyControlText(title) }
        }
    }
}

public struct StudyMenu<Content: View>: View {
    private let title: String
    private let content: Content
    public init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    public var body: some View { Menu { content } label: { StudyControlText(title) } }
}
#endif

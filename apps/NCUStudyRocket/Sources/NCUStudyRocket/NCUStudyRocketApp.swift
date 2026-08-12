import SwiftUI

@main
struct NCUStudyRocketApp: App {
    @StateObject private var workspace = WorkspaceStore()
    @StateObject private var document = MarkdownDocumentModel(root: URL(fileURLWithPath: "/Users/skyfrost/Desktop/大学"))
    var body: some Scene {
        WindowGroup("NCU StudyRocket") { ContentView().environmentObject(workspace).environmentObject(document).frame(minWidth: 980, minHeight: 680) }
            .commands { CommandGroup(replacing: .newItem) {}; CommandMenu("StudyRocket") { Button("打开 Codex：今天复盘") { CodexLink.open(workspace.rootURL, prompt: "今天复盘") }.keyboardShortcut("1", modifiers: [.command, .shift]); Button("打开 Codex：排下周") { CodexLink.open(workspace.rootURL, prompt: "排下周") }.keyboardShortcut("2", modifiers: [.command, .shift]) } }
    }
}

enum CodexLink {
    static func open(_ root: URL, prompt: String) { var c = URLComponents(); c.scheme = "codex"; c.host = "new"; c.queryItems = [URLQueryItem(name: "path", value: root.path), URLQueryItem(name: "prompt", value: prompt)]; if let url = c.url { NSWorkspace.shared.open(url) } }
}

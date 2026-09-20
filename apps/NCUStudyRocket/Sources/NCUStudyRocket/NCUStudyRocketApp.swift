import SwiftUI
import StudyRocketShared

final class StudyRocketAppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
}

@main
struct NCUStudyRocketApp: App {
    @NSApplicationDelegateAdaptor(StudyRocketAppDelegate.self) private var appDelegate
    @StateObject private var workspace: WorkspaceStore
    @StateObject private var document: MarkdownDocumentModel
    @StateObject private var chat: StudyChatStore
    @StateObject private var reminders: ReminderScheduler

    init() {
        let selfCheck = StudyRocketSelfCheckConfiguration.current
        let root = selfCheck?.repositoryRoot ?? URL(fileURLWithPath: "/Users/skyfrost/Desktop/大学")
        _workspace = StateObject(wrappedValue: WorkspaceStore(configuration: selfCheck))
        _document = StateObject(wrappedValue: MarkdownDocumentModel(root: root))
        _chat = StateObject(wrappedValue: StudyChatStore(configuration: selfCheck))
        _reminders = StateObject(wrappedValue: ReminderScheduler(disabled: selfCheck != nil))
    }
    var body: some Scene {
        WindowGroup("NCU StudyRocket") { ContentView().environmentObject(workspace).environmentObject(document).environmentObject(chat).environmentObject(reminders).frame(minWidth: 980, minHeight: 680).onAppear { appDelegate.onTerminate = { chat.disconnect() } } }
            .commands { CommandGroup(replacing: .newItem) {}; CommandMenu("StudyRocket") { Button("打开学业对话") { NotificationCenter.default.post(name: .studyRocketOpenChat, object: nil) }.keyboardShortcut("0", modifiers: [.command, .shift]); Button("今天复盘") { chat.prepare(prompt: ReminderRoute.daily.prompt); NotificationCenter.default.post(name: .studyRocketOpenChat, object: nil) }.keyboardShortcut("1", modifiers: [.command, .shift]); Button("排下周") { chat.prepare(prompt: ReminderRoute.weekly.prompt); NotificationCenter.default.post(name: .studyRocketOpenChat, object: nil) }.keyboardShortcut("2", modifiers: [.command, .shift]) } }
    }
}

enum CodexLink {
    static func open(_ root: URL, prompt: String) { var c = URLComponents(); c.scheme = "codex"; c.host = "new"; c.queryItems = [URLQueryItem(name: "path", value: root.path), URLQueryItem(name: "prompt", value: prompt)]; if let url = c.url { NSWorkspace.shared.open(url) } }
}

extension Notification.Name { static let studyRocketOpenChat = Notification.Name("studyRocketOpenChat") }

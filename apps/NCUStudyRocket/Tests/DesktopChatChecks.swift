import AppKit
import SwiftUI
import StudyRocketShared
import ImageIO
import UniformTypeIdentifiers

private final class DeferredHostProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((DeferredHostProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}

    func reply<T: Encodable>(_ value: T) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(value))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
struct DesktopChatChecks {
    @MainActor static func main() async throws {
        func composerHeight(_ text: String, width: CGFloat) -> CGFloat {
            let view = NSHostingView(rootView: DesktopChatTextInput(text: .constant(text), submit: {}, stop: {}, receiveFiles: { _ in })
                .frame(width: width))
            view.layoutSubtreeIfNeeded()
            return view.fittingSize.height
        }
        let shortHeight = composerHeight("简短输入", width: 280)
        let wrappedText = String(repeating: "这是一段自然换行的输入文字", count: 5)
        let narrowHeight = composerHeight(wrappedText, width: 280)
        let wideHeight = composerHeight(wrappedText, width: 760)
        let cappedHeight = composerHeight(String(repeating: wrappedText, count: 12), width: 280)
        precondition(shortHeight == 42, "empty or short native editor must retain the minimum height")
        precondition(narrowHeight > shortHeight && narrowHeight > wideHeight, "actual hosted native editor must grow for automatic line wrapping and adapt to width")
        precondition(cappedHeight == 152, "long native editing content must cap at 152 points and scroll")
        let nativeEditor = DesktopChatTextInput.makeEditor()
        nativeEditor.string = wrappedText
        _ = DesktopChatTextInput.measuredHeight(nativeEditor, width: 280)
        nativeEditor.string = "短"
        precondition(DesktopChatTextInput.measuredHeight(nativeEditor, width: 280) == 42, "deleting wrapped content must shrink the editor")
        print("PASS: actual hosted composer grows for soft wraps, adapts to width, shrinks and caps at 152 points")

        let resizeText = String(repeating: "中", count: 120) + "\n第二行用于检查换行"
        let resizeHost = NSHostingView(rootView: DesktopChatTextInput(text: .constant(resizeText), submit: {}, stop: {}, receiveFiles: { _ in }))
        func composerScroll(in view: NSView) -> DesktopChatTextInput.ComposerScrollView? {
            if let scroll = view as? DesktopChatTextInput.ComposerScrollView { return scroll }
            return view.subviews.lazy.compactMap { composerScroll(in: $0) }.first
        }
        resizeHost.frame = NSRect(x: 0, y: 0, width: 90, height: 152)
        resizeHost.layoutSubtreeIfNeeded()
        guard let scroll = composerScroll(in: resizeHost), let editingView = scroll.documentView as? DesktopChatTextInput.Editor,
              let container = editingView.textContainer, let layout = editingView.layoutManager else { fatalError("native editor must exist in the actual hosted view") }
        for width: CGFloat in [760, 280, 760] {
            resizeHost.setFrameSize(NSSize(width: width, height: 152))
            resizeHost.layoutSubtreeIfNeeded()
            scroll.layoutSubtreeIfNeeded()
            // Reproduce a late speculative narrow measurement after the actual
            // viewport widened. Measurement may not mutate the live document.
            _ = scroll.heightForProposal(90)
            precondition(abs(editingView.frame.width - scroll.contentView.bounds.width) < 1, "live editor must track the actual resized clip view, never a speculative width")
            precondition(abs(container.containerSize.width - (scroll.contentView.bounds.width - 4)) < 1, "TextKit width must follow the actual viewport after every resize")
            layout.ensureLayout(for: container)
            let range = layout.glyphRange(forCharacterRange: (resizeText as NSString).range(of: "第二行用于检查换行"), actualCharacterRange: nil)
            var fragments = 0
            layout.enumerateLineFragments(forGlyphRange: range) { _, _, _, _, _ in fragments += 1 }
            precondition(fragments == 1, "short second line must fit the actual editor after expansion")
            precondition(layout.usedRect(for: container).maxY + 16 <= editingView.frame.height + 1, "document height must contain laid out text without top clipping")
        }
        print("PASS: live NSTextView survives narrow-to-wide resize and late narrow measurement without stale wrapping or clipped document height")

        var displayed: [ChatStreamDisplayCoalescer.Update] = []
        let display = ChatStreamDisplayCoalescer { displayed.append($0) }
        for text in ["第", "第一", "第一项"] {
            display.enqueue(.init(turnID: "turn", itemID: "one", text: text, phase: .finalAnswer))
        }
        display.enqueue(.init(turnID: "turn", itemID: "two", text: "第二项", phase: .commentary))
        precondition(displayed.isEmpty, "stream bursts must not invalidate the transcript for every token")
        display.flush()
        precondition(displayed.map(\.text) == ["第一项", "第二项"], "terminal flush must retain all items and their latest text")
        display.enqueue(.init(turnID: "old-connection", itemID: "old", text: "迟到内容", phase: .finalAnswer))
        display.cancel()
        display.enqueue(.init(turnID: "new-connection", itemID: "new", text: "当前内容", phase: .finalAnswer))
        try await Task.sleep(for: .milliseconds(120))
        precondition(displayed.map(\.text) == ["第一项", "第二项", "当前内容"], "cancelled generation must not publish after reconnect")
        display.flush()
        precondition(displayed.count == 3, "terminal flush must not replay already displayed text")
        print("PASS: streaming display coalesces bursts, flushes final text and isolates cancelled connections")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-chat-checks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let token = root.appendingPathComponent("session")
        try Data("isolated-test-token".utf8).write(to: token)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeferredHostProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let host = StudyRocketHostClient(endpoint: URL(string: "http://fixture.invalid")!, session: session, tokenURL: token)
        let store = StudyChatStore(hostClient: host)
        store.draft = "尚未发送的原文\n第二行"
        store.prepare(prompt: "请排下周")
        precondition(store.draft == "尚未发送的原文\n第二行\n\n请排下周")
        store.prepare(prompt: "请排下周")
        precondition(store.draft == "尚未发送的原文\n第二行\n\n请排下周", "repeated shortcuts must not duplicate the appended request")
        store.prepare(prompt: "用户已经确认合并的原文", replacingDraft: true)
        precondition(store.draft == "用户已经确认合并的原文")
        store.prepare(prompt: "   ")
        precondition(store.draft == "用户已经确认合并的原文")
        print("PASS: shortcuts preserve unsent multiline drafts and only explicitly confirmed composition replaces them")
        let deferred = DeferredBox()
        DeferredHostProtocol.handler = { proto in
            switch proto.request.url!.path {
            case "/v1/health":
                proto.reply(HealthResponse(hostVersion: "fixture", repositoryBound: true, codexReady: true,
                    pairedDeviceCount: 0, activeThreadID: "isolated-chat", repositoryID: RequestSigning.bodyHash(Data(root.path.utf8)), dynamicToolsReady: true, capabilities: ["targeted-interrupt"]))
            case "/v1/chat/history": proto.reply(ChatHistoryResponse(revision: "fixture", messages: []))
            case "/v1/proposals": deferred.set(proto)
            case "/v1/events": break // Keep the stream open until disconnect cancels it.
            default: fatalError("Unexpected request")
            }
        }
        let connect = Task { await store.connect(to: root) }
        for _ in 0..<200 {
            if deferred.get() != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let response = deferred.get() else { fatalError("proposal request was not reached") }
        store.draft = "连接过程中继续输入的文字"
        response.reply(ProposalListResponse(proposals: []))
        await connect.value
        precondition(store.connectionState == .connected && store.draft == "连接过程中继续输入的文字",
            "connection completion must not restore an old shortcut over newer typing")
        print("PASS: connection completion preserves text typed after a shortcut")
        store.disconnect()
        deferred.clear()
        let secondConnect = Task { await store.connect(to: root) }
        for _ in 0..<200 {
            if deferred.get() != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let staleResponse = deferred.get() else { fatalError("second proposal request was not reached") }
        store.disconnect()
        store.draft = "新连接中的草稿"
        staleResponse.reply(ProposalListResponse(proposals: [ProposalDTO(id: "old", turnID: "old-turn", relativePath: "PROFILE.md",
            originalContent: "old", proposedContent: "stale", reason: "fixture", baseHash: "fixture", kind: "markdown")]))
        await secondConnect.value
        precondition(store.transcript.proposals.isEmpty, "stale proposals leaked after disconnect")
        precondition(store.connectionState == .disconnected && store.draft == "新连接中的草稿")
        print("PASS: delayed proposal response cannot change a disconnected chat")

        // Also exercise an availability failure after disconnect. It must not start stdio.
        let healthWait = DeferredBox()
        DeferredHostProtocol.handler = { healthWait.set($0) }
        let reconnect = Task { await store.connect(to: root) }
        for _ in 0..<200 {
            if healthWait.get() != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let delayedHealth = healthWait.get() else { fatalError("health request was not reached") }
        store.disconnect()
        reconnect.cancel()
        delayedHealth.client?.urlProtocol(delayedHealth, didFailWithError: URLError(.timedOut))
        await reconnect.value
        precondition(store.connectionState == .disconnected, "late connection failure changed state")
        print("PASS: cancelled availability probe cannot start a fallback connection")

        let historicalMessages = [
            ChatMessageDTO(id: "old-failed/user", role: "user", text: "旧请求", date: Date(timeIntervalSince1970: 1), turnID: "old-failed", status: "failed"),
            ChatMessageDTO(id: "latest/user", role: "user", text: "最新请求", date: Date(timeIntervalSince1970: 2), turnID: "latest", status: "completed"),
            ChatMessageDTO(id: "latest/assistant", role: "assistant", text: "最新回答", date: Date(timeIntervalSince1970: 3), turnID: "latest", status: "completed")
        ]
        DeferredHostProtocol.handler = { proto in
            switch proto.request.url!.path {
            case "/v1/health":
                proto.reply(HealthResponse(hostVersion: "fixture", repositoryBound: true, codexReady: true,
                    pairedDeviceCount: 0, activeThreadID: "isolated-chat", repositoryID: RequestSigning.bodyHash(Data(root.path.utf8)), dynamicToolsReady: true, capabilities: ["targeted-interrupt"]))
            case "/v1/chat/history": proto.reply(ChatHistoryResponse(revision: "history", messages: historicalMessages))
            case "/v1/proposals": proto.reply(ProposalListResponse(proposals: []))
            case "/v1/events": break
            default: fatalError("Unexpected replay fixture request")
            }
        }
        await store.connect(to: root)
        precondition(store.connectionState == .connected)
        for event in [
            ChatStreamEvent(kind: "status", turnID: "old-failed", status: "inProgress"),
            ChatStreamEvent(kind: "delta", turnID: "old-failed", itemID: "old-partial", text: "旧流文字"),
            ChatStreamEvent(kind: "status", turnID: "old-failed", text: "context_budget", status: "failed")
        ] { store.consumeHostEvent(HostEventEnvelope(kind: "chat", chat: event)) }
        try await Task.sleep(for: .milliseconds(100))
        precondition(store.connectionState == .connected && store.errorMessage == nil && !store.isBusy,
            "replayed historical failure must not poison a connected service")
        precondition(store.transcript.turns.first(where: { $0.id == "old-failed" })?.finalMessages.isEmpty == true)
        precondition(store.transcript.turns.first(where: { $0.id == "latest" })?.status == .completed)
        store.consumeHostEvent(HostEventEnvelope(kind: "chat", chat:
            ChatStreamEvent(kind: "status", turnID: "new-failure", text: "本轮请求失败", status: "failed")))
        precondition(store.connectionState == .connected && store.errorMessage == "本轮请求失败",
            "a new turn failure must remain visible without declaring the transport disconnected")
        precondition(store.transcript.turns.first(where: { $0.id == "new-failure" })?.status == .failed)
        store.disconnect()
        print("PASS: authoritative terminal history ignores stale SSE replay and preserves current turn errors")
        let lifecycle = LifecycleFixture(root: root)
        DeferredHostProtocol.handler = { lifecycle.respond($0) }
        await store.connect(to: root)
        store.draft = "第一条消息"
        store.send()
        for _ in 0..<100 {
            if store.transcript.turns.contains(where: { $0.id == "turn-1" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(lifecycle.sentCount == 1 && store.isBusy)
        store.draft = "打断后发送的新消息"
        store.send()
        store.draft = "继续输入的下一份草稿"
        for _ in 0..<100 {
            if lifecycle.interruptedTarget != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(lifecycle.interruptedTarget == "turn-1", "cancel must target the original turn")
        precondition(lifecycle.sentCount == 1 && store.isBusy && store.isStopping,
            "cancel acknowledgement cannot submit the replacement before terminal history")
        lifecycle.completeFirst()
        for _ in 0..<150 {
            if lifecycle.sentCount == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(lifecycle.sentCount == 2, "replacement must be sent exactly once after terminal history")
        precondition(store.draft == "继续输入的下一份草稿", "frozen replacement must not overwrite newer typing")
        store.consumeHostEvent(HostEventEnvelope(kind: "chat", chat: .init(kind: "delta", turnID: "turn-1", itemID: "late", text: "迟到的上一条消息")))
        try await Task.sleep(for: .milliseconds(150))
        precondition(store.transcript.turns.first(where: { $0.id == "turn-1" })?.finalMessages.contains(where: { $0.id == "late" }) != true)
        precondition(lifecycle.sentCount == 2)
        for _ in 0..<100 {
            if store.transcript.turns.contains(where: { $0.id == "turn-2" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        store.consumeHostEvent(HostEventEnvelope(kind: "chat", chat: .init(kind: "status", turnID: "turn-2", text: "确定失败", status: "failed")))
        precondition(!store.isBusy)
        store.retryLast()
        for _ in 0..<100 {
            if lifecycle.sentCount == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(lifecycle.sentCount == 3 && Set(lifecycle.requestIDs).count == 3,
            "explicit retry of a known terminal failure must create a fresh attempt identity")
        precondition(store.draft == "继续输入的下一份草稿")
        let sessionDirectory = DesktopChatDraftCache.directory(for: root)
        let preservedSession = sessionDirectory.appendingPathExtension("test-preserved")
        try FileManager.default.moveItem(at: sessionDirectory, to: preservedSession)
        try Data("write barrier".utf8).write(to: sessionDirectory)
        store.draft = "保存失败时不能丢失的输入"
        store.send()
        precondition(store.draft == "保存失败时不能丢失的输入" && lifecycle.sentCount == 3,
            "failed durable freeze must not clear composer or send an unrecorded request")
        try FileManager.default.removeItem(at: sessionDirectory)
        try FileManager.default.moveItem(at: preservedSession, to: sessionDirectory)
        store.disconnect()
        print("PASS: failed durable freeze preserves composer and prevents an unrecorded send")
        print("PASS: known terminal failure retries with a new UUID without replacing newer composer text")
        print("PASS: targeted stop waits for authoritative terminal, sends frozen replacement once, protects new typing and rejects old deltas")
        let evictionRoot = root.appendingPathComponent("history-evicted")
        try FileManager.default.createDirectory(at: evictionRoot, withIntermediateDirectories: true)
        let eviction = LifecycleFixture(root: evictionRoot)
        DeferredHostProtocol.handler = { eviction.respond($0) }
        let evictionStore = StudyChatStore(hostClient: host)
        await evictionStore.connect(to: evictionRoot)
        evictionStore.draft = "离线前的原请求"
        evictionStore.send()
        for _ in 0..<100 {
            if evictionStore.transcript.turns.contains(where: { $0.id == "turn-1" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        eviction.completeFirst(omitFromHistory: true)
        eviction.setReceiptFault("target")
        evictionStore.draft = "历史窗口淘汰后仍应发送的新消息"
        evictionStore.send()
        for _ in 0..<100 {
            if evictionStore.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(eviction.sentCount == 1 && evictionStore.isStopping,
            "a terminal receipt for a different turn cannot authorize the replacement")
        for fault in ["operation", "status"] {
            eviction.setReceiptFault(fault)
            evictionStore.errorMessage = nil
            evictionStore.retryLast()
            for _ in 0..<100 {
                if evictionStore.errorMessage != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(eviction.sentCount == 1 && evictionStore.isStopping,
                "mismatched operation or terminal status cannot authorize replacement")
        }
        eviction.setReceiptFault("")
        evictionStore.retryLast()
        for _ in 0..<100 {
            if eviction.sentCount == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(eviction.sentCount == 2,
            "the exact typed terminal must release replacement even when recent history has evicted the target")
        evictionStore.disconnect()
        try? FileManager.default.removeItem(at: DesktopChatDraftCache.directory(for: evictionRoot))
        print("PASS: typed interrupt validates target and recovers a terminal evicted from bounded history")
        DeferredHostProtocol.handler = nil

        let cacheFile = root.appendingPathComponent("attachment.txt")
        try Data("attachment fixture".utf8).write(to: cacheFile)
        var attachment = try DesktopChatDraftCache.importFile(cacheFile, root: root)
        DesktopChatDraftCache.save(.init(text: "持久草稿", attachments: [attachment]), root: root)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86400)],
            ofItemAtPath: attachment.localURL.deletingLastPathComponent().path)
        let cached = DesktopChatDraftCache.load(root: root)
        precondition(FileManager.default.fileExists(atPath: attachment.localURL.path), "old unsent bytes must survive retention cleanup")
        precondition(cached?.text == "持久草稿" && cached?.attachments.first?.metadata.state == .unknown)
        precondition(cached?.attachments.first?.metadata.sha256 == RequestSigning.bodyHash(Data("attachment fixture".utf8)))
        attachment.metadata.expiresAt = .now.addingTimeInterval(-1)
        DesktopChatDraftCache.save(.init(text: "到期仍保留文字", attachments: [attachment]), root: root)
        precondition(DesktopChatDraftCache.load(root: root)?.attachments.first?.metadata.state == .expired)
        try? FileManager.default.removeItem(at: DesktopChatDraftCache.directory(for: root))
        print("PASS: draft attachment identity survives restart, interrupted upload is unknown and expired attachment remains visible")

        let importRoot = root.appendingPathComponent("format-import")
        defer { try? FileManager.default.removeItem(at: DesktopChatDraftCache.directory(for: importRoot)) }
        let heic = root.appendingPathComponent("synthetic.heic")
        let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let writer = CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(writer), "fixture must encode actual HEIC data")
        let originalHEIC = try Data(contentsOf: heic)
        let converted = try DesktopChatDraftCache.importFile(heic, root: importRoot)
        let convertedBytes = try Data(contentsOf: converted.localURL)
        precondition(converted.metadata.filename == "synthetic.jpg" && converted.metadata.mimeType == "image/jpeg")
        precondition(convertedBytes.starts(with: [0xff, 0xd8]) && converted.metadata.byteCount == convertedBytes.count)
        precondition(converted.metadata.sha256 == RequestSigning.bodyHash(convertedBytes))
        let unchangedHEIC = try Data(contentsOf: heic)
        precondition(unchangedHEIC == originalHEIC, "HEIC conversion must leave the selected original unchanged")
        let oversizeJSON = root.appendingPathComponent("oversize.json")
        FileManager.default.createFile(atPath: oversizeJSON.path, contents: Data())
        let jsonHandle = try FileHandle(forWritingTo: oversizeJSON)
        try jsonHandle.truncate(atOffset: UInt64(32 * 1_048_576 + 1)); try jsonHandle.close()
        do { _ = try DesktopChatDraftCache.importFile(oversizeJSON, root: importRoot); fatalError("JSON must use the 32 MiB limit") } catch is StudyChatError {}
        for ext in ["epub", "mobi", "tsv"] {
            let unsupported = root.appendingPathComponent("unapproved." + ext)
            try Data("fixture".utf8).write(to: unsupported)
            do { _ = try DesktopChatDraftCache.importFile(unsupported, root: importRoot); fatalError("unapproved file format must be rejected") } catch is StudyChatError {}
        }
        print("PASS: actual HEIC converts to a verified JPEG copy without changing source; JSON limit and approved formats are enforced")

        let scopeA = root.appendingPathComponent("scope-A"), scopeB = root.appendingPathComponent("scope-B")
        for scope in [scopeA, scopeB] { try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true) }
        defer { for scope in [scopeA, scopeB] { try? FileManager.default.removeItem(at: DesktopChatDraftCache.directory(for: scope)) } }
        var scopedAttachment = try DesktopChatDraftCache.importFile(cacheFile, root: scopeA)
        scopedAttachment.metadata.state = .ready; scopedAttachment.metadata.expiresAt = .now.addingTimeInterval(-1)
        DesktopChatDraftCache.markSent(scopedAttachment.metadata, root: scopeA)
        let attachmentJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scopedAttachment))
        let failedID = UUID().uuidString
        let savedScope: [String: Any] = ["failed": ["id": failedID, "text": "A失败消息", "attachments": [attachmentJSON]],
            "composer": ["text": "A未发草稿", "attachments": [attachmentJSON]], "failedWasTerminal": true]
        try DesktopChatDraftCache.writeDurably(JSONSerialization.data(withJSONObject: savedScope), to: DesktopChatDraftCache.directory(for: scopeA).appendingPathComponent("session.json"))
        let scopeStore = StudyChatStore(hostClient: host)
        let fixtureA = LifecycleFixture(root: scopeA), fixtureB = LifecycleFixture(root: scopeB)
        DeferredHostProtocol.handler = { fixtureA.respond($0) }; await scopeStore.connect(to: scopeA)
        precondition(scopeStore.draft == "A未发草稿" && scopeStore.lastSubmitted == "A失败消息")
        precondition(FileManager.default.fileExists(atPath: scopedAttachment.localURL.path), "expired sent bytes referenced by a failed retry or composer must survive cleanup")
        DeferredHostProtocol.handler = { fixtureB.respond($0) }; await scopeStore.connect(to: scopeB)
        precondition(scopeStore.draft.isEmpty && scopeStore.attachments.isEmpty && scopeStore.lastSubmitted == nil, "new repository cannot inherit the previous scope's draft or failed intent")
        scopeStore.retryLast()
        try await Task.sleep(for: .milliseconds(30))
        precondition(fixtureB.sentCount == 0, "new scope must not retry the previous repository's frozen message")
        DeferredHostProtocol.handler = { fixtureA.respond($0) }; await scopeStore.connect(to: scopeA)
        precondition(scopeStore.draft == "A未发草稿" && scopeStore.attachments.first?.id == scopedAttachment.id && scopeStore.lastSubmitted == "A失败消息")
        scopeStore.disconnect(); DeferredHostProtocol.handler = nil
        // Direct cleanup reads every persisted reference itself, independent of
        // the currently selected repository or its in-memory protection set.
        for reference in ["active", "replacement", "failed", "composer"] {
            let referenced: [String: Any] = [reference: ["attachments": [attachmentJSON], "text": "保留", "id": failedID]]
            try DesktopChatDraftCache.writeDurably(JSONSerialization.data(withJSONObject: referenced), to: DesktopChatDraftCache.directory(for: scopeA).appendingPathComponent("session.json"))
            _ = DesktopChatDraftCache.load(root: scopeA)
            precondition(FileManager.default.fileExists(atPath: scopedAttachment.localURL.path), "all persisted composer/frozen/retry references must protect expired local bytes")
        }
        let scopedSessionURL = DesktopChatDraftCache.directory(for: scopeA).appendingPathComponent("session.json")
        try Data("{corrupt".utf8).write(to: scopedSessionURL)
        _ = DesktopChatDraftCache.load(root: scopeA)
        precondition(FileManager.default.fileExists(atPath: scopedAttachment.localURL.path), "unreadable frozen session must skip cleanup")
        try DesktopChatDraftCache.writeDurably(JSONSerialization.data(withJSONObject: savedScope), to: scopedSessionURL)
        let corruptDraft = DesktopChatDraftCache.directory(for: scopeA).appendingPathComponent("draft.json")
        try Data("{corrupt".utf8).write(to: corruptDraft)
        precondition(DesktopChatDraftCache.load(root: scopeA) == nil)
        precondition(FileManager.default.fileExists(atPath: scopedAttachment.localURL.path), "unreadable draft must conservatively skip all retention cleanup")
        let corruptStore = StudyChatStore(hostClient: host)
        await corruptStore.connect(to: scopeA)
        precondition(corruptStore.errorMessage?.contains("缓存") == true, "unreadable drafts must show an explicit recovery issue")
        corruptStore.disconnect()
        print("PASS: repository scope isolates drafts and failed retries; retention protects their bytes and skips unreadable archives")

        let ttlRoot = root.appendingPathComponent("attachment-ttl")
        try FileManager.default.createDirectory(at: ttlRoot, withIntermediateDirectories: true)
        var ttlAttachment = try DesktopChatDraftCache.importFile(cacheFile, root: ttlRoot)
        ttlAttachment.metadata.state = .ready
        ttlAttachment.metadata.uploadedBytes = ttlAttachment.metadata.byteCount
        ttlAttachment.metadata.expiresAt = .now.addingTimeInterval(2)
        DesktopChatDraftCache.save(.init(text: "到期时保留的输入", attachments: [ttlAttachment]), root: ttlRoot)
        let ttlFixture = LifecycleFixture(root: ttlRoot)
        DeferredHostProtocol.handler = { ttlFixture.respond($0) }
        let ttlStore = StudyChatStore(hostClient: host)
        await ttlStore.connect(to: ttlRoot)
        precondition(ttlStore.attachments.first?.metadata.state == .ready)
        try await Task.sleep(for: .milliseconds(2100))
        ttlStore.refreshAttachmentExpiry()
        precondition(ttlStore.attachments.first?.metadata.state == .expired && !ttlStore.canSubmit)
        ttlStore.retryAttachment(ttlAttachment.id)
        precondition(ttlStore.attachments.first?.id != ttlAttachment.id,
            "an expired unsent attachment must clone the retained local bytes under a new upload identity")
        precondition(ttlStore.draft == "到期时保留的输入" && FileManager.default.fileExists(atPath: ttlAttachment.localURL.path))
        try await Task.sleep(for: .milliseconds(50))
        ttlStore.disconnect()
        try? FileManager.default.removeItem(at: DesktopChatDraftCache.directory(for: ttlRoot))
        DeferredHostProtocol.handler = nil
        print("PASS: an open composer transitions expired attachments and renews with a fresh ID without losing local bytes")

        let repository = MarkdownRepository(root: root, backupRoot: root.appendingPathComponent("backups"))
        try Data("original".utf8).write(to: root.appendingPathComponent("PROFILE.md"))
        do {
            try await repository.saveBatch([
                .init(relative: "PROFILE.md", content: "first", loadedHash: repository.hash("original")),
                .init(relative: "PROFILE.md", content: "second", loadedHash: repository.hash("original"))
            ])
            fatalError("duplicate target should fail before writing")
        } catch MarkdownError.conflict {}
        let unchanged = try repository.read("PROFILE.md")
        precondition(unchanged == "original")
        print("PASS: Desktop rejects duplicate targets before batch writes")

        _ = NSApplication.shared
        let cases = ["好", "高数作业3.1 3.2的ddl是什么时候", "第一行较长一些\n短行", String(repeating: "长段落与 mixed English 🏸 验证换行。", count: 16), "https://example.com/" + String(repeating: "abcdef", count: 35)]
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/chat-audit-20261105")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            for width: CGFloat in [300, 650, 1000] {
                for (index, text) in cases.enumerated() {
                    let renderer = ImageRenderer(content: UserMessageView(message: ChatMessage(id: "test", role: .user, text: text, date: .now, turnState: .completed), showTime: .constant(false))
                        .frame(width: width).accentColor(.blue).environmentObject(store).environment(\.colorScheme, scheme))
                    renderer.proposedSize = .init(width: width, height: nil)
                    guard let image = renderer.cgImage else { fatalError("message failed to render") }
                    precondition(image.width == Int(width) && image.height > 30)
                    let bounds = bubbleBounds(image)
                    precondition(CGFloat(bounds.width) <= min(600, width * 0.7) + 1, "bubble exceeds row limit")
                    precondition(bounds.maxX >= Int(width) - 2, "bubble is not right aligned")
                    if index == 0 { precondition(bounds.width < 65, "short bubble expanded") }
                }
                let page = VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(cases.enumerated()), id: \.offset) { index, text in
                        UserMessageView(message: ChatMessage(id: "test-\(index)", role: .user, text: text, date: .now, turnState: .completed), showTime: .constant(false))
                    }
                }.frame(width: width).padding(24).background(scheme == .dark ? Color.black : Color.white)
                    .accentColor(.blue).environmentObject(store).environment(\.colorScheme, scheme)
                let rendered = ImageRenderer(content: page)
                guard let png = rendered.nsImage?.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) else { fatalError("no PNG") }
                try png.write(to: output.appendingPathComponent("messages-\(Int(width))-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        print("PASS: actual message view renders short, multiline, mixed and long-link messages at three widths")
    }
    private static func bubbleBounds(_ image: CGImage) -> (width: Int, maxX: Int) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var minX = image.width, maxX = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let i = (y * image.width + x) * 4
                if bytes[i + 3] > 10 && bytes[i + 3] < 120 && abs(Int(bytes[i]) - Int(bytes[i + 2])) < 4 {
                    minX = min(minX, x); maxX = max(maxX, x)
                }
            }
        }
        precondition(maxX >= minX, "bubble pixels missing")
        return (maxX - minX + 1, maxX)
    }

}

private final class DeferredBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DeferredHostProtocol?
    func set(_ value: DeferredHostProtocol) { lock.lock(); defer { lock.unlock() }; self.value = value }
    func get() -> DeferredHostProtocol? { lock.lock(); defer { lock.unlock() }; return value }
    func clear() { lock.lock(); defer { lock.unlock() }; value = nil }
}

private final class LifecycleFixture: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var texts: [String] = []
    private var ids: [String] = []
    var requestIDs: [String] { lock.lock(); defer { lock.unlock() }; return ids }
    private var terminal = false
    private var omitHistory = false
    private var receiptFault = ""
    private var target: String?
    init(root: URL) { self.root = root }
    var sentCount: Int { lock.lock(); defer { lock.unlock() }; return texts.count }
    var interruptedTarget: String? { lock.lock(); defer { lock.unlock() }; return target }
    func completeFirst(omitFromHistory: Bool = false) { lock.lock(); terminal = true; omitHistory = omitFromHistory; lock.unlock() }
    func setReceiptFault(_ value: String) { lock.lock(); receiptFault = value; lock.unlock() }
    func respond(_ proto: DeferredHostProtocol) {
        lock.lock(); defer { lock.unlock() }
        func history() -> ChatHistoryResponse {
            if omitHistory { return .init(revision: "evicted", messages: [], terminalTurns: []) }
            return .init(revision: "fixture", messages: texts.enumerated().map { index, text in
                .init(id: "user-\(index + 1)", role: "user", text: text, date: Date(timeIntervalSince1970: Double(index + 10)),
                      turnID: "turn-\(index + 1)", status: index == 0 && terminal ? "interrupted" : "inProgress")
            }, terminalTurns: terminal ? [.init(turnID: "turn-1", status: "interrupted")] : [])
        }
        switch proto.request.url!.path {
        case "/v1/health":
            proto.reply(HealthResponse(hostVersion: "fixture", repositoryBound: true, codexReady: true, pairedDeviceCount: 0,
                activeThreadID: "isolated-chat", repositoryID: RequestSigning.bodyHash(Data(root.path.utf8)), dynamicToolsReady: true, capabilities: ["targeted-interrupt"]))
        case "/v1/chat/history": proto.reply(history())
        case "/v1/chat/send":
            let body = Self.body(proto.request)
            let request = try! JSONDecoder().decode(SendChatRequest.self, from: body)
            texts.append(request.text); ids.append(request.clientRequestID); proto.reply(history())
        case "/v1/chat/interrupt":
            let request = try! JSONDecoder().decode(InterruptRequest.self, from: Self.body(proto.request))
            target = request.turnID
            let returnedID = receiptFault == "target" ? "wrong-turn" : request.turnID
            let returnedOperation = receiptFault == "operation" ? "wrong-operation" : request.operationID!
            let completed = terminal && request.turnID == "turn-1"
            proto.reply(ChatInterruptResponse(targetTurnID: returnedID, operationID: returnedOperation,
                status: receiptFault == "status" ? "failed" : completed ? "interrupted" : "cancelling",
                terminal: completed ? .init(turnID: returnedID, status: "interrupted") : nil))
        case "/v1/proposals": proto.reply(ProposalListResponse(proposals: []))
        case "/v1/events": break
        default: fatalError("Unexpected lifecycle request")
        }
    }
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; result.append(bytes, count: count) }
        return result
    }
}

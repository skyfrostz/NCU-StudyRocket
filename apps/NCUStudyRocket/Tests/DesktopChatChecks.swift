import AppKit
import SwiftUI
import StudyRocketShared

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
        let deferred = DeferredBox()
        DeferredHostProtocol.handler = { proto in
            switch proto.request.url!.path {
            case "/v1/health":
                proto.reply(HealthResponse(hostVersion: "fixture", repositoryBound: true, codexReady: true,
                    pairedDeviceCount: 0, activeThreadID: "isolated-chat", repositoryID: RequestSigning.bodyHash(Data(root.path.utf8)), dynamicToolsReady: true))
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
        store.disconnect()
        store.draft = "新连接中的草稿"
        response.reply(ProposalListResponse(proposals: [ProposalDTO(id: "old", turnID: "old-turn", relativePath: "PROFILE.md",
            originalContent: "old", proposedContent: "stale", reason: "fixture", baseHash: "fixture", kind: "markdown")]))
        await connect.value
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
        DeferredHostProtocol.handler = nil

        let repository = MarkdownRepository(root: root, backupRoot: root.appendingPathComponent("backups"))
        try Data("original".utf8).write(to: root.appendingPathComponent("PROFILE.md"))
        do {
            try repository.saveBatch([
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
                    let renderer = ImageRenderer(content: UserMessageView(message: ChatMessage(id: "test", role: .user, text: text, date: .now, turnState: .failed), showTime: .constant(true))
                        .frame(width: width).accentColor(.blue).environment(\.colorScheme, scheme))
                    renderer.proposedSize = .init(width: width, height: nil)
                    guard let image = renderer.cgImage else { fatalError("message failed to render") }
                    precondition(image.width == Int(width) && image.height > 30)
                    let bounds = blueBounds(image)
                    precondition(CGFloat(bounds.width) <= min(600, width * 0.7) + 1, "bubble exceeds row limit")
                    precondition(bounds.maxX >= Int(width) - 2, "bubble is not right aligned")
                    if index == 0 { precondition(bounds.width < 65, "short bubble expanded") }
                }
                let page = VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(cases.enumerated()), id: \.offset) { index, text in
                        UserMessageView(message: ChatMessage(id: "test-\(index)", role: .user, text: text, date: .now, turnState: .failed), showTime: .constant(true))
                    }
                }.frame(width: width).padding(24).background(scheme == .dark ? Color.black : Color.white)
                    .accentColor(.blue).environment(\.colorScheme, scheme)
                let rendered = ImageRenderer(content: page)
                guard let png = rendered.nsImage?.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) else { fatalError("no PNG") }
                try png.write(to: output.appendingPathComponent("messages-\(Int(width))-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        print("PASS: actual message view renders short, multiline, mixed and long-link messages at three widths")
    }
    private static func blueBounds(_ image: CGImage) -> (width: Int, maxX: Int) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var minX = image.width, maxX = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let i = (y * image.width + x) * 4
                if bytes[i + 2] > 180 && bytes[i] < 100 && bytes[i + 1] < 180 && bytes[i + 3] > 200 {
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
}

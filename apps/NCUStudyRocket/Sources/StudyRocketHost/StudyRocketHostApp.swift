import AppKit
import Darwin
import Foundation
import Network
import SwiftUI
import StudyRocketShared
import StudyRocketChatCore

private struct PublicHealthResponse: Encodable {
    let apiVersion = StudyRocketAPI.version
    let hostVersion: String
    let repositoryBound: Bool
    let codexReady: Bool
    let dynamicToolsReady: Bool
}

@main
enum StudyRocketHostApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = HostApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private final class HostApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let host = HostController()
    private var statusItem: NSStatusItem?
    private var dashboardWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "StudyRocket Host")
        item.button?.toolTip = "StudyRocket 手机连接"
        statusItem = item
        rebuildMenu()
        showDashboard(nil)
        let shouldAutostart = ProcessInfo.processInfo.environment["STUDYROCKET_HOST_AUTOSTART"] == "1"
            || CommandLine.arguments.contains("--autostart")
        NSLog("StudyRocket Host launched (autostart=%@)", shouldAutostart ? "yes" : "no")
        if shouldAutostart {
            host.start()
            refreshMenuSoon()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        host.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func menuWillOpen(_ menu: NSMenu) {
        host.refreshDevices()
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        addStatus("StudyRocket 手机连接", to: menu)
        addStatus(host.status.title, to: menu)
        addStatus(host.chatStatus, to: menu)
        addStatus(host.repositoryStatus, to: menu)
        addStatus(host.codexStatus, to: menu)
        addStatus(host.tailscaleStatus.title, to: menu)
        addStatus("已配对设备 \(host.devices.count) 台", to: menu)
        menu.addItem(.separator())

        let showDashboard = NSMenuItem(title: "显示连接面板", action: #selector(showDashboard(_:)), keyEquivalent: "")
        showDashboard.target = self
        menu.addItem(showDashboard)

        let toggle = NSMenuItem(title: host.isRunning ? "停止手机连接" : "启动手机连接", action: #selector(toggleHost), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        if host.chatBusy {
            let interrupt = NSMenuItem(title: "停止当前 Codex 回合", action: #selector(stopTurn), keyEquivalent: "")
            interrupt.target = self
            menu.addItem(interrupt)
        }
        if let code = host.pairingCode {
            addStatus("一次性配对码：\(code)", to: menu)
            addStatus("5 分钟内有效，最多尝试 5 次", to: menu)
        }
        if !host.devices.isEmpty {
            menu.addItem(.separator())
            addStatus("已配对设备", to: menu)
            for device in host.devices {
                let deviceItem = NSMenuItem(title: device.isRevoked ? "\(device.name)（已撤销）" : "撤销 \(device.name)", action: #selector(revokeDevice(_:)), keyEquivalent: "")
                deviceItem.target = self
                deviceItem.representedObject = device.id
                deviceItem.isEnabled = !device.isRevoked
                menu.addItem(deviceItem)
            }
        }
        menu.addItem(.separator())
        let openMain = NSMenuItem(title: "打开主应用", action: #selector(openMainApplication), keyEquivalent: "")
        openMain.target = self
        menu.addItem(openMain)
        if let address = host.tailscaleStatus.address {
            let copyAddress = NSMenuItem(title: "复制手机连接地址", action: #selector(copyAddress(_:)), keyEquivalent: "")
            copyAddress.target = self
            copyAddress.representedObject = address
            menu.addItem(copyAddress)
        }
        if let error = host.errorMessage {
            menu.addItem(.separator())
            addStatus(error, to: menu)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 StudyRocket Host", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
    }

    private func addStatus(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func refreshMenuSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(350)) { [weak self] in
            self?.rebuildMenu()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            self?.rebuildMenu()
        }
    }

    @objc private func toggleHost() {
        host.isRunning ? host.stop() : host.start()
        refreshMenuSoon()
    }

    @objc private func showDashboard(_ sender: Any?) {
        if dashboardWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "StudyRocket Host"
            window.contentView = NSHostingView(rootView: HostDashboardView(host: host))
            window.minSize = NSSize(width: 680, height: 520)
            window.isReleasedWhenClosed = false
            window.center()
            dashboardWindow = window
        }
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func stopTurn() {
        host.stopTurn()
        refreshMenuSoon()
    }

    @objc private func revokeDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        host.revoke(id)
        rebuildMenu()
    }

    @objc private func openMainApplication() {
        host.openMainApplication()
    }

    @objc private func copyAddress(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String else { return }
        host.copyToPasteboard(address)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@MainActor
final class HostController: ObservableObject {
    enum Status {
        case stopped
        case starting
        case running
        case degraded
        case failed

        var title: String {
            switch self {
            case .stopped: "未启动"
            case .starting: "正在启动"
            case .running: "仅本机监听"
            case .degraded: "首页可用 · 对话未就绪"
            case .failed: "启动失败"
            }
        }

        var systemImage: String {
            switch self {
            case .stopped: "pause.circle"
            case .starting: "ellipsis.circle"
            case .running: "lock.shield"
            case .degraded: "house.badge.exclamationmark"
            case .failed: "exclamationmark.triangle"
            }
        }

        var color: Color {
            switch self {
            case .stopped: .secondary
            case .starting: .orange
            case .running: .green
            case .degraded: .orange
            case .failed: .red
            }
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var errorMessage: String?
    @Published private(set) var pairingCode: String?
    @Published private(set) var devices: [PairedDeviceRecord] = []
    @Published private(set) var tailscaleStatus = TailscaleStatus.unavailable
    @Published private(set) var chatStatus = "未连接"
    @Published private(set) var chatBusy = false
    private var server: StudyRocketHTTPServer?
    private var startupDeadline: DispatchWorkItem?
    private var terminationSources: [DispatchSourceSignal] = []
    private var rootURL: URL {
        let path = UserDefaults.standard.string(forKey: "workspaceRoot") ?? "/Users/skyfrost/Desktop/大学"
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    var isRunning: Bool { status == .running || status == .starting || status == .degraded }

    var repositoryIsValid: Bool {
        FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("AGENTS.md").path) &&
        FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("PROFILE.md").path)
    }

    var repositoryStatus: String { repositoryIsValid ? "仓库已绑定 · \(rootURL.lastPathComponent)" : "仓库未绑定或缺少档案" }
    var codexIsAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/Applications/ChatGPT.app/Contents/Resources/codex") }
    var codexStatus: String { codexIsAvailable ? "Codex 可用" : "Codex 未找到" }

    init() {
        installTerminationHandlers()
    }

    func start() {
        guard !isRunning else { return }
        status = .starting
        errorMessage = nil
        chatStatus = "正在自检"
        do {
            let server = try StudyRocketHTTPServer(port: StudyRocketAPI.defaultHostPort, root: rootURL)
            server.onChatEvent = { [weak self] event in
                Task { @MainActor in self?.receiveChatEvent(event) }
            }
            self.server = server
            pairingCode = server.generatePairingCode()
            devices = server.devices()
            armStartupDeadline(for: server)
            server.start(
                onReady: { [weak self] ready, message in
                Task { @MainActor in
                    guard let self,
                          self.server === server,
                          self.status == .starting || self.status == .degraded else { return }
                    if self.status == .starting {
                        self.startupDeadline?.cancel()
                        self.startupDeadline = nil
                    }
                    if ready {
                        self.status = .running
                        self.chatStatus = "已连接"
                        self.errorMessage = nil
                        self.refreshTailscale()
                    } else {
                        self.status = .degraded
                        self.chatStatus = "对话未就绪"
                        self.errorMessage = message ?? "Codex 协议自检失败；首页仍可用，学业对话尚未就绪。"
                        self.refreshTailscale()
                    }
                }
                },
                onFailed: { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.server === server, self.isRunning else { return }
                        let message = "Host 监听启动失败：\(error.localizedDescription)"
                        self.stop()
                        self.errorMessage = message
                        self.status = .failed
                        NSLog("StudyRocket Host listener failed: %@", error.localizedDescription)
                    }
                }
            )
            refreshTailscale()
        } catch {
            status = .failed
            errorMessage = error.localizedDescription
            NSLog("StudyRocket Host failed to start: %@", error.localizedDescription)
        }
    }

    func stop() {
        startupDeadline?.cancel()
        startupDeadline = nil
        server?.stop()
        server = nil
        pairingCode = nil
        devices = []
        chatStatus = "未连接"
        chatBusy = false
        status = .stopped
    }

    /// The Host listener may be healthy while the local Codex stdio process is
    /// wedged.  Leave the listener and authenticated plan APIs available while
    /// the server keeps retrying the chat self-check.
    private func armStartupDeadline(for expectedServer: StudyRocketHTTPServer) {
        startupDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self, weak expectedServer] in
            guard let self,
                  let expectedServer,
                  self.server === expectedServer,
                  self.status == .starting else { return }
            self.errorMessage = "Codex 自检超时（25 秒）。首页仍可用，学业对话尚未就绪；Host 会继续重试。"
            self.chatStatus = "对话未就绪"
            self.status = .degraded
            self.startupDeadline = nil
        }
        startupDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: deadline)
    }

    func refreshDevices() {
        devices = server?.devices() ?? []
        refreshTailscale()
    }

    func regeneratePairingCode() {
        guard let server else { return }
        pairingCode = server.generatePairingCode()
        devices = server.devices()
    }

    func revoke(_ id: String) {
        do {
            try server?.revokeDevice(id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshDevices()
    }

    func stopTurn() {
        server?.interruptChat()
        chatBusy = false
        chatStatus = "已停止"
    }

    func openMainApplication() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/NCU StudyRocket.app"), configuration: .init())
    }

    func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func receiveChatEvent(_ event: String) {
        guard server != nil else { return }
        switch event {
        case "chat.ready": chatStatus = "已连接"
        case "chat.started": chatBusy = true; chatStatus = "Codex 正在处理"
        case "chat.interrupted": chatBusy = false; chatStatus = "已停止"
        case "chat.completed": chatBusy = false; chatStatus = "已连接"
        case "chat.failed": chatBusy = false; chatStatus = "对话失败"
        default: break
        }
    }

    deinit { server?.stop() }

    private func installTerminationHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.stop()
                exit(0)
            }
            source.resume()
            terminationSources.append(source)
        }
    }

    func refreshTailscale() {
        let task = Task.detached(priority: .utility) { TailscaleStatus.detect() }
        Task { [weak self] in
            self?.tailscaleStatus = await task.value
        }
    }
}

struct TailscaleStatus: Equatable {
    enum State: Equatable { case unavailable, notServed, served }
    let state: State
    let address: String?

    static let unavailable = TailscaleStatus(state: .unavailable, address: nil)

    var title: String {
        switch state {
        case .unavailable: "Tailscale 未检测到"
        case .notServed: "Tailscale 已连接，未检测 Serve"
        case .served: "Tailscale Serve 地址可用"
        }
    }

    var systemImage: String {
        switch state {
        case .unavailable: "wifi.slash"
        case .notServed: "network"
        case .served: "lock.shield.fill"
        }
    }

    static func detect() -> TailscaleStatus {
        let candidates = [
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
            "/usr/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        ]
        for executable in candidates where FileManager.default.isExecutableFile(atPath: executable) {
            let output = run(executable, arguments: ["status", "--json"])
            guard let data = output.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["BackendState"] as? String == "Running",
                  let selfInfo = object["Self"] as? [String: Any],
                  let dnsName = selfInfo["DNSName"] as? String else { continue }
            let host = dnsName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !host.isEmpty else { continue }
            let serve = run(executable, arguments: ["serve", "status", "--json"])
            let served = serve.contains("https://") || serve.contains("Web")
            // The MagicDNS hostname is stable enough to enter on iPhone before
            // Serve is enabled. Keep reachability separate from discovery.
            return TailscaleStatus(state: served ? .served : .notServed, address: "https://\(host)/")
        }
        return .unavailable
    }

    private static func run(_ executable: String, arguments: [String]) -> String {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.standardOutput = pipe; process.standardError = Pipe()
        do { try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return String(data: data, encoding: .utf8) ?? "" }
        catch { return "" }
    }
}

private final class StudyRocketHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.skyfrost.ncustudyrocket.host", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let pairing = HostPairingStore()
    private let localSession = HostLocalSessionStore()
    private let localSessionToken: String
    private let codexLeaseStore: CodexLeaseStore
    private let codexLeaseLock = NSLock()
    private var codexLease: CodexLease?
    private let root: URL
    private let snapshotBuilder: HostSnapshotBuilder
    private let writeService: HostWriteService
    private let chatBridge: HostChatBridge
    private let eventHub: StudyRocketEventHub
    private let connectionLock = NSLock()
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private let maximumConnections = 32
    private var selfCheckTask: Task<Void, Never>?
    var onChatEvent: ((String) -> Void)?

    init(port: UInt16, root: URL) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
        self.root = root.standardizedFileURL
        codexLeaseStore = CodexLeaseStore()
        localSessionToken = try localSession.issue()
        let builder = HostSnapshotBuilder(root: root.standardizedFileURL)
        snapshotBuilder = builder
        eventHub = StudyRocketEventHub(snapshotProvider: { builder.build() })
        writeService = HostWriteService(root: root.standardizedFileURL)
        chatBridge = HostChatBridge(root: root.standardizedFileURL)
        chatBridge.onEvent = { [weak self] event in
            guard let self else { return }
            eventHub.publish(event: event, snapshot: snapshotBuilder.build())
            self.onChatEvent?(event)
        }
        chatBridge.onStreamEvent = { [weak self] event in
            self?.eventHub.publish(event: "chat", envelope: HostEventEnvelope(kind: "chat", chat: event))
        }
    }

    func start(onReady: @escaping (Bool, String?) -> Void, onFailed: @escaping (NWError) -> Void) {
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("StudyRocket Host listener failed: %@", error.localizedDescription)
                onFailed(error)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        selfCheckTask?.cancel()
        selfCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try self.acquireCodexLeaseIfNeeded()
                    try await self.chatBridge.selfCheck()
                    onReady(true, nil)
                    return
                } catch {
                    self.releaseCodexLease()
                    NSLog("StudyRocket Host Codex self-check retry: %@", error.localizedDescription)
                    onReady(false, error.localizedDescription)
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        selfCheckTask?.cancel()
        selfCheckTask = nil
        chatBridge.shutdown()
        eventHub.closeAll()
        listener.cancel()
        connectionLock.lock()
        let connections = activeConnections.values
        activeConnections.removeAll()
        connectionLock.unlock()
        connections.forEach { $0.cancel() }
        localSession.clear()
        releaseCodexLease()
    }

    deinit {
        localSession.clear()
        releaseCodexLease()
    }

    func generatePairingCode() -> String {
        pairing.generateCode()
    }

    func devices() -> [PairedDeviceRecord] { pairing.list() }

    func revokeDevice(_ id: String) throws { try pairing.revoke(id) }

    func interruptChat() {
        chatBridge.interrupt()
    }

    private func acquireCodexLeaseIfNeeded() throws {
        codexLeaseLock.lock()
        defer { codexLeaseLock.unlock() }
        guard codexLease == nil else { return }
        codexLease = try codexLeaseStore.acquire(owner: "StudyRocket Host")
    }

    private func releaseCodexLease() {
        codexLeaseLock.lock()
        let lease = codexLease
        codexLease = nil
        codexLeaseLock.unlock()
        lease?.release()
    }

    private func accept(_ connection: NWConnection) {
        let remote = connection.endpoint.debugDescription
        guard remote.contains("127.0.0.1") || remote.contains("::1") || remote.contains("localhost") else {
            connection.cancel()
            return
        }
        let connectionID = ObjectIdentifier(connection)
        connectionLock.lock()
        guard activeConnections.count < maximumConnections else {
            connectionLock.unlock()
            connection.cancel()
            return
        }
        activeConnections[connectionID] = connection
        connectionLock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .failed, .cancelled:
                self?.releaseConnection(connection)
                self?.eventHub.remove(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { [weak connection] in connection?.cancel() }
        queue.asyncAfter(deadline: .now() + .seconds(10), execute: deadline)
        receive(on: connection, buffer: Data(), deadline: deadline)
    }

    private func releaseConnection(_ connection: NWConnection) {
        connectionLock.lock()
        activeConnections.removeValue(forKey: ObjectIdentifier(connection))
        connectionLock.unlock()
    }

    private func receive(on connection: NWConnection, buffer: Data, deadline: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var next = buffer
            if let data { next.append(data) }
            switch HostHTTPRequestParser.parse(next) {
            case .incomplete where !isComplete && error == nil:
                self.receive(on: connection, buffer: next, deadline: deadline)
            case .complete(let request):
                deadline.cancel()
                Task {
                    let response = await self.response(for: request)
                    let keepsAlive = request.method == "GET" && request.path == "/v1/events" && response.starts(with: Data("HTTP/1.1 200".utf8))
                    connection.send(content: response, completion: .contentProcessed { error in
                        if error != nil {
                            connection.cancel()
                        } else if keepsAlive {
                            if !self.eventHub.add(connection) { connection.cancel() }
                        } else {
                            connection.cancel()
                        }
                    })
                }
            case .rejected(let status, let code, let message):
                deadline.cancel()
                let payload = (try? self.encoder.encode(APIErrorBody(code: code, message: message, retryable: false))) ?? Data("{}".utf8)
                connection.send(content: self.makeResponse(status: status, payload: payload), completion: .contentProcessed { _ in connection.cancel() })
            case .incomplete:
                deadline.cancel()
                connection.cancel()
            }
        }
    }

    private func response(for request: HostHTTPRequest) async -> Data {
        let method = request.method
        let path = request.path
        let headers = request.headers
        let body = request.body

        let payload: Data
        let status: String
        if method == "GET", path == "/v1/health" {
            let bound = FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path) && FileManager.default.fileExists(atPath: root.appendingPathComponent("PROFILE.md").path)
            let codexReady = FileManager.default.isExecutableFile(atPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
            let chatState = chatBridge.chatState
            let toolsReady = chatBridge.canGenerateChat && StudyRocketDynamicToolContract.declarationIsValid
            if isAuthorized(headers: headers, method: method, path: path, body: body) {
                let repositoryID = RequestSigning.bodyHash(Data(root.path.utf8))
                let health = HealthResponse(hostVersion: "0.1.0", repositoryBound: bound, codexReady: codexReady, pairedDeviceCount: pairing.deviceCount, activeThreadID: chatBridge.currentThreadID, repositoryID: repositoryID, dynamicToolsReady: toolsReady, chatState: chatState.rawValue, chatIssueCode: chatBridge.chatIssueCode)
                payload = (try? encoder.encode(health)) ?? Data("{}".utf8)
            } else {
                let health = PublicHealthResponse(hostVersion: "0.1.0", repositoryBound: bound, codexReady: codexReady, dynamicToolsReady: toolsReady)
                payload = (try? encoder.encode(health)) ?? Data("{}".utf8)
            }
            status = "200 OK"
        } else if method == "POST", path == "/v1/pair" {
            do {
                let request = try decoder.decode(PairRequest.self, from: body)
                payload = try encoder.encode(pairing.pair(request))
                status = "200 OK"
            } catch {
                payload = (try? encoder.encode(APIErrorBody(code: "pairing_failed", message: error.localizedDescription, retryable: false))) ?? Data("{}".utf8)
                status = "401 Unauthorized"
            }
        } else if method == "GET", path == "/v1/snapshot" {
            guard isAuthorized(headers: headers, method: method, path: path, body: body) else {
                payload = (try? encoder.encode(APIErrorBody(code: "unauthorized", message: "设备尚未配对或请求签名已失效。", retryable: false))) ?? Data("{}".utf8)
                status = "401 Unauthorized"
                return makeResponse(status: status, payload: payload)
            }
            let bound = FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path) && FileManager.default.fileExists(atPath: root.appendingPathComponent("PROFILE.md").path)
            if bound {
                payload = (try? encoder.encode(snapshotBuilder.build())) ?? Data("{}".utf8)
                status = "200 OK"
            } else {
                payload = (try? encoder.encode(APIErrorBody(code: "repository_unbound", message: "StudyRocket Host 尚未绑定有效仓库。", retryable: false))) ?? Data("{}".utf8)
                status = "503 Service Unavailable"
            }
        } else if method == "GET", path == "/v1/chat/history" {
            guard isAuthorized(headers: headers, method: method, path: path, body: body) else {
                payload = (try? encoder.encode(APIErrorBody(code: "unauthorized", message: "设备尚未配对或请求签名已失效。", retryable: false))) ?? Data("{}".utf8)
                status = "401 Unauthorized"
                return makeResponse(status: status, payload: payload)
            }
            do {
                let history = chatBridge.chatState == .authFailed ? chatBridge.history() : try await chatBridge.connectHistory()
                payload = try encoder.encode(history)
                status = "200 OK"
            } catch {
                let authFailed = StudyRocketCodexErrorPresentation.isAuthenticationFailure(error.localizedDescription)
                payload = (try? encoder.encode(APIErrorBody(code: authFailed ? "provider_auth_failed" : "codex_unavailable", message: StudyRocketCodexErrorPresentation.message(for: error.localizedDescription, fallback: "Codex 历史暂时不可用。"), retryable: !authFailed))) ?? Data("{}".utf8)
                status = "503 Service Unavailable"
            }
        } else if method == "GET", path == "/v1/events" {
            guard isAuthorized(headers: headers, method: method, path: path, body: body) else {
                payload = (try? encoder.encode(APIErrorBody(code: "unauthorized", message: "设备尚未配对或请求签名已失效。", retryable: false))) ?? Data("{}".utf8)
                status = "401 Unauthorized"
                return makeResponse(status: status, payload: payload)
            }
            let snapshot = snapshotBuilder.build()
            eventHub.remember(snapshot)
            let envelope = HostEventEnvelope(kind: "snapshot", snapshot: snapshot)
            let json = (try? encoder.encode(envelope)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            payload = Data("event: snapshot\ndata: \(json)\n\n".utf8)
            status = "200 OK"
        } else if method == "GET", path == "/v1/week" {
            guard isAuthorized(headers: headers, method: method, path: path, body: body) else {
                payload = (try? encoder.encode(APIErrorBody(code: "unauthorized", message: "设备尚未配对或请求签名已失效。", retryable: false))) ?? Data("{}".utf8)
                status = "401 Unauthorized"
                return makeResponse(status: status, payload: payload)
            }
            payload = (try? encoder.encode(snapshotBuilder.build().week)) ?? Data("{}".utf8)
            status = "200 OK"
        } else if method == "GET", path == "/v1/daily" {
            guard isAuthorized(headers: headers, method: method, path: path, body: body) else {
                payload = (try? encoder.encode(APIErrorBody(code: "unauthorized", message: "设备尚未配对或请求签名已失效。", retryable: false))) ?? Data("{}".utf8)
                status = "401 Unauthorized"
                return makeResponse(status: status, payload: payload)
            }
            payload = (try? encoder.encode(snapshotBuilder.build().daily)) ?? Data("{}".utf8)
            status = "200 OK"
        } else if method == "GET", path == "/v1/summaries" {
            guard isAuthorized(headers: headers, method: method, path: path, body: body) else {
                payload = (try? encoder.encode(APIErrorBody(code: "unauthorized", message: "设备尚未配对或请求签名已失效。", retryable: false))) ?? Data("{}".utf8)
                status = "401 Unauthorized"
                return makeResponse(status: status, payload: payload)
            }
            payload = (try? encoder.encode(snapshotBuilder.build().summaries)) ?? Data("[]".utf8)
            status = "200 OK"
        } else if method == "GET", path.hasPrefix("/v1/documents/") {
            guard isAuthorized(headers: headers, method: method, path: path, body: body) else {
                payload = (try? encoder.encode(APIErrorBody(code: "unauthorized", message: "设备尚未配对或请求签名已失效。", retryable: false))) ?? Data("{}".utf8)
                status = "401 Unauthorized"
                return makeResponse(status: status, payload: payload)
            }
            let prefix = "/v1/documents/"
            let key = String(path.dropFirst(prefix.count))
            // Accept only an exact logical key.  No URL path or filename can
            // be supplied by a phone client.
            if key.isEmpty || key.contains("/") || key.removingPercentEncoding != key || HostSnapshotBuilder.documentMap[key] == nil {
                payload = (try? encoder.encode(APIErrorBody(code: "invalid_document", message: "资料键无效。", retryable: false))) ?? Data("{}".utf8)
                status = "400 Bad Request"
            } else if let detail = snapshotBuilder.document(documentKey: key) {
                payload = (try? encoder.encode(detail)) ?? Data("{}".utf8)
                status = "200 OK"
            } else {
                payload = (try? encoder.encode(APIErrorBody(code: "document_unavailable", message: "资料缺失或内容为空。", retryable: false))) ?? Data("{}".utf8)
                status = "404 Not Found"
            }
        } else if method == "GET", path == "/v1/proposals" {
            guard isAuthorized(headers: headers, method: method, path: path, body: body) else {
                payload = (try? encoder.encode(APIErrorBody(code: "unauthorized", message: "设备尚未配对或请求签名已失效。", retryable: false))) ?? Data("{}".utf8)
                status = "401 Unauthorized"
                return makeResponse(status: status, payload: payload)
            }
            payload = (try? encoder.encode(chatBridge.proposals())) ?? Data("{}".utf8)
            status = "200 OK"
        } else if method == "GET", path == "/v1/proposals/challenge" {
            guard let deviceID = authenticatedDeviceID(headers: headers, method: method, path: path, body: body) else {
                payload = (try? encoder.encode(APIErrorBody(code: "biometric_required", message: "草案确认需要已配对设备的 Face ID 授权。", retryable: false))) ?? Data("{}".utf8)
                status = "401 Unauthorized"
                return makeResponse(status: status, payload: payload)
            }
            do {
                payload = try encoder.encode(pairing.issueAuthorizationChallenge(for: deviceID))
                status = "200 OK"
            } catch {
                payload = (try? encoder.encode(APIErrorBody(code: "authorization_unavailable", message: error.localizedDescription, retryable: false))) ?? Data("{}".utf8)
                status = "403 Forbidden"
            }
        } else if method == "POST", path == "/v1/proposals/apply" {
            let localAuthorized = headerValue("X-StudyRocket-Local-Session", in: headers) == localSessionToken
            let deviceID = localAuthorized ? nil : authenticatedDeviceID(headers: headers, method: method, path: path, body: body)
            guard localAuthorized || deviceID != nil else {
                payload = (try? encoder.encode(APIErrorBody(code: "unauthorized", message: "设备尚未配对或请求签名已失效。", retryable: false))) ?? Data("{}".utf8)
                status = "401 Unauthorized"
                return makeResponse(status: status, payload: payload)
            }
            do {
                let request = try decoder.decode(ProposalApplyRequest.self, from: body)
                if let deviceID {
                    guard pairing.consumeAuthorization(request.authorization, for: deviceID) else {
                        throw HostWriteError(code: "biometric_required", message: "请在 iPhone 上重新完成 Face ID 确认。")
                    }
                }
                guard snapshotBuilder.build().revision == request.metadata.baseRevision else { throw HostWriteError(code: "conflict", message: "仓库内容已变化，请重新生成草案。") }
                let remaining = try chatBridge.apply(request)
                let snapshot = snapshotBuilder.build()
                eventHub.publish(snapshot)
                payload = try encoder.encode(ProposalApplyResponse(remaining: remaining, revision: snapshot.revision))
                status = "200 OK"
            } catch let error as HostWriteError {
                payload = (try? encoder.encode(APIErrorBody(code: error.code, message: error.message, retryable: error.code == "conflict"))) ?? Data("{}".utf8)
                status = error.code == "conflict" ? "409 Conflict" : "422 Unprocessable Entity"
            } catch {
                payload = (try? encoder.encode(APIErrorBody(code: "invalid_request", message: error.localizedDescription, retryable: false))) ?? Data("{}".utf8)
                status = "400 Bad Request"
            }
        } else if method == "POST", path == "/v1/chat/send" {
            guard isAuthorized(headers: headers, method: method, path: path, body: body) else {
                payload = (try? encoder.encode(APIErrorBody(code: "unauthorized", message: "设备尚未配对或请求签名已失效。", retryable: false))) ?? Data("{}".utf8)
                status = "401 Unauthorized"
                return makeResponse(status: status, payload: payload)
            }
            guard chatBridge.canGenerateChat else {
                let authFailed = chatBridge.chatState == .authFailed
                payload = (try? encoder.encode(APIErrorBody(code: authFailed ? "provider_auth_failed" : "codex_starting", message: authFailed ? StudyRocketCodexErrorPresentation.authenticationFailureMessage : "StudyRocket Host 正在完成 Codex 协议自检，请稍后重试。", retryable: !authFailed))) ?? Data("{}".utf8)
                status = "503 Service Unavailable"
                return makeResponse(status: status, payload: payload)
            }
            do {
                let request = try decoder.decode(SendChatRequest.self, from: body)
                guard request.apiVersion == StudyRocketAPI.version else {
                    throw HostChatError.protocolError("客户端版本不兼容，请更新 StudyRocket。")
                }
                _ = chatBridge.send(request.text, requestID: request.clientRequestID)
                payload = (try? encoder.encode(chatBridge.history())) ?? Data("{}".utf8)
                status = "202 Accepted"
            } catch {
                payload = (try? encoder.encode(APIErrorBody(code: "invalid_request", message: error.localizedDescription, retryable: false))) ?? Data("{}".utf8)
                status = "400 Bad Request"
            }
        } else if method == "POST", path == "/v1/chat/interrupt" {
            guard isAuthorized(headers: headers, method: method, path: path, body: body) else {
                payload = (try? encoder.encode(APIErrorBody(code: "unauthorized", message: "设备尚未配对或请求签名已失效。", retryable: false))) ?? Data("{}".utf8)
                status = "401 Unauthorized"
                return makeResponse(status: status, payload: payload)
            }
            guard chatBridge.canGenerateChat else {
                let authFailed = chatBridge.chatState == .authFailed
                payload = (try? encoder.encode(APIErrorBody(code: authFailed ? "provider_auth_failed" : "codex_starting", message: authFailed ? StudyRocketCodexErrorPresentation.authenticationFailureMessage : "StudyRocket Host 正在完成 Codex 协议自检，请稍后重试。", retryable: !authFailed))) ?? Data("{}".utf8)
                status = "503 Service Unavailable"
                return makeResponse(status: status, payload: payload)
            }
            do {
                let request = try decoder.decode(InterruptRequest.self, from: body)
                guard request.apiVersion == StudyRocketAPI.version else {
                    throw HostChatError.protocolError("客户端版本不兼容，请更新 StudyRocket。")
                }
                chatBridge.interrupt()
                payload = Data("{}".utf8)
                status = "202 Accepted"
            } catch {
                payload = (try? encoder.encode(APIErrorBody(code: "invalid_request", message: error.localizedDescription, retryable: false))) ?? Data("{}".utf8)
                status = "400 Bad Request"
            }
        } else if (["POST", "PUT"].contains(method) && ["/v1/week", "/v1/deliveries/toggle", "/v1/daily"].contains(path))
                    || (method == "POST" && path == "/v1/periods/toggle") {
            guard isAuthorized(headers: headers, method: method, path: path, body: body) else {
                payload = (try? encoder.encode(APIErrorBody(code: "unauthorized", message: "设备尚未配对或请求签名已失效。", retryable: false))) ?? Data("{}".utf8)
                status = "401 Unauthorized"
                return makeResponse(status: status, payload: payload)
            }
            do {
                let snapshot: SnapshotResponse
                switch path {
                case "/v1/week": snapshot = try writeService.applyWeek(decoder.decode(PlanWriteRequest.self, from: body))
                case "/v1/deliveries/toggle": snapshot = try writeService.toggleDelivery(decoder.decode(DeliveryToggleRequest.self, from: body))
                case "/v1/periods/toggle": snapshot = try writeService.togglePeriod(decoder.decode(PeriodCompletionToggleRequest.self, from: body))
                default: snapshot = try writeService.applyDaily(decoder.decode(DailyWriteRequest.self, from: body))
                }
                eventHub.publish(snapshot)
                payload = try encoder.encode(snapshot)
                status = "200 OK"
            } catch let error as HostWriteError {
                payload = (try? encoder.encode(APIErrorBody(code: error.code, message: error.message, retryable: error.code == "conflict"))) ?? Data("{}".utf8)
                status = error.code == "conflict" ? "409 Conflict" : "422 Unprocessable Entity"
            } catch {
                payload = (try? encoder.encode(APIErrorBody(code: "invalid_request", message: error.localizedDescription, retryable: false))) ?? Data("{}".utf8)
                status = "400 Bad Request"
            }
        } else {
            let body = APIErrorBody(code: "host_bootstrap", message: "StudyRocket Host 已启动，业务接口尚未配对。", retryable: true)
            payload = (try? encoder.encode(body)) ?? Data("{}".utf8)
            status = "503 Service Unavailable"
        }

        let isEventStream = method == "GET" && path == "/v1/events" && status == "200 OK"
        return makeResponse(status: status, payload: payload, contentType: isEventStream ? "text/event-stream" : "application/json; charset=utf-8", keepAlive: isEventStream)
    }

    private func makeResponse(status: String, payload: Data, contentType: String = "application/json; charset=utf-8", keepAlive: Bool = false) -> Data {
        var headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Connection: \(keepAlive ? "keep-alive" : "close")",
            "Cache-Control: no-store"
        ]
        if keepAlive {
            headers.append("Transfer-Encoding: chunked")
            let frame = Self.chunk(payload)
            return Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8) + frame
        }
        headers.append("Content-Length: \(payload.count)")
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8) + payload
    }

    private static func chunk(_ payload: Data) -> Data {
        Data("\(String(payload.count, radix: 16))\r\n".utf8) + payload + Data("\r\n".utf8)
    }

    private func authentication(from headers: String) -> RequestAuthentication? {
        func value(_ name: String) -> String? {
            headers.components(separatedBy: "\r\n").dropFirst().first { $0.lowercased().hasPrefix(name.lowercased() + ":") }?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        }
        guard let deviceID = value("X-StudyRocket-Device"),
              let timestamp = value("X-StudyRocket-Timestamp").flatMap(Int64.init),
              let nonce = value("X-StudyRocket-Nonce"),
              let signature = value("X-StudyRocket-Signature") else { return nil }
        return RequestAuthentication(deviceID: deviceID, timestamp: timestamp, nonce: nonce, signature: signature)
    }

    private func isAuthorized(headers: String, method: String, path: String, body: Data) -> Bool {
        if let local = headerValue("X-StudyRocket-Local-Session", in: headers), local == localSessionToken {
            return true
        }
        return authenticatedDeviceID(headers: headers, method: method, path: path, body: body) != nil
    }

    private func authenticatedDeviceID(headers: String, method: String, path: String, body: Data) -> String? {
        guard let authentication = authentication(from: headers) else { return nil }
        return pairing.verifyAndIdentify(authentication, method: method, path: path, body: body)
    }

    private func headerValue(_ name: String, in headers: String) -> String? {
        headers.components(separatedBy: "\r\n").dropFirst()
            .first { $0.lowercased().hasPrefix(name.lowercased() + ":") }?
            .split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespaces)
    }
}

private final class StudyRocketEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let heartbeatTimer: DispatchSourceTimer
    private let snapshotProvider: (() -> SnapshotResponse)?
    private var lastSnapshotRevision: String?

    init(snapshotProvider: (() -> SnapshotResponse)? = nil) {
        self.snapshotProvider = snapshotProvider
        heartbeatTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        heartbeatTimer.schedule(deadline: .now() + .seconds(20), repeating: .seconds(20))
        heartbeatTimer.setEventHandler { [weak self] in self?.publishHeartbeat() }
        heartbeatTimer.resume()
    }

    @discardableResult
    func add(_ connection: NWConnection) -> Bool {
        let id = ObjectIdentifier(connection)
        lock.lock()
        guard connections.count < 16 else { lock.unlock(); return false }
        connections[id] = connection
        lock.unlock()
        return true
    }

    func publish(_ snapshot: SnapshotResponse) {
        publish(event: "snapshot", snapshot: snapshot)
    }

    func publish(event: String, snapshot: SnapshotResponse) {
        remember(snapshot)
        publish(event: event, envelope: HostEventEnvelope(kind: event, snapshot: snapshot))
    }

    func remember(_ snapshot: SnapshotResponse) {
        lock.lock()
        lastSnapshotRevision = snapshot.revision
        lock.unlock()
    }

    func publish(event: String, envelope: HostEventEnvelope) {
        guard let data = try? JSONEncoder().encode(envelope), let json = String(data: data, encoding: .utf8) else { return }
        let payload = Self.chunk(Data("event: \(event)\ndata: \(json)\n\n".utf8))
        lock.lock(); let current = connections; lock.unlock()
        for connection in current.values {
            connection.send(content: payload, completion: .contentProcessed { [weak self, weak connection] error in
                if error != nil, let connection { self?.remove(connection); connection.cancel() }
            })
        }
    }

    private func publishHeartbeat() {
        if let snapshotProvider {
            let snapshot = snapshotProvider()
            lock.lock()
            let changed = lastSnapshotRevision != snapshot.revision
            lastSnapshotRevision = snapshot.revision
            lock.unlock()
            if changed {
                publish(event: "snapshot", envelope: HostEventEnvelope(kind: "snapshot", snapshot: snapshot))
                return
            }
        }
        publish(event: "heartbeat", envelope: HostEventEnvelope(kind: "heartbeat"))
    }

    func closeAll() {
        lock.lock(); let current = connections; connections.removeAll(); lock.unlock()
        current.values.forEach { $0.cancel() }
        heartbeatTimer.cancel()
    }

    deinit { heartbeatTimer.cancel() }

    func remove(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.lock(); connections.removeValue(forKey: id); lock.unlock()
    }

    private static func chunk(_ payload: Data) -> Data {
        Data("\(String(payload.count, radix: 16))\r\n".utf8) + payload + Data("\r\n".utf8)
    }
}

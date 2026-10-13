import Darwin
import Foundation

struct TailscaleStatus: Equatable {
    enum State: Equatable { case unavailable, notServed, served }
    let state: State
    let address: String?

    static let unavailable = TailscaleStatus(state: .unavailable, address: nil)

    var title: String {
        switch state {
        case .unavailable: "Tailscale 未检测到"
        case .notServed: "Tailscale 已连接，未检测到 Host Serve"
        case .served: "Tailscale Serve 地址已配置"
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
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
            "/usr/bin/tailscale"
        ]
        for executable in candidates where FileManager.default.isExecutableFile(atPath: executable) {
            guard let status = run(executable, arguments: ["status", "--json"]),
                  parse(status: status, serve: Data()).state != .unavailable else { continue }
            let serve = run(executable, arguments: ["serve", "status", "--json"]) ?? Data()
            return parse(status: status, serve: serve)
        }
        return .unavailable
    }

    static func parse(status: Data, serve: Data) -> TailscaleStatus {
        guard let object = try? JSONSerialization.jsonObject(with: status) as? [String: Any],
              object["BackendState"] as? String == "Running",
              let selfInfo = object["Self"] as? [String: Any],
              let dnsName = selfInfo["DNSName"] as? String else { return .unavailable }
        let host = dnsName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let url = URL(string: "https://\(host)/"), url.host == host,
              !host.isEmpty, url.user == nil, url.port == nil else { return .unavailable }
        let discovered = TailscaleStatus(state: .notServed, address: url.absoluteString)
        guard let config = try? JSONSerialization.jsonObject(with: serve) as? [String: Any],
              let tcp = config["TCP"] as? [String: [String: Any]],
              let web = config["Web"] as? [String: [String: Any]] else { return discovered }
        // A Web entry alone may serve a different app or plain HTTP. Advertise
        // only HTTPS whose root handler forwards to this Host's loopback port.
        for port in tcp.keys.sorted(by: { ($0 == "443" ? "" : $0) < ($1 == "443" ? "" : $1) }) {
            guard let number = Int(port), (1...65535).contains(number),
                  tcp[port]?["HTTPS"] as? Bool == true,
                  let handlers = web["\(host):\(port)"]?["Handlers"] as? [String: [String: Any]],
                  let proxy = handlers["/"]?["Proxy"] as? String,
                  let backend = URLComponents(string: proxy),
                  backend.scheme == "http",
                  ["127.0.0.1", "localhost", "::1", "[::1]"].contains(backend.host ?? ""),
                  backend.port == 43817, backend.user == nil, backend.password == nil,
                  backend.path.isEmpty || backend.path == "/",
                  backend.query == nil, backend.fragment == nil else { continue }
            return TailscaleStatus(state: .served, address: "https://\(host)\(number == 443 ? "" : ":\(number)")/")
        }
        return discovered
    }

    /// Use a private file rather than a pipe so a large CLI response cannot
    /// block the child. A stalled daemon must not leave refresh stuck forever.
    static func run(_ executable: String, arguments: [String], timeout: TimeInterval = 3) -> Data? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("studyrocket-tailscale-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent("output")
            guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            let finished = DispatchSemaphore(value: 0)
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            guard finished.wait(timeout: .now() + timeout) == .success else {
                if process.isRunning { process.terminate() }
                if finished.wait(timeout: .now() + 0.25) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            return try Data(contentsOf: output)
        } catch { return nil }
    }
}

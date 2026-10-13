import Foundation

@main
struct HostConnectionDiscoveryChecks {
    static func main() throws {
        let status = Data(#"{"BackendState":"Running","Self":{"DNSName":"mac.example.ts.net."}}"#.utf8)
        func serve(port: Int = 443, https: Bool = true, proxy: String = "http://127.0.0.1:43817") throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "TCP": [String(port): ["HTTPS": https]],
                "Web": ["mac.example.ts.net:\(port)": ["Handlers": ["/": ["Proxy": proxy]]]]
            ])
        }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: message, code: 1) }
        }
        try require(TailscaleStatus.parse(status: status, serve: try serve()).address == "https://mac.example.ts.net/", "default HTTPS address")
        try require(TailscaleStatus.parse(status: status, serve: try serve()).state == .served, "root Host proxy")
        try require(TailscaleStatus.parse(status: status, serve: try serve(port: 8443)).address == "https://mac.example.ts.net:8443/", "nondefault HTTPS port")
        for data in [Data(), Data(#"{"Web":{}}"#.utf8), try serve(https: false), try serve(proxy: "http://127.0.0.1:9999"), try serve(proxy: "http://remote.example:43817"), try serve(proxy: "http://127.0.0.1:43817/other")] {
            try require(TailscaleStatus.parse(status: status, serve: data).state == .notServed, "reject incomplete or unrelated Serve")
        }
        try require(TailscaleStatus.parse(status: Data(#"{"BackendState":"Stopped"}"#.utf8), serve: try serve()) == .unavailable, "disconnected daemon")
        try require(TailscaleStatus.parse(status: Data(#"{"BackendState":"Running","Self":{"DNSName":""}}"#.utf8), serve: try serve()) == .unavailable, "missing DNS name")
        let start = Date()
        try require(TailscaleStatus.run("/bin/sleep", arguments: ["10"], timeout: 0.1) == nil, "CLI timeout")
        try require(Date().timeIntervalSince(start) < 2, "refresh deadline")
        try require(TailscaleStatus.run("/usr/bin/false", arguments: []) == nil, "failed CLI exit")
        let modern = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        let legacy = "/Applications/ChatGPT.app/Contents/Resources/codex"
        try require(StudyRocketCodexExecutable.resolve(isExecutable: { $0 == modern || $0 == legacy }) == modern, "modern bundled executable")
        try require(StudyRocketCodexExecutable.resolve(isExecutable: { $0 == legacy }) == legacy, "legacy bundled executable")
        try require(StudyRocketCodexExecutable.resolve(isExecutable: { _ in false }) == nil, "missing executable")
        print("HostConnectionDiscoveryChecks: HTTPS discovery, timeout and Codex layout checks passed")
    }
}

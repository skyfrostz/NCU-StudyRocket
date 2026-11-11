import Foundation
import StudyRocketShared

/// Local control-plane client used only while the optional StudyRocket Host is running.
/// The main app keeps its existing stdio client as a fallback when no Host token exists.
actor StudyRocketHostClient {
    private var endpoint: URL
    private let localEndpoint: URL
    private let session: URLSession
    private var cloudBinding: DesktopCloudBinding?
    private var cloudRequired = false
    private var lastEventID: String?
    private let tokenURL: URL

    init(
        configuration: StudyRocketSelfCheckConfiguration? = StudyRocketSelfCheckConfiguration.current,
        endpoint: URL? = nil,
        session: URLSession = .shared,
        tokenURL: URL? = nil
    ) {
        self.endpoint = endpoint
            ?? URL(string: "http://127.0.0.1:\(configuration?.port ?? StudyRocketAPI.defaultHostPort)")!
        self.localEndpoint = self.endpoint
        self.session = session
        self.tokenURL = tokenURL ?? configuration?.localSessionURL ?? StudyRocketLocalSession.tokenURL()
    }

    func configureCloud(for root: URL) -> Bool {
        let previousBinding = cloudBinding
        let previousRequired = cloudRequired
        cloudRequired = DesktopCloudBinding.isManaged(root)
        let next = try? DesktopCloudBinding.read(root)
        if next != cloudBinding { lastEventID = nil }
        cloudBinding = next
        endpoint = next?.endpoint ?? localEndpoint
        return previousBinding != cloudBinding || previousRequired != cloudRequired
    }

    func isAvailable(for root: URL? = nil) async -> Bool {
        guard cloudBinding != nil || !cloudRequired && readToken() != nil else { return false }
        do {
            let health = try await health(for: root)
            guard health.repositoryBound, health.codexReady, health.dynamicToolsReady != false else { return false }
            if let cloudBinding { return health.repositoryID == cloudBinding.repositoryID }
            if let root {
                let expected = RequestSigning.bodyHash(Data(root.standardizedFileURL.path.utf8))
                return health.repositoryID == expected
            }
            return true
        } catch {
            return false
        }
    }

    func health(for root: URL? = nil) async throws -> HealthResponse {
        let health = try await get("/v1/health", as: HealthResponse.self)
        if let cloudBinding {
            guard health.repositoryID == cloudBinding.repositoryID else { throw LocalHostError.server("云仓库身份发生变化，请重新配对。") }
        } else if let root {
            let expected = RequestSigning.bodyHash(Data(root.standardizedFileURL.path.utf8))
            guard health.repositoryID == expected else { throw LocalHostError.server("StudyRocket Host 绑定了其他仓库。") }
        }
        return health
    }

    func waitUntilAvailable(for root: URL? = nil) async -> Bool {
        guard cloudBinding != nil || !cloudRequired && readToken() != nil else { return false }
        for _ in 0..<20 {
            if await isAvailable(for: root) { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    func history() async throws -> ChatHistoryResponse {
        let history: ChatHistoryResponse = try await get("/v1/chat/history", as: ChatHistoryResponse.self)
        if let cloudBinding {
            let terminalIDs = Set((history.terminalTurns ?? []).filter { ["completed", "failed", "interrupted"].contains($0.status) }.map(\.turnID))
            let prefix = "studyrocket.cloud.pending-chat." + cloudBinding.repositoryID + "."
            for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix(prefix) && !key.hasSuffix(".text") {
                if let id = value as? String, terminalIDs.contains(id) {
                    UserDefaults.standard.removeObject(forKey: key); UserDefaults.standard.removeObject(forKey: key + ".text")
                }
            }
        }
        return history
    }

    func events() -> AsyncThrowingStream<HostEventEnvelope, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: endpoint.appendingPathComponent("/v1/events"))
                    request.httpMethod = "GET"
                    request.timeoutInterval = 90
                    try authenticate(&request)
                    if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw LocalHostError.server("StudyRocket Host 实时事件连接失败。")
                    }
                    var candidateEventID = lastEventID
                    for try await line in bytes.lines {
                        if line.hasPrefix("id: ") { candidateEventID = String(line.dropFirst(4)); continue }
                        guard line.hasPrefix("data: ") else { continue }
                        let data = Data(line.dropFirst(6).utf8)
                        if let event = try? JSONDecoder().decode(HostEventEnvelope.self, from: data) {
                            continuation.yield(event)
                            lastEventID = candidateEventID
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func snapshot() async throws -> SnapshotResponse {
        try await get("/v1/snapshot", as: SnapshotResponse.self)
    }

    func pendingCloudDraft() -> String? {
        guard let cloudBinding else { return nil }
        let prefix = "studyrocket.cloud.pending-chat." + cloudBinding.repositoryID + "."
        return UserDefaults.standard.dictionaryRepresentation().keys.sorted()
            .first(where: { $0.hasPrefix(prefix) && $0.hasSuffix(".text") })
            .flatMap { UserDefaults.standard.string(forKey: $0) }
    }

    func send(_ text: String) async throws {
        var requestID = UUID().uuidString
        var persistedKey: String?
        if let cloudBinding {
            let key = "studyrocket.cloud.pending-chat." + cloudBinding.repositoryID + "." + RequestSigning.bodyHash(Data(text.utf8))
            persistedKey = key
            requestID = UserDefaults.standard.string(forKey: key) ?? requestID
            // Kept until a successful history acknowledgement, so uncertain retries
            // survive restart and retain the same server idempotency key.
            UserDefaults.standard.set(requestID, forKey: key)
            UserDefaults.standard.set(text, forKey: key + ".text")
        }
        _ = try await post("/v1/chat/send", body: SendChatRequest(text: text, clientRequestID: requestID), as: ChatHistoryResponse.self)
        if let persistedKey { UserDefaults.standard.removeObject(forKey: persistedKey); UserDefaults.standard.removeObject(forKey: persistedKey + ".text") }
    }

    func interrupt() async throws {
        _ = try await post("/v1/chat/interrupt", body: InterruptRequest(turnID: ""), as: EmptyResponse.self)
    }

    func proposals() async throws -> ProposalListResponse {
        try await get("/v1/proposals", as: ProposalListResponse.self)
    }

    func applyProposals(ids: [String], baseRevision: String) async throws -> ProposalApplyResponse {
        let authorization: String
        if let cloudBinding { authorization = try await DesktopCloudAPI(endpoint: cloudBinding.endpoint).authorizeProposals() }
        else { guard !cloudRequired else { throw LocalHostError.unavailable }; authorization = readToken() ?? "local" }
        let request = ProposalApplyRequest(
            proposalIDs: ids,
            authorization: authorization,
            metadata: WriteMetadata(baseRevision: baseRevision)
        )
        return try await post("/v1/proposals/apply", body: request, as: ProposalApplyResponse.self)
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = "GET"
        return try await execute(request, as: type)
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body, as type: Response.Type) async throws -> Response {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await execute(request, as: type)
    }

    private func execute<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        var request = request
        try authenticate(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalHostError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let body = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
                throw LocalHostError.server(body.message)
            }
            throw LocalHostError.server("StudyRocket Host 返回 HTTP \(http.statusCode)。")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private func authenticate(_ request: inout URLRequest) throws {
        if let cloudBinding { try DesktopCloudIdentity().authenticate(&request, endpoint: cloudBinding.endpoint); return }
        guard !cloudRequired, let token = readToken() else { throw LocalHostError.unavailable }
        request.setValue(token, forHTTPHeaderField: "X-StudyRocket-Local-Session")
    }

    private func readToken() -> String? {
        guard let data = try? Data(contentsOf: tokenURL),
              let token = String(data: data, encoding: .utf8) else { return nil }
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private struct EmptyResponse: Decodable {}

enum LocalHostError: LocalizedError {
    case unavailable
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "StudyRocket Host 未启动。"
        case .invalidResponse: return "StudyRocket Host 返回了无效响应。"
        case .server(let message): return message
        }
    }
}

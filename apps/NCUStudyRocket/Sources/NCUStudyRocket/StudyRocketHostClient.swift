import Foundation
import StudyRocketShared

/// Local control-plane client used only while the optional StudyRocket Host is running.
/// The main app keeps its existing stdio client as a fallback when no Host token exists.
actor StudyRocketHostClient {
    private let endpoint: URL
    private let session: URLSession
    private let tokenURL: URL

    init(endpoint: URL = URL(string: "http://127.0.0.1:\(StudyRocketAPI.defaultHostPort)")!, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
        tokenURL = StudyRocketLocalSession.tokenURL()
    }

    func isAvailable(for root: URL? = nil) async -> Bool {
        guard readToken() != nil else { return false }
        do {
            let health = try await health(for: root)
            guard health.repositoryBound, health.codexReady, health.dynamicToolsReady != false else { return false }
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
        if let root {
            let expected = RequestSigning.bodyHash(Data(root.standardizedFileURL.path.utf8))
            guard health.repositoryID == expected else { throw LocalHostError.server("StudyRocket Host 绑定了其他仓库。") }
        }
        return health
    }

    func waitUntilAvailable(for root: URL? = nil) async -> Bool {
        guard readToken() != nil else { return false }
        for _ in 0..<20 {
            if await isAvailable(for: root) { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    func history() async throws -> ChatHistoryResponse {
        try await get("/v1/chat/history", as: ChatHistoryResponse.self)
    }

    func events() -> AsyncThrowingStream<HostEventEnvelope, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: endpoint.appendingPathComponent("/v1/events"))
                    request.httpMethod = "GET"
                    request.timeoutInterval = 90
                    guard let token = readToken() else { throw LocalHostError.unavailable }
                    request.setValue(token, forHTTPHeaderField: "X-StudyRocket-Local-Session")
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw LocalHostError.server("StudyRocket Host 实时事件连接失败。")
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let data = Data(line.dropFirst(6).utf8)
                        if let event = try? JSONDecoder().decode(HostEventEnvelope.self, from: data) {
                            continuation.yield(event)
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

    func send(_ text: String) async throws {
        _ = try await post("/v1/chat/send", body: SendChatRequest(text: text), as: ChatHistoryResponse.self)
    }

    func interrupt() async throws {
        _ = try await post("/v1/chat/interrupt", body: InterruptRequest(turnID: ""), as: EmptyResponse.self)
    }

    func proposals() async throws -> ProposalListResponse {
        try await get("/v1/proposals", as: ProposalListResponse.self)
    }

    func applyProposals(ids: [String], baseRevision: String) async throws -> ProposalApplyResponse {
        let request = ProposalApplyRequest(
            proposalIDs: ids,
            authorization: readToken() ?? "local",
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
        guard let token = readToken() else { throw LocalHostError.unavailable }
        request.setValue(token, forHTTPHeaderField: "X-StudyRocket-Local-Session")
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

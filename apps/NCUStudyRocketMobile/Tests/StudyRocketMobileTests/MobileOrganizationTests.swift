import Foundation
import XCTest
import StudyRocketShared
@testable import StudyRocketMobile

private final class OrganizationURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fixture: OrganizationFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.fixture!.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.fixture!.status(for: request), httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class OrganizationFixture: @unchecked Sendable {
    let lock = NSLock()
    var chats: [SendChatRequest] = []
    var writes: [ProposalApplyRequest] = []
    var terminal = true
    var offersProposals = true
    var dropApplyReceipt = false
    var operationAvailable = true
    var operationMissing = false
    var dropBeforeCommitOnce = false
    var revision = "r0"
    var proposalIDs: [String] = []
    func respond(_ request: URLRequest) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        switch request.url!.path {
        case "/v1/health": return try encoder.encode(HealthResponse(hostVersion: "test", repositoryBound: true, codexReady: true, pairedDeviceCount: 1, activeThreadID: "academic", repositoryID: "organize-test", dynamicToolsReady: true, backend: "cloud"))
        case "/v1/snapshot": return try encoder.encode(snapshot())
        case "/v1/chat/send":
            chats.append(try JSONDecoder().decode(SendChatRequest.self, from: Self.body(request)))
            return try encoder.encode(history())
        case "/v1/chat/history": return try encoder.encode(history())
        case "/v1/proposals": return try encoder.encode(ProposalListResponse(proposals: proposals()))
        case "/v1/proposals/challenge": return try encoder.encode(ProposalAuthorizationChallenge(challenge: "fixture-only", expiresAt: .now.addingTimeInterval(30)))
        case "/v1/proposals/apply":
            let write = try JSONDecoder().decode(ProposalApplyRequest.self, from: Self.body(request))
            writes.append(write)
            if dropBeforeCommitOnce { dropBeforeCommitOnce = false; operationMissing = true; throw URLError(.networkConnectionLost) }
            operationMissing = false; revision = "r1"
            if dropApplyReceipt { throw URLError(.networkConnectionLost) }
            return try encoder.encode(ProposalApplyResponse(remaining: .init(proposals: []), revision: revision))
        default:
            if request.url!.path.hasPrefix("/v1/operations/"), operationMissing {
                return try encoder.encode(APIErrorBody(code: "operation_not_found", message: "not found", retryable: false))
            }
            if request.url!.path.hasPrefix("/v1/operations/"), let write = writes.last, operationAvailable {
                return try encoder.encode(CloudOperationStatus(id: write.metadata.idempotencyKey, state: "succeeded", revision: "r1"))
            }
            throw URLError(.notConnectedToInternet)
        }
    }
    func status(for request: URLRequest) -> Int {
        lock.lock(); defer { lock.unlock() }
        return request.url!.path.hasPrefix("/v1/operations/") && operationMissing ? 404 : 200
    }
    func snapshot() -> SnapshotResponse {
        SnapshotResponse(revision: revision, home: HomeSnapshot(dateLabel: "2026-11-14", periods: [], firstOpenTask: nil, visibleDeliveries: [], completedDeliveries: 0, totalDeliveries: 0), week: .init(days: [], bufferRules: [], deliveries: []), daily: .init(date: "2026-11-14"), summaries: [])
    }
    func history() -> ChatHistoryResponse {
        let messages = chats.flatMap { chat -> [ChatMessageDTO] in
            let id = chat.clientRequestID
            return [.init(id: "u-" + id, role: "user", text: chat.text, date: .now, turnID: id, status: terminal ? "completed" : "inProgress"), .init(id: "a-" + id, role: "assistant", text: "请确认这个关联", date: .now, turnID: id, status: terminal ? "completed" : "inProgress")]
        }
        return .init(revision: revision, messages: messages, terminalTurns: terminal ? chats.map { .init(turnID: $0.clientRequestID, status: "completed") } : [])
    }
    func proposals() -> [ProposalDTO] {
        guard offersProposals, revision != "r1" else { return [] }
        return chats.map { chat in
            .init(id: "p-" + chat.clientRequestID, turnID: chat.clientRequestID, relativePath: "工作台/下周计划.md", originalContent: "fixture", proposedContent: "fixture", reason: "fixture", baseHash: "hash", kind: "markdown")
        } + [.init(id: "unrelated", turnID: "old-turn", relativePath: "工作台/下周计划.md", originalContent: "old", proposedContent: "other", reason: "unrelated", baseHash: "old", kind: "markdown")]
    }
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return data
    }
}

@MainActor final class MobileOrganizationTests: XCTestCase {
    private func session(_ fixture: OrganizationFixture, directory: URL, endpoint: String = "https://organization.test") -> MobileSession {
        OrganizationURLProtocol.fixture = fixture
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OrganizationURLProtocol.self]
        return MobileSession(cacheDirectory: directory, client: StudyRocketRemoteClient(endpoint: URL(string: endpoint)!, session: URLSession(configuration: config)), eventStreamsEnabled: false, chatRecoveryDelays: [.seconds(60)])
    }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OrganizationTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testDirectSendPreservesComposerCoalescesAndReopensLatestRoundOnly() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = OrganizationFixture(), app = session(OrganizationFixture(), directory: dir)
        OrganizationURLProtocol.fixture = fixture
        await app.refresh()
        app.inputDraft = "尚未发送的原草稿"
        await app.startOrganization()
        await app.startOrganization()
        await app.refreshChat(); await app.refreshProposals(); await app.refreshOrganization()
        XCTAssertEqual(fixture.chats.count, 1)
        XCTAssertEqual(app.inputDraft, "尚未发送的原草稿")
        XCTAssertEqual(app.organizationProposals.map(\.turnID), [fixture.chats[0].clientRequestID])
        app.setOrganizationClarification("只关联科研交付物")
        await app.sendOrganizationClarification()
        await app.refreshChat(); await app.refreshProposals(); await app.refreshOrganization()
        XCTAssertEqual(fixture.chats.count, 2)
        XCTAssertEqual(app.organizationProposals.count, 1)
        XCTAssertEqual(app.organizationProposals.first?.turnID, fixture.chats.last?.clientRequestID)
        let restored = session(fixture, directory: dir)
        await restored.refresh(); await restored.refreshChat(); await restored.refreshProposals(); await restored.refreshOrganization()
        XCTAssertEqual(restored.currentOrganization?.rounds.count, 2)
        XCTAssertEqual(restored.organizationProposals.first?.turnID, fixture.chats.last?.clientRequestID)
        XCTAssertEqual(restored.inputDraft, "尚未发送的原草稿")
        app.leaveForeground(); restored.leaveForeground()
    }
    func testUnfinishedRoundHasNoConfirmationAndSurvivesRelaunch() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = OrganizationFixture(); fixture.terminal = false
        let app = session(fixture, directory: dir); await app.refresh(); await app.startOrganization(); await app.refreshProposals()
        XCTAssertTrue(app.organizationProposals.isEmpty)
        await app.confirmOrganization(); XCTAssertTrue(fixture.writes.isEmpty)
        app.leaveForeground()
        let restored = session(fixture, directory: dir); await restored.refresh(); await restored.refreshOrganization()
        await restored.startOrganization()
        XCTAssertEqual(fixture.chats.count, 1)
        XCTAssertEqual(restored.currentOrganization?.phase, .requesting)
        restored.leaveForeground()
    }
    func testLostApplyReceiptReconcilesSavedKeyAfterRelaunchWithoutSecondPost() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = OrganizationFixture(); fixture.dropApplyReceipt = true; fixture.operationAvailable = false
        let app = session(fixture, directory: dir); await app.refresh(); await app.startOrganization(); await app.refreshChat(); await app.refreshProposals(); await app.refreshOrganization()
        await app.confirmOrganization()
        XCTAssertEqual(app.currentOrganization?.phase, .receiptUnknown)
        let write = try XCTUnwrap(fixture.writes.first)
        XCTAssertEqual(write.metadata.baseRevision, "r0")
        XCTAssertEqual(write.proposalIDs, ["p-" + fixture.chats[0].clientRequestID])
        await app.confirmOrganization(); XCTAssertEqual(fixture.writes.count, 1)
        app.leaveForeground()
        fixture.operationAvailable = true
        let restored = session(fixture, directory: dir); await restored.refresh(); await restored.refreshOrganization()
        XCTAssertEqual(restored.currentOrganization?.phase, .applied)
        XCTAssertEqual(fixture.writes.count, 1)
        XCTAssertEqual(restored.snapshot?.revision, "r1")
        restored.leaveForeground()
    }
    func testPreviewRevisionConflictBlocksWriteAndKeepsClarification() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = OrganizationFixture(), app = session(OrganizationFixture(), directory: dir); OrganizationURLProtocol.fixture = fixture
        await app.refresh(); await app.startOrganization(); await app.refreshChat(); await app.refreshProposals(); await app.refreshOrganization()
        XCTAssertEqual(app.currentOrganization?.previewRevision, "r0")
        fixture.revision = "r-new"; await app.refresh()
        await app.confirmOrganization()
        XCTAssertTrue(fixture.writes.isEmpty)
        XCTAssertTrue(app.currentOrganization?.issue?.contains("变化") == true)
        XCTAssertEqual(app.currentOrganization?.previewRevision, "r0")
        app.leaveForeground()
    }
    func testPendingWeekDraftBlocksOrganizationAndEndpointIsolation() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = OrganizationFixture(), app = session(OrganizationFixture(), directory: dir); OrganizationURLProtocol.fixture = fixture
        await app.refresh(); await app.startOrganization(); app.leaveForeground()
        let other = session(fixture, directory: dir, endpoint: "https://other.test")
        await other.refresh(); await other.refreshOrganization()
        XCTAssertNil(other.currentOrganization)
        other.leaveForeground()
        _ = await other.saveWeek(fixture.snapshot().week)
        await other.startOrganization()
        XCTAssertEqual(fixture.chats.count, 1)
        XCTAssertNotNil(other.pendingWeekDraft)
    }
    func testKnownAbsentOperationReplaysExactIntentWithOriginalKey() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = OrganizationFixture(); fixture.dropBeforeCommitOnce = true
        let app = session(fixture, directory: dir)
        await app.refresh(); await app.startOrganization(); await app.refreshChat(); await app.refreshProposals(); await app.refreshOrganization()
        await app.confirmOrganization()
        XCTAssertEqual(app.currentOrganization?.phase, .ready)
        XCTAssertEqual(app.proposalApplyOutcome, .retryAvailable)
        await app.confirmOrganization()
        XCTAssertEqual(app.currentOrganization?.phase, .applied)
        XCTAssertEqual(fixture.writes.count, 2)
        XCTAssertEqual(fixture.writes[0].metadata.idempotencyKey, fixture.writes[1].metadata.idempotencyKey)
        XCTAssertEqual(fixture.writes[0].metadata.baseRevision, fixture.writes[1].metadata.baseRevision)
        XCTAssertEqual(fixture.writes[0].proposalIDs, fixture.writes[1].proposalIDs)
        app.leaveForeground()
    }
    func testInterruptedAuthorizationReopensAsConfirmableWithoutWriting() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = OrganizationFixture(), app = session(OrganizationFixture(), directory: dir); OrganizationURLProtocol.fixture = fixture
        await app.refresh(); await app.startOrganization(); await app.refreshChat(); await app.refreshProposals(); await app.refreshOrganization()
        var workflow = try XCTUnwrap(app.currentOrganization)
        workflow.phase = .applying
        let scope = PeriodCompletion.textHash(for: workflow.endpoint.absoluteString + "|" + workflow.repositoryID)
        try JSONEncoder().encode(workflow).write(to: dir.appendingPathComponent("organization-\(scope).json"), options: .atomic)
        app.leaveForeground()
        let restored = session(fixture, directory: dir); await restored.refresh(); await restored.refreshOrganization()
        XCTAssertEqual(restored.currentOrganization?.phase, .ready)
        XCTAssertTrue(fixture.writes.isEmpty)
        restored.leaveForeground()
    }
    func testConcurrentConfirmCoalescesToOneWrite() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = OrganizationFixture(), app = session(OrganizationFixture(), directory: dir); OrganizationURLProtocol.fixture = fixture
        await app.refresh(); await app.startOrganization(); await app.refreshChat(); await app.refreshProposals(); await app.refreshOrganization()
        async let first: Void = app.confirmOrganization()
        async let second: Void = app.confirmOrganization()
        _ = await (first, second)
        XCTAssertEqual(fixture.writes.count, 1)
        XCTAssertEqual(app.currentOrganization?.phase, .applied)
        app.leaveForeground()
    }
    func testPreservationValidatorRejectsTaskRenameAndScheduleChange() throws {
        let week = WeeklyPlanSnapshot(days: [DaySnapshot(id: "2026-11-14", dateLabel: "2026-11-14", slots: [PeriodSnapshot(id: "morning", title: "上午", text: "原文 10:00 写作业")])], bufferRules: [], deliveries: [])
        let graph = TaskLinkage(activationDate: "2026-11-14").reconciled(with: week)
        let original = try TaskLinkageMarkdown.write(graph, in: "fixture")
        var changed = graph; changed.tasks[0].text = "改写任务"
        func proposal(_ graph: TaskLinkage) throws -> ProposalDTO {
            .init(id: "p", turnID: "t", relativePath: "工作台/下周计划.md", originalContent: original, proposedContent: try TaskLinkageMarkdown.write(graph, in: "fixture"), reason: "test", baseHash: "hash", kind: "markdown")
        }
        XCTAssertThrowsError(try MobileOrganizationValidation.validate([proposal(changed)]))
        changed = graph; changed.assignments[0].periodID = "evening"
        XCTAssertThrowsError(try MobileOrganizationValidation.validate([proposal(changed)]))
        XCTAssertNoThrow(try MobileOrganizationValidation.validate([proposal(graph)]))
    }
}

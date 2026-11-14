import Foundation
import XCTest
@testable import StudyRocketMobile
import StudyRocketShared

private final class MobileLifecycleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private struct MobileStubResponse {
    let statusCode: Int
    let data: Data
    var deliveryGate: MobileStubDeliveryGate? = nil
}

private final class MobileStubDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveries: [@Sendable () -> Void] = []
    private var isOpen = false

    func enqueue(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        if isOpen { lock.unlock(); action() }
        else { deliveries.append(action); lock.unlock() }
    }

    func release() {
        lock.lock()
        isOpen = true
        let actions = deliveries
        deliveries.removeAll()
        lock.unlock()
        actions.forEach { $0() }
    }
}

private final class MobileStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> MobileStubResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let stub = try handler(request)
            let deliver: @Sendable () -> Void = { [self] in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: stub.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: stub.data)
                client?.urlProtocolDidFinishLoading(self)
            }
            if let gate = stub.deliveryGate { gate.enqueue(deliver) }
            else { deliver() }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class MobileSyncFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var authoritative: SnapshotResponse
    private var forcedDeliveryError: APIErrorBody?
    private var dropDeliveryResponseAfterApply: Bool
    private var documents: [String: DocumentDetail]
    private var codexReady: Bool
    private var facts = [QuickFact]()
    private var dropFactReceipt = true
    var legacyRepositoryID: String?
    private(set) var dailyRequests: [DailyWriteRequest] = []
    private(set) var factRequests: [FactWriteRequest] = []
    private(set) var migratedDeliveryRequests: [DeliveryToggleRequest] = []
    func setReady(_ value: Bool) { lock.lock(); defer { lock.unlock() }; codexReady = value }
    private let repositoryBound: Bool
    private var healthReads = 0
    private var snapshotReads = 0
    private var chatHistoryReads = 0
    private var totalChatHistoryReads = 0
    var totalChatHistoryReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalChatHistoryReads
    }
    private var forcedChatHistory: ChatHistoryResponse?
    func setChatHistory(_ value: ChatHistoryResponse) {
        lock.lock(); defer { lock.unlock() }
        forcedChatHistory = value
    }
    private var acceptedChatText: String?
    private var acceptedChatID: String?
    private var chatCompletionAfterHistoryReads: Int?
    private let chatTerminalIssue: APIErrorBody?
    private let chatSendCancellation: Bool
    private var firstChatRejection: APIErrorBody?
    private let chatTurnIDOverride: String?
    private let cloudBackend: Bool
    private let firstChatReceiptGate: MobileStubDeliveryGate?
    private var recordedChatRequests: [SendChatRequest] = []
    var chatRequests: [SendChatRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedChatRequests
    }
    func setChatCompletionRead(_ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        chatCompletionAfterHistoryReads = value
    }
    private(set) var writePaths: [String] = []
    private(set) var baseRevisions: [String] = []
    private(set) var deliveryTargets: [Bool] = []
    private(set) var linkedPeriodRequests: [PeriodCompletionToggleRequest] = []

    init(
        snapshot: SnapshotResponse,
        codexReady: Bool = true,
        repositoryBound: Bool = true,
        forcedDeliveryError: APIErrorBody? = nil,
        dropDeliveryResponseAfterApply: Bool = false,
        documents: [String: DocumentDetail] = [:],
        chatCompletionAfterHistoryReads: Int? = nil,
        chatTerminalIssue: APIErrorBody? = nil,
        chatSendCancellation: Bool = false,
        firstChatRejection: APIErrorBody? = nil,
        chatTurnIDOverride: String? = nil,
        cloudBackend: Bool = false,
        firstChatReceiptGate: MobileStubDeliveryGate? = nil
    ) {
        authoritative = snapshot
        self.codexReady = codexReady
        self.repositoryBound = repositoryBound
        self.forcedDeliveryError = forcedDeliveryError
        self.dropDeliveryResponseAfterApply = dropDeliveryResponseAfterApply
        self.documents = documents
        self.chatCompletionAfterHistoryReads = chatCompletionAfterHistoryReads
        self.chatTerminalIssue = chatTerminalIssue
        self.chatSendCancellation = chatSendCancellation
        self.firstChatRejection = firstChatRejection
        self.chatTurnIDOverride = chatTurnIDOverride
        self.cloudBackend = cloudBackend
        self.firstChatReceiptGate = firstChatReceiptGate
    }

    var snapshot: SnapshotResponse {
        lock.lock()
        defer { lock.unlock() }
        return authoritative
    }

    var readCounts: (health: Int, snapshot: Int, chatHistory: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (healthReads, snapshotReads, chatHistoryReads)
    }

    func response(for request: URLRequest) throws -> MobileStubResponse {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        let path = request.url?.path ?? ""
        switch (request.httpMethod ?? "GET", path) {
        case ("GET", "/v1/health"):
            healthReads += 1
            return MobileStubResponse(statusCode: 200, data: try encoder.encode(HealthResponse(
                hostVersion: "test",
                repositoryBound: repositoryBound,
                codexReady: codexReady,
                pairedDeviceCount: 1,
                activeThreadID: "academic",
                repositoryID: "repo-test",
                dynamicToolsReady: codexReady, backend: cloudBackend || legacyRepositoryID != nil ? "cloud" : nil, legacyRepositoryID: legacyRepositoryID
            )))
        case ("GET", "/v1/snapshot"):
            snapshotReads += 1
            return MobileStubResponse(statusCode: 200, data: try encoder.encode(authoritative))
        case ("GET", "/v1/proposals"):
            return MobileStubResponse(statusCode: 200, data: try encoder.encode(ProposalListResponse(proposals: [])))
        case ("POST", "/v1/facts"):
            let write = try JSONDecoder().decode(FactWriteRequest.self, from: Self.bodyData(for: request))
            factRequests.append(write)
            guard write.repositoryID == "repo-test", UUID(uuidString: write.metadata.idempotencyKey) == write.entry.id else { throw URLError(.badServerResponse) }
            if !facts.contains(write.entry) { facts.append(write.entry) }
            record(path: path, revision: write.metadata.baseRevision)
            if dropFactReceipt { dropFactReceipt = false; throw URLError(.networkConnectionLost) }
            authoritative = SnapshotResponse(revision: "facts", home: authoritative.home, week: authoritative.week, daily: authoritative.daily, summaries: [], recentFacts: facts)
            return MobileStubResponse(statusCode: 200, data: try encoder.encode(authoritative))
        case ("POST", "/v1/daily"):
            let write = try JSONDecoder().decode(DailyWriteRequest.self, from: Self.bodyData(for: request))
            dailyRequests.append(write)
            guard write.metadata.baseRevision == authoritative.revision else {
                return MobileStubResponse(statusCode: 409, data: try encoder.encode(APIErrorBody(code: "conflict", message: "daily revision changed")))
            }
            authoritative = SnapshotResponse(revision: "daily-saved", home: authoritative.home, week: authoritative.week, daily: write.entry, summaries: [])
            return MobileStubResponse(statusCode: 200, data: try encoder.encode(authoritative))
        case ("POST", "/v1/week"):
            let value = try JSONDecoder().decode(PlanWriteRequest.self, from: Self.bodyData(for: request))
            record(path: path, revision: value.metadata.baseRevision)
            guard value.metadata.baseRevision == authoritative.revision else {
                return MobileStubResponse(
                    statusCode: 409,
                    data: try encoder.encode(APIErrorBody(code: "conflict", message: "revision conflict", retryable: true))
                )
            }
            authoritative = Self.rebuild(
                authoritative,
                days: value.plan.days,
                historicalRows: value.plan.historicalRows,
                futureRows: value.plan.futureRows
            )
            return MobileStubResponse(statusCode: 200, data: try encoder.encode(authoritative))
        case ("POST", "/v1/chat/send"):
            guard chatCompletionAfterHistoryReads != nil else {
                return MobileStubResponse(statusCode: 404, data: try encoder.encode(APIErrorBody(code: "not_found", message: path)))
            }
            let send = try JSONDecoder().decode(SendChatRequest.self, from: Self.bodyData(for: request))
            recordedChatRequests.append(send)
            if let rejection = firstChatRejection {
                firstChatRejection = nil
                return MobileStubResponse(statusCode: 409, data: try encoder.encode(rejection))
            }
            acceptedChatText = send.text
            acceptedChatID = chatTurnIDOverride ?? send.clientRequestID
            chatHistoryReads = 0
            if chatSendCancellation { throw URLError(.cancelled) }
            return MobileStubResponse(statusCode: 202, data: try encoder.encode(ChatHistoryResponse(revision: "0", messages: [])),
                deliveryGate: recordedChatRequests.count == 1 ? firstChatReceiptGate : nil)
        case ("GET", "/v1/chat/history"):
            totalChatHistoryReads += 1
            if let forcedChatHistory {
                return MobileStubResponse(statusCode: 200, data: try encoder.encode(forcedChatHistory))
            }
            guard let text = acceptedChatText, let turnID = acceptedChatID, let completionRead = chatCompletionAfterHistoryReads else {
                return MobileStubResponse(statusCode: 200, data: try encoder.encode(ChatHistoryResponse(revision: "0", messages: [])))
            }
            chatHistoryReads += 1
            let isComplete = chatHistoryReads >= completionRead
            let date = Date(timeIntervalSinceReferenceDate: 123_456)
            let status = isComplete ? (chatTerminalIssue == nil ? "completed" : "failed") : "inProgress"
            var messages = [ChatMessageDTO(id: turnID + "/user", role: "user", text: text, date: date, turnID: turnID, status: status)]
            if isComplete {
                messages.append(ChatMessageDTO(id: turnID + "/assistant", role: "assistant", text: chatTerminalIssue?.message ?? "已恢复的回复", date: date.addingTimeInterval(1), turnID: turnID, phase: "final_answer", status: status))
            }
            let terminals = isComplete ? [ChatTurnTerminalDTO(turnID: turnID, status: status, issueCode: chatTerminalIssue?.code, message: chatTerminalIssue?.message)] : []
            return MobileStubResponse(statusCode: 200, data: try encoder.encode(ChatHistoryResponse(revision: "\(chatHistoryReads)", messages: messages, terminalTurns: terminals)))
        case ("GET", let path) where path.hasPrefix("/v1/documents/"):
            let key = String(path.dropFirst("/v1/documents/".count))
            guard let document = documents[key] else {
                return MobileStubResponse(
                    statusCode: 404,
                    data: try encoder.encode(APIErrorBody(code: "not_found", message: path))
                )
            }
            return MobileStubResponse(statusCode: 200, data: try encoder.encode(document))
        case ("POST", "/v1/deliveries/toggle"):
            if let error = forcedDeliveryError {
                forcedDeliveryError = nil
                return MobileStubResponse(statusCode: error.code == "conflict" ? 409 : 422, data: try encoder.encode(error))
            }
            let value = try JSONDecoder().decode(DeliveryToggleRequest.self, from: Self.bodyData(for: request))
            migratedDeliveryRequests.append(value)
            record(path: path, revision: value.metadata.baseRevision)
            deliveryTargets.append(value.isCompleted)
            guard value.metadata.baseRevision == authoritative.revision else {
                return MobileStubResponse(
                    statusCode: 409,
                    data: try encoder.encode(APIErrorBody(code: "conflict", message: "revision conflict", retryable: true))
                )
            }
            if var graph = authoritative.week.linkage, let id = value.deliveryID {
                try graph.setDelivery(id, completed: value.isCompleted, confirmedTaskIDs: value.confirmedTaskIDs)
                authoritative = Self.withPlan(graph.projected(authoritative.week), source: authoritative)
                if dropDeliveryResponseAfterApply { dropDeliveryResponseAfterApply = false; throw URLError(.timedOut) }
                return MobileStubResponse(statusCode: 200, data: try encoder.encode(authoritative))
            }
            let deliveries = authoritative.week.deliveries.map {
                DeliverySnapshot(
                    id: $0.id,
                    text: $0.text,
                    isCompleted: $0.text == value.text ? value.isCompleted : $0.isCompleted,
                    dateLabel: $0.dateLabel
                )
            }
            authoritative = Self.rebuild(authoritative, deliveries: deliveries)
            if dropDeliveryResponseAfterApply {
                dropDeliveryResponseAfterApply = false
                throw URLError(.timedOut)
            }
            return MobileStubResponse(statusCode: 200, data: try encoder.encode(authoritative))
        case ("POST", "/v1/periods/toggle"):
            let value = try JSONDecoder().decode(PeriodCompletionToggleRequest.self, from: Self.bodyData(for: request))
            record(path: path, revision: value.metadata.baseRevision)
            guard value.metadata.baseRevision == authoritative.revision else {
                return MobileStubResponse(
                    statusCode: 409,
                    data: try encoder.encode(APIErrorBody(code: "conflict", message: "revision conflict", retryable: true))
                )
            }
            guard let taskID = value.taskID else {
                return MobileStubResponse(
                    statusCode: 422,
                    data: try encoder.encode(APIErrorBody(code: "period_upgrade_required", message: "task id required"))
                )
            }
            if var graph = authoritative.week.linkage, let id = value.logicalTaskID {
                guard graph.assignments.contains(where: { $0.id == value.assignmentID && $0.taskID == id }) else { throw TaskLinkageError.changed }
                linkedPeriodRequests.append(value)
                try graph.setTask(id, completed: value.isCompleted)
                authoritative = Self.withPlan(graph.projected(authoritative.week), source: authoritative)
                return MobileStubResponse(statusCode: 200, data: try encoder.encode(authoritative))
            }
            let days = authoritative.week.days.map { day in
                guard day.id == value.dayID else { return day }
                let slots = Self.updatedSlots(day.slots, periodID: value.periodID, taskID: taskID, isCompleted: value.isCompleted)
                return DaySnapshot(id: day.id, dateLabel: day.dateLabel, slots: slots, unassigned: day.unassigned)
            }
            let historicalRows = authoritative.week.historicalRows.map { row in
                ScheduledRowSnapshot(
                    id: row.id,
                    dateLabel: row.dateLabel,
                    slots: Self.updatedSlots(row.slots, periodID: value.periodID, taskID: taskID, isCompleted: value.isCompleted),
                    unassigned: row.unassigned,
                    isCompleted: row.isCompleted
                )
            }
            let futureRows = authoritative.week.futureRows.map { row in
                ScheduledRowSnapshot(
                    id: row.id,
                    dateLabel: row.dateLabel,
                    slots: Self.updatedSlots(row.slots, periodID: value.periodID, taskID: taskID, isCompleted: value.isCompleted),
                    unassigned: row.unassigned,
                    isCompleted: row.isCompleted
                )
            }
            authoritative = Self.rebuild(
                authoritative,
                days: days,
                historicalRows: historicalRows,
                futureRows: futureRows
            )
            return MobileStubResponse(statusCode: 200, data: try encoder.encode(authoritative))
        default:
            return MobileStubResponse(
                statusCode: 404,
                data: try encoder.encode(APIErrorBody(code: "not_found", message: path))
            )
        }
    }

    private func record(path: String, revision: String) {
        writePaths.append(path)
        baseRevisions.append(revision)
    }

    private static func bodyData(for request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func rebuild(
        _ source: SnapshotResponse,
        deliveries: [DeliverySnapshot]? = nil,
        days: [DaySnapshot]? = nil,
        historicalRows: [ScheduledRowSnapshot]? = nil,
        futureRows: [ScheduledRowSnapshot]? = nil
    ) -> SnapshotResponse {
        let deliveries = deliveries ?? source.week.deliveries
        let days = days ?? source.week.days
        let historicalRows = historicalRows ?? source.week.historicalRows
        let futureRows = futureRows ?? source.week.futureRows
        let nextNumber = Int(source.revision.dropFirst()) ?? 0
        let revision = "r\(nextNumber + 1)"
        let periods = days.first?.slots ?? source.home.periods
        return SnapshotResponse(
            revision: revision,
            home: HomeSnapshot(
                dateLabel: source.home.dateLabel,
                periods: periods,
                firstOpenTask: periods.lazy.flatMap(\.tasks).first(where: { !$0.isCompleted })?.text,
                visibleDeliveries: deliveries,
                completedDeliveries: deliveries.filter(\.isCompleted).count,
                totalDeliveries: deliveries.count,
                timetable: source.home.timetable
            ),
            week: WeeklyPlanSnapshot(
                days: days,
                bufferRules: source.week.bufferRules,
                deliveries: deliveries,
                historicalRows: historicalRows,
                futureRows: futureRows
            ),
            daily: source.daily,
            summaries: source.summaries
        )
    }

    static func withPlan(_ plan: WeeklyPlanSnapshot, source: SnapshotResponse) -> SnapshotResponse {
        SnapshotResponse(revision: "r" + String((Int(source.revision.dropFirst()) ?? 0) + 1), home: source.home, week: plan,
            daily: source.daily, summaries: source.summaries)
    }

    private static func updatedSlots(
        _ slots: [PeriodSnapshot],
        periodID: String,
        taskID: String,
        isCompleted: Bool
    ) -> [PeriodSnapshot] {
        slots.map { period in
            guard period.id == periodID,
                  period.tasks.contains(where: { $0.id == taskID }) else { return period }
            let tasks = period.tasks.map { task in
                PeriodTaskSnapshot(
                    id: task.id,
                    text: task.text,
                    isCompleted: task.id == taskID ? isCompleted : task.isCompleted
                )
            }
            return PeriodSnapshot(id: period.id, title: period.title, text: period.text, tasks: tasks)
        }
    }
}

@MainActor
final class MobileSessionSyncTests: XCTestCase {
    func testEndpointRequiresHTTPSUnlessExplicitSimulatorLoopbackFixture() {
        XCTAssertTrue(MobileEndpointError.accepts(URL(string: "https://macbook-pro-1.tailnet.ts.net/")!))
        XCTAssertFalse(MobileEndpointError.accepts(URL(string: "http://localhost:43817/")!, allowSimulatorLoopbackHTTP: false))
        XCTAssertTrue(MobileEndpointError.accepts(URL(string: "http://localhost:43817/")!, allowSimulatorLoopbackHTTP: true))
        XCTAssertFalse(MobileEndpointError.accepts(URL(string: "http://127.0.0.1:43817/")!, allowSimulatorLoopbackHTTP: true))
        XCTAssertFalse(MobileEndpointError.accepts(URL(string: "http://localhost:43818/")!, allowSimulatorLoopbackHTTP: true))
        XCTAssertTrue(MobileEndpointError.accepts(
            URL(string: "http://localhost:43818/")!,
            allowSimulatorLoopbackHTTP: false,
            selfCheckSimulatorLoopbackPort: 43818
        ))
        XCTAssertTrue(MobileEndpointError.accepts(
            URL(string: "http://localhost:44000/")!,
            allowSimulatorLoopbackHTTP: false,
            selfCheckSimulatorLoopbackPort: 44000
        ))
        XCTAssertFalse(MobileEndpointError.accepts(
            URL(string: "http://localhost:43817/")!,
            allowSimulatorLoopbackHTTP: false,
            selfCheckSimulatorLoopbackPort: 43818
        ))
        XCTAssertFalse(MobileEndpointError.accepts(
            URL(string: "http://127.0.0.1:43818/")!,
            allowSimulatorLoopbackHTTP: false,
            selfCheckSimulatorLoopbackPort: 43818
        ))
    }

    func testSelfCheckLoopbackPortRequiresExplicitIsolatedSimulatorConfiguration() {
        XCTAssertEqual(
            MobileEndpointError.selfCheckLoopbackPort(
                arguments: ["--studyrocket-self-check", "--self-check-port", "43818"],
                isSelfCheckRuntime: true
            ),
            43818
        )
        XCTAssertEqual(
            MobileEndpointError.selfCheckLoopbackPort(
                arguments: ["--studyrocket-self-check", "--self-check-port", "44000"],
                isSelfCheckRuntime: true
            ),
            44000
        )
        XCTAssertNil(MobileEndpointError.selfCheckLoopbackPort(
            arguments: ["--studyrocket-self-check", "--self-check-port", "43818"],
            isSelfCheckRuntime: false
        ))
        XCTAssertNil(MobileEndpointError.selfCheckLoopbackPort(
            arguments: ["--self-check-port", "43818"],
            isSelfCheckRuntime: true
        ))
        XCTAssertNil(MobileEndpointError.selfCheckLoopbackPort(
            arguments: ["--studyrocket-self-check", "--self-check-port", "43817"],
            isSelfCheckRuntime: true
        ))
        XCTAssertNil(MobileEndpointError.selfCheckLoopbackPort(
            arguments: ["--studyrocket-self-check", "--self-check-port", "0"],
            isSelfCheckRuntime: true
        ))
        XCTAssertNil(MobileEndpointError.selfCheckLoopbackPort(
            arguments: ["--studyrocket-self-check", "--self-check-port", "1"],
            isSelfCheckRuntime: true
        ))
        XCTAssertNil(MobileEndpointError.selfCheckLoopbackPort(
            arguments: ["--studyrocket-self-check", "--self-check-port", "43818", "--self-check-port", "44000"],
            isSelfCheckRuntime: true
        ))
    }

    override func tearDown() {
        MobileStubURLProtocol.handler = nil
        super.tearDown()
    }

    func testEmptyPlanDatesRespectUnassignedCompletedAndOfflineQueuedTasks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeDrafts(directory: directory, legacy: false, deliveryTexts: [], periodIDs: ["morning"], includeDaily: false)
        let session = makeSession(directory: directory, fixture: MobileSyncFixture(snapshot: makeSnapshot()))
        let blank = PeriodSnapshot(id: "morning", title: "上午", text: "")
        func day(_ id: String, slot: PeriodSnapshot, unassigned: String = "") -> DaySnapshot {
            DaySnapshot(id: id, dateLabel: id, slots: [slot], unassigned: unassigned)
        }
        XCTAssertFalse(session.isEmptyPlanDay(day("2026-08-19", slot: blank)))
        XCTAssertTrue(session.isEmptyPlanDay(day("2026-08-20", slot: blank)))
        XCTAssertFalse(session.isEmptyPlanDay(day("2026-08-20", slot: blank, unassigned: "待分时事项")))
        let done = PeriodSnapshot(id: "morning", title: "上午", text: "完成例题", isCompleted: true)
        XCTAssertFalse(session.isEmptyPlanDay(day("2026-08-20", slot: done)))
    }

    func testLegacyTwoOfFiveQueueWaitsForReviewThenReplaysSequentially() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeDrafts(directory: directory, legacy: true)
        let fixture = MobileSyncFixture(snapshot: makeSnapshot())
        let session = makeSession(directory: directory, fixture: fixture)

        await session.refresh()

        XCTAssertEqual(session.state, .online)
        XCTAssertEqual(session.legacyPendingToggleCount, 5)
        XCTAssertEqual(session.legacyPendingReview?.items.count, 5)
        XCTAssertEqual(session.legacyPendingReview?.selectableIDs.count, 5)
        XCTAssertTrue(fixture.writePaths.isEmpty, "legacy operations must not write before review")
        XCTAssertNotNil(session.pendingDailyDraft)

        session.deferLegacyPendingReview()
        XCTAssertNil(session.legacyPendingReview)
        XCTAssertEqual(session.legacyPendingToggleCount, 5)
        session.presentLegacyPendingReview()
        let selected = try XCTUnwrap(session.legacyPendingReview).selectableIDs
        await session.applyLegacyPendingReview(selectedIDs: selected)

        XCTAssertEqual(fixture.writePaths, [
            "/v1/deliveries/toggle",
            "/v1/deliveries/toggle",
            "/v1/deliveries/toggle",
            "/v1/periods/toggle",
            "/v1/periods/toggle"
        ])
        XCTAssertEqual(fixture.baseRevisions, ["r0", "r1", "r2", "r3", "r4"])
        XCTAssertEqual(session.pendingDeliveryCount, 0)
        XCTAssertEqual(session.pendingPeriodCount, 0)
        XCTAssertEqual(session.legacyPendingToggleCount, 0)
        XCTAssertEqual(session.snapshot?.revision, "r5")
        XCTAssertTrue(session.snapshot?.week.deliveries.allSatisfy(\.isCompleted) == true)
        XCTAssertTrue(session.snapshot?.week.days.first?.slots.prefix(2).allSatisfy(\.isCompleted) == true)
        XCTAssertNotNil(session.pendingDailyDraft, "daily draft remains manual")
    }

    func testKeyedQueueAutomaticallyReplaysAfterSuccessfulRefresh() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeDrafts(directory: directory, legacy: false, deliveryTexts: ["交付物 3"], periodIDs: ["morning"], includeDaily: false)
        let fixture = MobileSyncFixture(snapshot: makeSnapshot())
        let session = makeSession(directory: directory, fixture: fixture)

        await session.refresh()

        XCTAssertEqual(fixture.writePaths, ["/v1/deliveries/toggle", "/v1/periods/toggle"])
        XCTAssertEqual(fixture.baseRevisions, ["r0", "r1"])
        XCTAssertEqual(session.pendingDeliveryCount, 0)
        XCTAssertEqual(session.pendingPeriodCount, 0)
        XCTAssertFalse(session.isReplayingPendingToggles)
        XCTAssertNil(session.pendingToggleSyncIssue)
    }

    func testKeyedHistoricalPeriodToggleMatchesDateLabelAndDoesNotBlockFollowingQueue() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let historicalTask = PeriodTaskSnapshot(id: "historical-task", text: "历史任务", isCompleted: true)
        let historicalRows = [ScheduledRowSnapshot(
            id: "opaque-scheduled-row-id",
            dateLabel: "9 月 14 日",
            slots: [
                PeriodSnapshot(id: "morning", title: "上午", text: "历史任务", tasks: [historicalTask]),
                PeriodSnapshot(id: "noon", title: "中午", text: ""),
                PeriodSnapshot(id: "evening", title: "晚上", text: "")
            ]
        )]
        let currentTask = PeriodTaskSnapshot(id: "current-task", text: "当前任务", isCompleted: true)
        let currentPeriods = [
            PeriodSnapshot(id: "morning", title: "上午", text: "当前任务", tasks: [currentTask]),
            PeriodSnapshot(id: "noon", title: "中午", text: ""),
            PeriodSnapshot(id: "evening", title: "晚上", text: "")
        ]
        let initial = makeSnapshot(periods: currentPeriods)
        let snapshot = SnapshotResponse(
            revision: initial.revision,
            fetchedAt: initial.fetchedAt,
            home: initial.home,
            week: WeeklyPlanSnapshot(
                days: initial.week.days,
                bufferRules: initial.week.bufferRules,
                deliveries: initial.week.deliveries,
                historicalRows: historicalRows
            ),
            daily: initial.daily,
            summaries: initial.summaries
        )
        let payload: [String: Any] = [
            "deliveries": [],
            "periods": [
                [
                    "dayID": "2026-09-14",
                    "periodID": "morning",
                    "taskID": "historical-task",
                    "isCompleted": false,
                    "idempotencyKey": "historical-key"
                ],
                [
                    "dayID": "2026-08-19",
                    "periodID": "morning",
                    "taskID": "current-task",
                    "isCompleted": true,
                    "idempotencyKey": "current-key"
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("pending-drafts.json"), options: .atomic)
        let fixture = MobileSyncFixture(snapshot: snapshot)
        let session = makeSession(directory: directory, fixture: fixture)

        await session.refresh()

        XCTAssertEqual(fixture.writePaths, ["/v1/periods/toggle"])
        XCTAssertEqual(fixture.baseRevisions, ["r0"])
        XCTAssertEqual(session.pendingPeriodCount, 0)
        XCTAssertFalse(session.snapshot?.week.historicalRows.first?.slots.first?.tasks.first?.isCompleted ?? true)
        XCTAssertTrue(session.snapshot?.week.days.first?.slots.first?.tasks.first?.isCompleted ?? false)
        XCTAssertNil(session.pendingToggleSyncIssue)
    }

    func testTaskToggleUpdatesOnlyTheRequestedChildTask() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let periods = [
            PeriodSnapshot(id: "morning", title: "上午", text: "08:00 复习高数\n10:00 整理错题"),
            PeriodSnapshot(id: "noon", title: "中午", text: ""),
            PeriodSnapshot(id: "evening", title: "晚上", text: "")
        ]
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(periods: periods))
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()

        let day = try XCTUnwrap(session.snapshot?.week.days.first)
        let morning = try XCTUnwrap(day.slots.first(where: { $0.id == "morning" }))
        let first = morning.tasks[0]
        let second = morning.tasks[1]
        await session.toggleTask(dayID: day.id, period: morning, task: first, isCompleted: true)

        let updated = try XCTUnwrap(session.snapshot?.week.days.first?.slots.first(where: { $0.id == "morning" }))
        XCTAssertTrue(updated.tasks.first(where: { $0.id == first.id })?.isCompleted == true)
        XCTAssertFalse(updated.tasks.first(where: { $0.id == second.id })?.isCompleted ?? true)
        XCTAssertFalse(updated.isCompleted)
        XCTAssertEqual(fixture.writePaths, ["/v1/periods/toggle"])
    }

    func testLegacyMultiTaskPeriodStaysInReviewAndNeverAutoReplays() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let periods = [
            PeriodSnapshot(id: "morning", title: "上午", text: "08:00 复习高数\n10:00 整理错题"),
            PeriodSnapshot(id: "noon", title: "中午", text: ""),
            PeriodSnapshot(id: "evening", title: "晚上", text: "")
        ]
        let snapshot = makeSnapshot(periods: periods)
        let morning = try XCTUnwrap(snapshot.week.days.first?.slots.first(where: { $0.id == "morning" }))
        let payload: [String: Any] = [
            "deliveries": [],
            "periods": [[
                "dayID": "2026-08-19",
                "periodID": "morning",
                "textHash": PeriodCompletion.textHash(for: morning.text),
                "isCompleted": true,
                "idempotencyKey": "old-whole-period-key"
            ]]
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("pending-drafts.json"), options: .atomic)

        let fixture = MobileSyncFixture(snapshot: snapshot)
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()

        XCTAssertEqual(session.legacyPendingToggleCount, 1)
        let item = try XCTUnwrap(session.legacyPendingReview?.items.first)
        XCTAssertFalse(item.canSync)
        XCTAssertEqual(item.detail, "旧版操作指向多个任务，请在首页逐项确认。")
        XCTAssertTrue(fixture.writePaths.isEmpty)
    }

    func testUnmatchedLegacyItemsAreDisabledAndUnselectedItemsAreRemoved() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeDrafts(
            directory: directory,
            legacy: true,
            deliveryTexts: ["交付物 3", "已经改名的交付物"],
            periodIDs: [],
            includeDaily: true
        )
        let fixture = MobileSyncFixture(snapshot: makeSnapshot())
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()
        let review = try XCTUnwrap(session.legacyPendingReview)

        XCTAssertEqual(review.items.count, 2)
        XCTAssertEqual(review.items.filter(\.canSync).count, 1)
        XCTAssertEqual(review.items.filter { !$0.canSync }.first?.detail, "任务已变化，无法自动同步")
        await session.applyLegacyPendingReview(selectedIDs: review.selectableIDs)

        XCTAssertEqual(fixture.writePaths, ["/v1/deliveries/toggle"])
        XCTAssertEqual(session.legacyPendingToggleCount, 0)
        XCTAssertEqual(session.pendingDeliveryCount, 0)
        XCTAssertNotNil(session.pendingDailyDraft)
    }

    func testDiscardingLegacyQueuePreservesDailyDraftAndDoesNotWrite() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeDrafts(directory: directory, legacy: true)
        let fixture = MobileSyncFixture(snapshot: makeSnapshot())
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()

        session.discardLegacyPendingToggles()

        XCTAssertEqual(session.pendingDeliveryCount, 0)
        XCTAssertEqual(session.pendingPeriodCount, 0)
        XCTAssertEqual(session.legacyPendingToggleCount, 0)
        XCTAssertNotNil(session.pendingDailyDraft)
        XCTAssertTrue(fixture.writePaths.isEmpty)
    }

    func testHostWithoutCodexStillLoadsPlanAndKeepsChatUnavailable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), codexReady: false)
        let session = makeSession(directory: directory, fixture: fixture)

        await session.refresh()

        XCTAssertEqual(session.state, .online)
        XCTAssertEqual(session.snapshot?.revision, "r0")
        XCTAssertFalse(session.isChatAvailable)
        XCTAssertTrue(fixture.writePaths.isEmpty)
    }

    func testUnboundRepositoryStillRejectsConnection() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), repositoryBound: false)
        let session = makeSession(directory: directory, fixture: fixture)

        await session.refresh()

        XCTAssertNotEqual(session.state, .online)
        XCTAssertEqual(fixture.readCounts.snapshot, 0)
        XCTAssertTrue(fixture.writePaths.isEmpty)
    }

    func testForegroundColdStartCoalescesAndKeepsCachedSnapshotWhileChecking() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cached = makeSnapshot()
        try JSONEncoder().encode(cached).write(to: directory.appendingPathComponent("snapshot.json"))
        let fixture = MobileSyncFixture(snapshot: cached)
        let session = makeSession(directory: directory, fixture: fixture)
        let gate = MobileStubDeliveryGate()
        MobileStubURLProtocol.handler = { request in
            let response = try fixture.response(for: request)
            return MobileStubResponse(statusCode: response.statusCode, data: response.data,
                deliveryGate: request.url?.path == "/v1/health" ? gate : nil)
        }
        let first = Task { await session.enterForeground() }
        for _ in 0..<50 where fixture.readCounts.health == 0 { try await Task.sleep(for: .milliseconds(2)) }
        let duplicate = Task { await session.enterForeground() }
        XCTAssertEqual(session.state, .connecting)
        XCTAssertEqual(session.snapshot?.revision, cached.revision)
        gate.release()
        await first.value; await duplicate.value
        XCTAssertEqual(fixture.readCounts.health, 1)
        XCTAssertEqual(fixture.readCounts.snapshot, 1)
        XCTAssertEqual(session.state, .online)
        session.leaveForeground()
    }

    func testBackgroundRejectsLateHealthAndDoesNotStartSnapshotOrSSE() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot())
        let session = makeSession(directory: directory, fixture: fixture, eventStreamsEnabled: true)
        let gate = MobileStubDeliveryGate()
        MobileStubURLProtocol.handler = { request in
            let response = try fixture.response(for: request)
            return MobileStubResponse(statusCode: response.statusCode, data: response.data, deliveryGate: gate)
        }
        let refresh = Task { await session.enterForeground() }
        for _ in 0..<50 where fixture.readCounts.health == 0 { try await Task.sleep(for: .milliseconds(2)) }
        session.leaveForeground()
        gate.release()
        await refresh.value
        XCTAssertNil(session.snapshot)
        XCTAssertEqual(fixture.readCounts.snapshot, 0)
        XCTAssertFalse(session.isEventStreamRunning)
        session.startEventStream()
        XCTAssertFalse(session.isEventStreamRunning)
        MobileStubURLProtocol.handler = fixture.response
        await session.enterForeground()
        XCTAssertEqual(session.state, .online)
        session.leaveForeground()
    }

    func testTransientRetryIsBoundedAndNetworkRecoveryOnlyProbes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot())
        let session = makeSession(directory: directory, fixture: fixture)
        session.connectionRetryDelays = [.milliseconds(5), .milliseconds(5), .milliseconds(5)]
        let requests = MobileLifecycleCounter()
        MobileStubURLProtocol.handler = { _ in requests.increment(); throw URLError(.notConnectedToInternet) }
        await session.refresh()
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(requests.value, 4)
        session.networkPathChanged(isAvailable: false)
        session.networkPathChanged(isAvailable: true)
        XCTAssertNotEqual(session.state, .online)
        MobileStubURLProtocol.handler = fixture.response
        for _ in 0..<50 where session.state != .online { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(session.state, .online)
        XCTAssertEqual(fixture.readCounts.snapshot, 1)
        session.leaveForeground()
    }

    func testBackgroundWinsOverQueuedForegroundAndCancelsRetry() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot())
        let session = makeSession(directory: directory, fixture: fixture)
        session.foregroundDidChange(isActive: true)
        session.foregroundDidChange(isActive: false)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(fixture.readCounts.health, 0)
        session.connectionRetryDelays = [.milliseconds(10)]
        let requests = MobileLifecycleCounter()
        MobileStubURLProtocol.handler = { _ in requests.increment(); throw URLError(.timedOut) }
        await session.enterForeground()
        session.leaveForeground()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(requests.value, 1)
        XCTAssertFalse(session.isEventStreamRunning)
    }

    func testReplacementEndpointRejectsOldRefreshResponse() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot())
        let session = makeSession(directory: directory, fixture: fixture)
        let gate = MobileStubDeliveryGate()
        MobileStubURLProtocol.handler = { request in
            let response = try fixture.response(for: request)
            return MobileStubResponse(statusCode: response.statusCode, data: response.data, deliveryGate: gate)
        }
        let old = Task { await session.refresh() }
        for _ in 0..<50 where fixture.readCounts.health == 0 { try await Task.sleep(for: .milliseconds(2)) }
        let endpoint = URL(string: "https://replacement.test")!
        try session.replaceClient(with: StudyRocketRemoteClient(endpoint: endpoint), endpoint: endpoint, persistEndpoint: false)
        gate.release()
        await old.value
        XCTAssertNil(session.health)
        XCTAssertNil(session.snapshot)
        XCTAssertEqual(session.state, .connecting)
        session.leaveForeground()
    }

    func testAuthenticationFailureDoesNotRetryOnTimerOrNetworkPath() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot())
        let session = makeSession(directory: directory, fixture: fixture)
        session.connectionRetryDelays = [.milliseconds(5)]
        let requests = MobileLifecycleCounter()
        MobileStubURLProtocol.handler = { _ in
            requests.increment()
            return MobileStubResponse(statusCode: 401, data: try JSONEncoder().encode(APIErrorBody(code: "unauthorized", message: "Pair again")))
        }
        await session.refresh()
        session.networkPathChanged(isAvailable: false)
        session.networkPathChanged(isAvailable: true)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(requests.value, 1)
        XCTAssertEqual(session.state, .failed("Pair again"))
        MobileStubURLProtocol.handler = fixture.response
        await session.refresh()
        XCTAssertEqual(session.state, .online)
        session.leaveForeground()
    }

    func testCancelledReplayCannotClearResumedReplayOwnership() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot())
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()
        try writeDrafts(directory: directory, legacy: false, deliveryTexts: ["交付物 3"], periodIDs: [], includeDaily: false)
        let firstGate = MobileStubDeliveryGate(), resumedGate = MobileStubDeliveryGate()
        let writes = MobileLifecycleCounter()
        MobileStubURLProtocol.handler = { request in
            if request.url?.path == "/v1/deliveries/toggle" {
                writes.increment()
                if writes.value == 1 {
                    return MobileStubResponse(statusCode: 503, data: try JSONEncoder().encode(APIErrorBody(code: "unavailable", message: "Retry")), deliveryGate: firstGate)
                }
                let response = try fixture.response(for: request)
                return MobileStubResponse(statusCode: response.statusCode, data: response.data, deliveryGate: resumedGate)
            }
            return try fixture.response(for: request)
        }
        let oldReplay = Task { await session.commitPendingDrafts() }
        for _ in 0..<50 where writes.value == 0 { try await Task.sleep(for: .milliseconds(2)) }
        session.leaveForeground()
        let resumed = Task { await session.enterForeground() }
        for _ in 0..<50 where writes.value < 2 { try await Task.sleep(for: .milliseconds(2)) }
        firstGate.release()
        await oldReplay.value
        XCTAssertEqual(writes.value, 2)
        XCTAssertTrue(session.isReplayingPendingToggles)
        resumedGate.release()
        await resumed.value
        XCTAssertFalse(session.isReplayingPendingToggles)
        XCTAssertEqual(session.pendingDeliveryCount, 0)
        session.leaveForeground()
    }

    func testConcurrentRefreshDuringReplaySharesReadWithoutOverlappingWrites() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot())
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()
        try writeDrafts(directory: directory, legacy: false, deliveryTexts: ["交付物 3"], periodIDs: [], includeDaily: false)
        let gate = MobileStubDeliveryGate()
        MobileStubURLProtocol.handler = { request in
            let response = try fixture.response(for: request)
            return MobileStubResponse(statusCode: response.statusCode, data: response.data,
                deliveryGate: request.url?.path == "/v1/deliveries/toggle" ? gate : nil)
        }
        let replay = Task { await session.commitPendingDrafts() }
        for _ in 0..<50 where !session.isReplayingPendingToggles { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(session.isReplayingPendingToggles)
        let first = Task { await session.refresh() }
        let second = Task { await session.refresh() }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(fixture.readCounts.health, 2)
        gate.release()
        await replay.value; await first.value; await second.value
        XCTAssertEqual(fixture.readCounts.health, 2)
        XCTAssertEqual(fixture.readCounts.snapshot, 2)
        XCTAssertEqual(fixture.writePaths, ["/v1/deliveries/toggle"])
        session.leaveForeground()
    }

    func testHistoricalSnapshotReplayCannotOverwriteCurrentHTTPAuthorityOrCache() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = timedSnapshot(revision: "old-merged-tasks", timestamp: 1_000, label: "11月12日 · 周四")
        let current = timedSnapshot(revision: "current-independent-tasks", timestamp: 2_000, label: "11月14日 · 周六")
        let next = timedSnapshot(revision: "new-authoritative-change", timestamp: 3_001, label: "11月14日 · 周六")
        let event = timedSnapshot(revision: "event-payload-never-adopted", timestamp: 3_000, label: "不可作为当前内容")
        let fixture = MobileSyncFixture(snapshot: current)
        let session = makeSession(directory: directory, fixture: fixture)
        let reads = MobileLifecycleCounter(), newReadGate = MobileStubDeliveryGate()
        MobileStubURLProtocol.handler = { request in
            if request.url?.path == "/v1/snapshot" {
                reads.increment()
                return MobileStubResponse(statusCode: 200, data: try JSONEncoder().encode(reads.value == 1 ? current : next), deliveryGate: reads.value == 1 ? nil : newReadGate)
            }
            return try fixture.response(for: request)
        }
        await session.refresh()
        for _ in 0..<100 { session.consumeHostEvent(HostEventEnvelope(kind: "snapshot", snapshot: old)) }
        session.consumeHostEvent(HostEventEnvelope(kind: "resync", snapshot: old,
            chat: ChatStreamEvent(kind: "item_completed", turnID: "history", itemID: "item", text: "历史正文仍然保留")))
        XCTAssertTrue(session.chatMessages.contains { $0.text == "历史正文仍然保留" })
        session.consumeHostEvent(HostEventEnvelope(kind: "chat", chat: ChatStreamEvent(kind: "status", turnID: "history", status: "completed")))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(session.snapshot, current)
        XCTAssertEqual(reads.value, 1, "Old event pages must not cause a GET storm")
        let cached = try JSONDecoder().decode(SnapshotResponse.self, from: Data(contentsOf: directory.appendingPathComponent("snapshot.json")))
        XCTAssertEqual(cached, current)
        // A genuinely new event invalidates once; even while GET is delayed,
        // its historical payload is never rendered as current content.
        for _ in 0..<20 { session.consumeHostEvent(HostEventEnvelope(kind: "snapshot", snapshot: event)) }
        for _ in 0..<50 where reads.value < 2 { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(session.snapshot, current)
        XCTAssertEqual(reads.value, 2)
        newReadGate.release()
        for _ in 0..<50 where session.snapshot?.revision != next.revision { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(session.snapshot, next)
        XCTAssertEqual(reads.value, 2)
        session.leaveForeground()
    }

    func testSnapshotInvalidationDuringExistingGETRequiresFollowupRead() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = timedSnapshot(revision: "initial", timestamp: 1_000, label: "11月14日")
        let earlyRead = timedSnapshot(revision: "read-before-event", timestamp: 1_100, label: "11月14日")
        let event = timedSnapshot(revision: "invalidated", timestamp: 1_200, label: "事件内容不可直接显示")
        let latest = timedSnapshot(revision: "read-after-event", timestamp: 1_300, label: "11月14日")
        let fixture = MobileSyncFixture(snapshot: initial)
        let session = makeSession(directory: directory, fixture: fixture)
        let reads = MobileLifecycleCounter(), gate = MobileStubDeliveryGate()
        MobileStubURLProtocol.handler = { request in
            if request.url?.path == "/v1/snapshot" {
                reads.increment()
                let value = reads.value == 1 ? initial : reads.value == 2 ? earlyRead : latest
                return MobileStubResponse(statusCode: 200, data: try JSONEncoder().encode(value), deliveryGate: reads.value == 2 ? gate : nil)
            }
            return try fixture.response(for: request)
        }
        await session.refresh()
        let pull = Task { await session.refreshVisibleContent() }
        for _ in 0..<50 where reads.value < 2 { try await Task.sleep(for: .milliseconds(2)) }
        session.consumeHostEvent(HostEventEnvelope(kind: "resync", snapshot: event))
        try await Task.sleep(for: .milliseconds(5))
        gate.release()
        await pull.value
        for _ in 0..<50 where session.snapshot?.revision != latest.revision { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(session.snapshot, latest)
        XCTAssertEqual(reads.value, 3, "Dirty-during-read needs exactly one followup authoritative GET")
        session.leaveForeground()
    }

    func testNewSnapshotInvalidationDuringFollowupIsRetainedButFutureTimestampIsBounded() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = timedSnapshot(revision: "initial", timestamp: 1_000, label: "11月14日")
        let firstEvent = timedSnapshot(revision: "event-one", timestamp: 1_200, label: "事件")
        let secondEvent = timedSnapshot(revision: "event-two", timestamp: 1_400, label: "事件")
        let futureEvent = timedSnapshot(revision: "future-event", timestamp: 9_999, label: "未来时间")
        let latest = timedSnapshot(revision: "latest", timestamp: 1_500, label: "11月14日")
        let firstRead = timedSnapshot(revision: "before-first", timestamp: 1_100, label: "11月14日")
        let secondRead = timedSnapshot(revision: "before-second", timestamp: 1_300, label: "11月14日")
        let fixture = MobileSyncFixture(snapshot: initial)
        let session = makeSession(directory: directory, fixture: fixture)
        let reads = MobileLifecycleCounter(), gate = MobileStubDeliveryGate()
        MobileStubURLProtocol.handler = { request in
            if request.url?.path == "/v1/snapshot" {
                reads.increment()
                let value = reads.value == 1 ? initial : reads.value == 2 ? firstRead : reads.value == 3 ? secondRead : latest
                return MobileStubResponse(statusCode: 200, data: try JSONEncoder().encode(value), deliveryGate: reads.value == 3 ? gate : nil)
            }
            return try fixture.response(for: request)
        }
        await session.refresh()
        session.consumeHostEvent(HostEventEnvelope(kind: "snapshot", snapshot: firstEvent))
        for _ in 0..<50 where reads.value < 3 { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(reads.value, 3)
        session.consumeHostEvent(HostEventEnvelope(kind: "snapshot", snapshot: secondEvent))
        gate.release()
        for _ in 0..<50 where session.snapshot?.revision != latest.revision { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(session.snapshot, latest)
        XCTAssertEqual(reads.value, 4)
        session.consumeHostEvent(HostEventEnvelope(kind: "snapshot", snapshot: futureEvent))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(reads.value, 6, "A single future timestamp may not start an endless read loop")
        XCTAssertEqual(session.snapshot, latest)
        session.leaveForeground()
    }

    func testVisibleRefreshCompletesWhileSlowPendingReplayKeepsOwnIndicator() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeDrafts(directory: directory, legacy: false, deliveryTexts: ["交付物 3"], periodIDs: [], includeDaily: false)
        let fixture = MobileSyncFixture(snapshot: makeSnapshot())
        let session = makeSession(directory: directory, fixture: fixture)
        let gate = MobileStubDeliveryGate()
        MobileStubURLProtocol.handler = { request in
            let response = try fixture.response(for: request)
            return MobileStubResponse(statusCode: response.statusCode, data: response.data,
                deliveryGate: request.url?.path == "/v1/deliveries/toggle" ? gate : nil)
        }
        var completedRead = false
        let visibleRefresh = Task { await session.refreshVisibleContent(); completedRead = true }
        for _ in 0..<50 where !completedRead || !session.isReplayingPendingToggles { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(completedRead, "Pull spinner must not wait for the queued write receipt")
        XCTAssertFalse(session.isRefreshingSnapshot)
        XCTAssertEqual(session.state, .online)
        XCTAssertTrue(session.isReplayingPendingToggles)
        XCTAssertEqual(session.pendingDeliveryCount, 1)
        gate.release()
        await visibleRefresh.value
        await session.refresh()
        XCTAssertEqual(fixture.writePaths, ["/v1/deliveries/toggle"])
        XCTAssertEqual(session.pendingDeliveryCount, 0)
        session.leaveForeground()
    }

    func testSlowSnapshotCannotRollBackNewerQueuedWriteReceipt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeDrafts(directory: directory, legacy: false, deliveryTexts: ["交付物 3"], periodIDs: [], includeDaily: false)
        let original = makeSnapshot()
        let fixture = MobileSyncFixture(snapshot: original)
        let session = makeSession(directory: directory, fixture: fixture)
        let writeGate = MobileStubDeliveryGate(), readGate = MobileStubDeliveryGate()
        let reads = MobileLifecycleCounter()
        MobileStubURLProtocol.handler = { request in
            if request.url?.path == "/v1/snapshot" {
                reads.increment()
                if reads.value > 1 {
                    return MobileStubResponse(statusCode: 200, data: try JSONEncoder().encode(original), deliveryGate: readGate)
                }
            }
            let response = try fixture.response(for: request)
            return MobileStubResponse(statusCode: response.statusCode, data: response.data,
                deliveryGate: request.url?.path == "/v1/deliveries/toggle" ? writeGate : nil)
        }
        await session.refreshVisibleContent()
        for _ in 0..<50 where fixture.writePaths.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        let secondRead = Task { await session.refreshVisibleContent() }
        for _ in 0..<50 where reads.value < 2 { try await Task.sleep(for: .milliseconds(2)) }
        writeGate.release()
        for _ in 0..<50 where session.pendingDeliveryCount != 0 { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(session.snapshot?.revision, "r1")
        readGate.release()
        await secondRead.value
        XCTAssertEqual(session.snapshot?.revision, "r1")
        XCTAssertEqual(fixture.writePaths, ["/v1/deliveries/toggle"])
        session.leaveForeground()
    }

    func testOnlineReadKeepsCacheStatusAndUsesBoundedRequestTimeouts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot())
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()
        let gate = MobileStubDeliveryGate()
        MobileStubURLProtocol.handler = { request in
            if request.url?.path == "/v1/health" { XCTAssertEqual(request.timeoutInterval, 8) }
            if request.url?.path == "/v1/snapshot" { XCTAssertEqual(request.timeoutInterval, 12) }
            let response = try fixture.response(for: request)
            return MobileStubResponse(statusCode: response.statusCode, data: response.data,
                deliveryGate: request.url?.path == "/v1/snapshot" ? gate : nil)
        }
        let refresh = Task { await session.refreshVisibleContent() }
        for _ in 0..<50 where fixture.readCounts.snapshot < 2 { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(session.isRefreshingSnapshot)
        XCTAssertEqual(session.state, .online, "Checking an online snapshot must not insert an offline card")
        XCTAssertNotNil(session.snapshot)
        gate.release()
        await refresh.value
        XCTAssertFalse(session.isRefreshingSnapshot)
        MobileStubURLProtocol.handler = { _ in throw URLError(.timedOut) }
        await session.refreshVisibleContent()
        XCTAssertNotNil(session.snapshot)
        XCTAssertFalse(session.isRefreshingSnapshot)
        XCTAssertNotEqual(session.state, .online)
        let offlineState = session.state
        let retryGate = MobileStubDeliveryGate()
        MobileStubURLProtocol.handler = { request in
            let response = try fixture.response(for: request)
            return MobileStubResponse(statusCode: response.statusCode, data: response.data,
                deliveryGate: request.url?.path == "/v1/health" ? retryGate : nil)
        }
        let retry = Task { await session.refreshVisibleContent() }
        for _ in 0..<50 where !session.isRefreshingSnapshot { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(session.state, offlineState, "A manual pull must not replace the existing cache status with connecting text")
        retryGate.release()
        await retry.value
        XCTAssertEqual(session.state, .online)
        session.leaveForeground()
    }

    func testConcurrentRefreshUsesOneSnapshotAndOneReplay() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeDrafts(directory: directory, legacy: false, deliveryTexts: ["交付物 3"], periodIDs: [], includeDaily: false)
        let fixture = MobileSyncFixture(snapshot: makeSnapshot())
        let session = makeSession(directory: directory, fixture: fixture)

        async let first: Void = session.refresh()
        async let second: Void = session.refresh()
        _ = await (first, second)

        XCTAssertEqual(fixture.readCounts.health, 1)
        XCTAssertEqual(fixture.readCounts.snapshot, 1)
        XCTAssertEqual(fixture.writePaths, ["/v1/deliveries/toggle"])
        XCTAssertEqual(session.pendingDeliveryCount, 0)
        XCTAssertEqual(session.snapshot?.revision, "r1")
    }

    func testThreeEventFailuresProbeWithoutDowngradingHealthyHost() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot())
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()

        session.noteEventStreamFailure()
        session.noteEventStreamFailure()
        XCTAssertEqual(session.state, .online)
        session.noteEventStreamFailure()
        for _ in 0..<40 where fixture.readCounts.health < 2 || fixture.readCounts.snapshot < 2 {
            await Task.yield()
        }

        XCTAssertEqual(fixture.readCounts.health, 2)
        XCTAssertEqual(fixture.readCounts.snapshot, 2)
        XCTAssertEqual(session.state, .online)
    }

    func testEventStreamReconnectRefreshesAndReplaysPendingToggles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeDrafts(
            directory: directory,
            legacy: false,
            deliveryTexts: ["交付物 3"],
            periodIDs: ["morning"],
            includeDaily: false
        )
        let cached = makeSnapshot()
        try JSONEncoder().encode(cached)
            .write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
        let fixture = MobileSyncFixture(snapshot: cached)
        let session = makeSession(directory: directory, fixture: fixture)

        XCTAssertEqual(session.state, .offline(lastUpdated: cached.fetchedAt))
        session.noteEventStreamConnected()
        for _ in 0..<100 where fixture.writePaths.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(fixture.readCounts.health, 1)
        XCTAssertEqual(fixture.readCounts.snapshot, 1)
        XCTAssertEqual(fixture.writePaths, ["/v1/deliveries/toggle", "/v1/periods/toggle"])
        XCTAssertEqual(session.pendingDeliveryCount, 0)
        XCTAssertEqual(session.pendingPeriodCount, 0)
        XCTAssertEqual(session.state, .online)
        XCTAssertNil(session.pendingToggleSyncIssue)
    }

    func testBackgroundFactReceiptDoesNotOverwriteSnapshotOrPostNextFact() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = makeSnapshot()
        let fixture = MobileSyncFixture(snapshot: original)
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()
        let first = QuickFact(text: "第一条测试事实"), second = QuickFact(text: "第二条测试事实")
        try session.enqueueFact(first); try session.enqueueFact(second)
        let gate = MobileStubDeliveryGate(), writes = MobileLifecycleCounter()
        let late = SnapshotResponse(revision: "old-scene-receipt", home: original.home, week: original.week, daily: original.daily, summaries: [])
        MobileStubURLProtocol.handler = { request in
            if request.url?.path == "/v1/facts" {
                writes.increment()
                return MobileStubResponse(statusCode: 200, data: try JSONEncoder().encode(late), deliveryGate: gate)
            }
            return try fixture.response(for: request)
        }
        let sync = Task { await session.syncFacts() }
        for _ in 0..<50 where writes.value == 0 { try await Task.sleep(for: .milliseconds(2)) }
        session.leaveForeground()
        gate.release()
        await sync.value
        XCTAssertEqual(session.snapshot?.revision, original.revision)
        XCTAssertEqual(session.pendingFacts, [second])
        XCTAssertEqual(writes.value, 1)
    }

    func testFactQueueSurvivesLostReceiptAndRelaunch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot())
        let first = makeSession(directory: directory, fixture: fixture)
        await first.refresh()
        let fact = QuickFact(text: "完成例题")
        try first.enqueueFact(fact)
        await first.syncFacts()
        XCTAssertEqual(first.pendingFacts, [fact])
        let next = makeSession(directory: directory, fixture: fixture)
        XCTAssertEqual(next.pendingFacts, [fact])
        await next.refresh()
        XCTAssertEqual(next.snapshot?.recentFacts, [fact])
        XCTAssertTrue(next.pendingFacts.isEmpty)
        XCTAssertEqual(fixture.writePaths, ["/v1/facts", "/v1/facts"])
    }

    func testConversationRefreshCoalescesAndKeepsDraftAndTurn() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), codexReady: false, chatCompletionAfterHistoryReads: 10)
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await session.refresh()
        XCTAssertFalse(session.isChatAvailable)
        fixture.setReady(true)
        async let button: Void = session.refreshConversation()
        async let pull: Void = session.refreshConversation()
        _ = await (button, pull)
        XCTAssertTrue(session.isChatAvailable)
        XCTAssertEqual(fixture.readCounts.health, 2)
        session.inputDraft = "一条测试问题"
        await session.sendDraft()
        session.inputDraft = "正在输入的下一条"
        await session.refreshConversation()
        XCTAssertEqual(session.inputDraft, "正在输入的下一条")
        XCTAssertTrue(session.isChatBusy)
        XCTAssertNil(session.conversationRefreshError)
        XCTAssertEqual(session.chatMessages.filter { $0.role == "user" }.count, 1)
        let prior = session.chatMessages
        MobileStubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await session.refreshConversation()
        XCTAssertNotNil(session.conversationRefreshError)
        XCTAssertEqual(session.chatMessages, prior)
        MobileStubURLProtocol.handler = fixture.response
        await session.refreshConversation()
        XCTAssertNil(session.conversationRefreshError)
        XCTAssertEqual(session.inputDraft, "正在输入的下一条")
        XCTAssertTrue(fixture.writePaths.isEmpty)
    }

    func testChatRecoversFinalResponseWhenSSEIsUnavailable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 2)
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.milliseconds(30)])

        await session.refresh()
        session.inputDraft = "测试无 SSE 回复恢复"
        await session.sendDraft()

        XCTAssertTrue(session.isChatBusy)
        XCTAssertEqual(session.chatProgress, .thinking)
        for _ in 0..<50 where session.isChatBusy {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(session.isChatBusy)
        XCTAssertNil(session.chatProgress)
        XCTAssertNil(session.lastChatIssue)
        XCTAssertGreaterThanOrEqual(fixture.readCounts.chatHistory, 2)
        XCTAssertTrue(session.chatMessages.contains { $0.role == "assistant" && $0.text == "已恢复的回复" })
        XCTAssertFalse(session.chatMessages.contains { $0.id.hasPrefix("mobile-pending-") })
    }

    func testCancelledHistoryReadKeepsContextBudgetTerminalAndRecoverableInput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reason = "本回合资料达到上下文预算，请缩小问题或分段处理；当前请求与必读资料未被删减。"
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 1,
            chatTerminalIssue: APIErrorBody(code: "context_budget", message: reason))
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await session.refresh()
        session.inputDraft = "帮我看一下今天的安排"
        await session.sendDraft()
        session.inputDraft = "正在输入的下一条"
        await session.refreshChat()

        XCTAssertFalse(session.isChatBusy)
        XCTAssertNil(session.chatProgress)
        XCTAssertEqual(session.lastChatIssueCode, "context_budget")
        XCTAssertEqual(session.lastChatIssue, reason)
        XCTAssertEqual(session.lastFailedChatText, "帮我看一下今天的安排")

        MobileStubURLProtocol.handler = { request in
            if request.url?.path == "/v1/chat/history" { throw URLError(.cancelled) }
            return try fixture.response(for: request)
        }
        await session.refreshChat()
        let cancelledRead = Task { await session.refreshChat() }
        cancelledRead.cancel()
        await cancelledRead.value

        XCTAssertEqual(session.lastChatIssueCode, "context_budget")
        XCTAssertEqual(session.lastChatIssue, reason)
        XCTAssertEqual(session.inputDraft, "正在输入的下一条")
        XCTAssertEqual(session.state, .online)
        XCTAssertTrue(session.chatMessages.contains { $0.role == "assistant" && $0.text == reason && $0.status == "failed" })
        session.restoreFailedChatDraft()
        XCTAssertEqual(session.inputDraft, "帮我看一下今天的安排")
        XCTAssertNil(session.lastChatIssue)
        XCTAssertEqual(fixture.chatRequests.count, 1, "Restoring input must never resend a turn")
    }

    func testCancelledConversationRefreshDoesNotHideTerminalOrDisconnectService() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reason = "本回合资料达到上下文预算，请分段处理。"
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 1,
            chatTerminalIssue: APIErrorBody(code: "context_budget", message: reason))
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await session.refresh()
        session.inputDraft = "测试刷新取消"
        await session.sendDraft()
        await session.refreshChat()
        MobileStubURLProtocol.handler = { request in
            if request.url?.path == "/v1/chat/history" { throw URLError(.cancelled) }
            return try fixture.response(for: request)
        }
        await session.refreshConversation()

        XCTAssertFalse(session.refreshingConversation)
        XCTAssertNil(session.conversationRefreshError)
        XCTAssertNil(session.lastConnectionIssue)
        XCTAssertEqual(session.state, .online)
        XCTAssertEqual(session.lastChatIssueCode, "context_budget")
        XCTAssertEqual(session.lastChatIssue, reason)
        XCTAssertEqual(session.lastFailedChatText, "测试刷新取消")
        XCTAssertFalse(session.isChatBusy)
        XCTAssertEqual(fixture.chatRequests.count, 1)
    }

    func testCancelledSnapshotRefreshPreservesConnectionDraftAndPendingOperation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 10)
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await session.refresh()
        session.inputDraft = "仍在等待的原请求"
        await session.sendDraft()
        session.inputDraft = "尚未发送的新草稿"
        let pendingURL = directory.appendingPathComponent("pending-cloud-chats.json")
        let originalPending = try Data(contentsOf: pendingURL)
        let originalRevision = session.snapshot?.revision
        MobileStubURLProtocol.handler = { _ in throw URLError(.cancelled) }
        await session.refresh()

        XCTAssertEqual(session.state, .online)
        XCTAssertNil(session.lastConnectionIssue)
        XCTAssertNil(session.lastChatIssue)
        XCTAssertEqual(session.inputDraft, "尚未发送的新草稿")
        XCTAssertEqual(session.snapshot?.revision, originalRevision)
        XCTAssertEqual(try Data(contentsOf: pendingURL), originalPending)
        XCTAssertTrue(session.isChatBusy)
        XCTAssertEqual(fixture.chatRequests.count, 1)
    }

    func testCancelledSendReceiptKeepsOriginalIDAndOnlyReadsForRecovery() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reason = "本回合资料达到上下文预算，请分段处理。"
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 1,
            chatTerminalIssue: APIErrorBody(code: "context_budget", message: reason), chatSendCancellation: true)
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.milliseconds(30)])
        await session.refresh()
        session.inputDraft = "已经送达但回执被取消的请求"
        await session.sendDraft()

        XCTAssertTrue(session.isChatBusy)
        XCTAssertEqual(session.chatProgress, .recovering)
        XCTAssertNil(session.lastChatIssue)
        let pendingURL = directory.appendingPathComponent("pending-cloud-chats.json")
        let pending = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: pendingURL)) as? [[String: Any]])
        XCTAssertEqual(pending.first?["id"] as? String, fixture.chatRequests.first?.clientRequestID)
        XCTAssertEqual(pending.first?["text"] as? String, session.inputDraft)
        session.inputDraft = "恢复过程中继续保留的新草稿"
        for _ in 0..<50 where session.isChatBusy { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertFalse(session.isChatBusy)
        XCTAssertEqual(session.lastChatIssueCode, "context_budget")
        XCTAssertEqual(session.lastChatIssue, reason)
        XCTAssertEqual(session.lastFailedChatText, "已经送达但回执被取消的请求")
        XCTAssertEqual(session.inputDraft, "恢复过程中继续保留的新草稿")
        XCTAssertEqual(fixture.chatRequests.count, 1, "An unknown send receipt must never trigger another POST")
        let remaining = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: pendingURL)) as? [[String: Any]])
        XCTAssertTrue(remaining.isEmpty, "Only the authoritative terminal can settle the persisted request")
    }

    func testLateAcceptedReceiptDoesNotClearInputRestoredAfterTerminal() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = MobileStubDeliveryGate()
        defer { gate.release() }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 1,
            chatTerminalIssue: APIErrorBody(code: "context_budget", message: "本回合资料达到上下文预算。"),
            firstChatReceiptGate: gate)
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await session.refresh()
        session.inputDraft = "终态先于发送回执的原请求"
        let sending = Task { await session.sendDraft() }
        for _ in 0..<50 where fixture.chatRequests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fixture.chatRequests.count, 1)
        await session.refreshChat()
        XCTAssertFalse(session.isChatBusy)
        XCTAssertEqual(session.lastChatIssueCode, "context_budget")
        session.restoreFailedChatDraft()

        gate.release()
        await sending.value

        XCTAssertEqual(session.inputDraft, "终态先于发送回执的原请求")
        XCTAssertFalse(session.isChatBusy)
        XCTAssertNil(session.chatProgress)
        XCTAssertNil(session.lastChatIssue)
        XCTAssertEqual(fixture.chatRequests.count, 1)
    }

    func testLateAcceptedReceiptDoesNotChangeNewRequestOrItsDraft() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = MobileStubDeliveryGate()
        defer { gate.release() }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 1,
            chatTerminalIssue: APIErrorBody(code: "context_budget", message: "本回合资料达到上下文预算。"),
            firstChatReceiptGate: gate)
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await session.refresh()
        session.inputDraft = "旧回合原文"
        let oldSend = Task { await session.sendDraft() }
        for _ in 0..<50 where fixture.chatRequests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fixture.chatRequests.count, 1)
        await session.refreshChat()
        XCTAssertFalse(session.isChatBusy)
        fixture.setChatCompletionRead(100)
        session.inputDraft = "用户另外发起的新请求"
        await session.sendDraft()
        session.inputDraft = "旧回合原文"
        let pendingURL = directory.appendingPathComponent("pending-cloud-chats.json")
        let newPending = try Data(contentsOf: pendingURL)
        let pending = try XCTUnwrap(JSONSerialization.jsonObject(with: newPending) as? [[String: Any]])
        XCTAssertEqual(pending.first?["id"] as? String, fixture.chatRequests.last?.clientRequestID)
        XCTAssertNotEqual(fixture.chatRequests.first?.clientRequestID, fixture.chatRequests.last?.clientRequestID)

        gate.release()
        await oldSend.value

        XCTAssertEqual(session.inputDraft, "旧回合原文")
        XCTAssertTrue(session.isChatBusy)
        XCTAssertEqual(session.chatProgress, .thinking)
        XCTAssertNil(session.lastChatIssue)
        XCTAssertEqual(try Data(contentsOf: pendingURL), newPending)
        XCTAssertEqual(fixture.chatRequests.count, 2, "Only the two explicitly submitted requests may be posted")
        fixture.setChatCompletionRead(1)
        await session.refreshChat()
    }

    func testStreamingTerminalFlushesImmediatelyAndHistoryKeepsItemIdentity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 1)
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await session.refresh()
        session.inputDraft = "流式展示测试"
        await session.sendDraft()
        let turn = try XCTUnwrap(fixture.chatRequests.first?.clientRequestID)
        let item = turn + "/assistant"
        session.consumeHostEvent(HostEventEnvelope(kind: "chat", chat: ChatStreamEvent(
            kind: "delta", turnID: turn, itemID: item, text: "已恢复的回复", phase: "final_answer")))
        session.consumeHostEvent(HostEventEnvelope(kind: "chat", chat: ChatStreamEvent(
            kind: "status", turnID: turn, status: "completed")))
        let message = try XCTUnwrap(session.chatMessages.first { $0.role == "assistant" })
        XCTAssertEqual(message.text, "已恢复的回复", "Terminal flush must not leave buffered words behind")
        XCTAssertEqual(message.status, "completed", "Rich rendering must be available without waiting for history")
        await session.refreshChat()
        XCTAssertEqual(session.chatMessages.first { $0.role == "assistant" }?.id, message.id)
        XCTAssertFalse(session.isChatBusy)
    }

    func testExplicitRetryChecksFailedTurnAndPreservesNewComposerDraft() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 1,
            chatTerminalIssue: APIErrorBody(code: "context_budget", message: "请缩小问题。"))
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await session.refresh()
        session.inputDraft = "原问题"
        await session.sendDraft()
        await session.refreshChat()
        let firstID = fixture.chatRequests.first?.clientRequestID
        session.inputDraft = "正在写的另一条草稿"
        let reads = fixture.totalChatHistoryReadCount
        await session.retryFailedChat()
        XCTAssertGreaterThan(fixture.totalChatHistoryReadCount, reads)
        XCTAssertEqual(fixture.chatRequests.count, 2)
        XCTAssertNotEqual(firstID, fixture.chatRequests.last?.clientRequestID)
        XCTAssertEqual(fixture.chatRequests.last?.text, "原问题")
        XCTAssertEqual(session.inputDraft, "正在写的另一条草稿")
        await session.refreshChat()
    }

    func testObservedReplayIsSettledWhenTerminalHistoryArrivesBeforeSSETerminal() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), cloudBackend: true)
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()
        // Read-only fixture DB sequence: four turns, terminal states completed,
        // completed, failed, completed; each SSE sequence is status(inProgress),
        // delta(s), item_completed, status(terminal). A concurrent history read
        // can arrive between the last turn's initial and terminal SSE events.
        session.consumeHostEvent(HostEventEnvelope(kind: "chat", chat: ChatStreamEvent(
            kind: "status", turnID: "fixture-4", status: "inProgress")))
        XCTAssertTrue(session.isChatBusy)
        let statuses = ["completed", "completed", "failed", "completed"]
        let messages = statuses.enumerated().flatMap { index, status in
            ["user", "assistant"].map { role in
                ChatMessageDTO(id: "fixture-\(index + 1)/\(role)", role: role, text: "合成历史",
                    date: Date(timeIntervalSinceReferenceDate: Double(index)), turnID: "fixture-\(index + 1)", status: status)
            }
        }
        let terminals = statuses.enumerated().map {
            ChatTurnTerminalDTO(turnID: "fixture-\($0.offset + 1)", status: $0.element)
        }
        fixture.setChatHistory(ChatHistoryResponse(revision: "8", messages: messages, terminalTurns: terminals))
        await session.refreshChat()
        XCTAssertFalse(session.isChatBusy, "Authoritative terminal history must settle an observed remote turn")
        session.consumeHostEvent(HostEventEnvelope(kind: "chat", chat: ChatStreamEvent(
            kind: "item_completed", turnID: "fixture-4", itemID: "fixture-4/assistant", text: "合成历史", status: "completed")))
        session.consumeHostEvent(HostEventEnvelope(kind: "chat", chat: ChatStreamEvent(
            kind: "status", turnID: "fixture-4", status: "completed")))
        XCTAssertFalse(session.isChatBusy, "A deduplicated terminal must not strand remote activity")
        XCTAssertTrue(fixture.chatRequests.isEmpty)
    }

    func testFixture67EventReplayAcrossAllFourHistoryInterleavings() async throws {
        // Credential/content-free sequence read from the isolated runtime DB:
        // starts at seq 1,10,54,59; the last turn emits proposals.updated at 60.
        let statuses = ["completed", "completed", "failed", "completed"]
        let deltaCounts = [6, 41, 2, 5]
        var events: [HostEventEnvelope] = []
        for index in 0..<4 {
            let turn = "fixture-\(index + 1)"
            events.append(HostEventEnvelope(kind: "chat", chat: ChatStreamEvent(kind: "status", turnID: turn, status: "inProgress")))
            if index == 3 { events.append(HostEventEnvelope(kind: "proposals.updated")) }
            for _ in 0..<deltaCounts[index] {
                events.append(HostEventEnvelope(kind: "chat", chat: ChatStreamEvent(kind: "delta", turnID: turn, itemID: turn + "/assistant", text: "片段")))
            }
            events.append(HostEventEnvelope(kind: "chat", chat: ChatStreamEvent(kind: "item_completed", turnID: turn,
                itemID: turn + "/assistant", text: "合成完整回复", status: statuses[index])))
            events.append(HostEventEnvelope(kind: "chat", chat: ChatStreamEvent(kind: "status", turnID: turn, status: statuses[index])))
        }
        XCTAssertEqual(events.count, 67)
        let messages = statuses.enumerated().flatMap { index, status in
            ["user", "assistant"].map { role in
                ChatMessageDTO(id: "fixture-\(index + 1)/\(role)", role: role, text: "合成完整回复",
                    date: Date(timeIntervalSinceReferenceDate: Double(index)), turnID: "fixture-\(index + 1)", status: status)
            }
        }
        let history = ChatHistoryResponse(revision: "8", messages: messages, terminalTurns: statuses.enumerated().map {
            ChatTurnTerminalDTO(turnID: "fixture-\($0.offset + 1)", status: $0.element)
        })
        for sequence in [1, 10, 54, 59] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = MobileSyncFixture(snapshot: makeSnapshot(), cloudBackend: true)
            let session = makeSession(directory: directory, fixture: fixture)
            await session.refresh()
            fixture.setChatHistory(history)
            for (index, event) in events.enumerated() {
                session.consumeHostEvent(event)
                if index + 1 == sequence { await session.refreshChat() }
            }
            await session.refreshChat()
            XCTAssertFalse(session.isChatBusy, "History interleaving after SSE sequence \(sequence)")
            XCTAssertNil(session.chatProgress)
            XCTAssertFalse(session.chatMessages.contains { $0.status == "inProgress" })
            XCTAssertTrue(fixture.chatRequests.isEmpty)
        }
    }

    func testTerminalOnlyHistoryBlocksReplayedProgressAndAnonymousStart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), cloudBackend: true)
        fixture.setChatHistory(ChatHistoryResponse(revision: "1", messages: [], terminalTurns: [
            ChatTurnTerminalDTO(turnID: "finished-without-message", status: "failed")]))
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()
        await session.refreshChat()
        session.consumeHostEvent(HostEventEnvelope(kind: "chat", chat: ChatStreamEvent(
            kind: "status", turnID: "finished-without-message", status: "inProgress")))
        XCTAssertFalse(session.isChatBusy)
        session.consumeHostEvent(HostEventEnvelope(kind: "chat.started"))
        XCTAssertFalse(session.isChatBusy, "Anonymous legacy events must reconcile history rather than invent a live turn")
        await session.refreshChat()
        XCTAssertFalse(session.isChatBusy)
        XCTAssertTrue(fixture.chatRequests.isEmpty)
    }

    func testAuthoritativeRemoteRunningTurnRemainsBusyUntilItsOwnTerminal() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), cloudBackend: true)
        let running = ChatMessageDTO(id: "remote/user", role: "user", text: "另一个客户端的回合",
            date: .now, turnID: "remote", status: "inProgress")
        fixture.setChatHistory(ChatHistoryResponse(revision: "1", messages: [running]))
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()
        await session.refreshChat()
        XCTAssertTrue(session.isChatBusy)
        session.consumeHostEvent(HostEventEnvelope(kind: "chat", chat: ChatStreamEvent(
            kind: "status", turnID: "unrelated-old", status: "completed")))
        XCTAssertTrue(session.isChatBusy, "An unrelated terminal must not clear a live remote turn")
        fixture.setChatHistory(ChatHistoryResponse(revision: "2", messages: [running], terminalTurns: [
            ChatTurnTerminalDTO(turnID: "remote", status: "completed")]))
        await session.refreshChat()
        XCTAssertFalse(session.isChatBusy)
        XCTAssertTrue(fixture.chatRequests.isEmpty)
    }

    func testOldSSETerminalAndItemCannotSettleNewPendingOperation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 100, cloudBackend: true)
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await session.refresh()
        session.inputDraft = "当前请求 A"
        await session.sendDraft()
        let currentID = try XCTUnwrap(fixture.chatRequests.last?.clientRequestID)
        let pendingURL = directory.appendingPathComponent("pending-cloud-chats.json")
        let before = try Data(contentsOf: pendingURL)
        for status in ["failed", "inProgress", "completed"] {
            session.consumeHostEvent(HostEventEnvelope(kind: "chat", chat: ChatStreamEvent(
                kind: "status", turnID: "old-B", text: "旧消息", status: status)))
        }
        session.consumeHostEvent(HostEventEnvelope(kind: "chat", chat: ChatStreamEvent(
            kind: "item_completed", turnID: "old-B", itemID: "old-item", text: "旧回复")))
        XCTAssertTrue(session.isChatBusy)
        XCTAssertEqual(try Data(contentsOf: pendingURL), before)
        XCTAssertNil(session.lastFailedChatText)
        session.consumeHostEvent(HostEventEnvelope(kind: "chat", chat: ChatStreamEvent(
            kind: "status", turnID: currentID, status: "completed")))
        XCTAssertFalse(session.isChatBusy)
        let remaining = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: pendingURL)) as? [[String: Any]])
        XCTAssertTrue(remaining.isEmpty)
    }

    func testLegacyHostTerminalBeforeHistorySettlesOnlyAfterProvenBinding() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 1,
            chatTurnIDOverride: "legacy-host-turn")
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await session.refresh()
        session.inputDraft = "Host 使用自己的 turn ID"
        await session.sendDraft()
        let pendingURL = directory.appendingPathComponent("pending-cloud-chats.json")
        let before = try Data(contentsOf: pendingURL)
        session.consumeHostEvent(HostEventEnvelope(kind: "chat", chat: ChatStreamEvent(
            kind: "status", turnID: "legacy-host-turn", status: "completed")))
        XCTAssertTrue(session.isChatBusy)
        XCTAssertEqual(try Data(contentsOf: pendingURL), before)
        await session.refreshChat()
        XCTAssertFalse(session.isChatBusy)
        let remaining = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: pendingURL)) as? [[String: Any]])
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSameTextOldHistoryDoesNotConsumeNewOptimisticMessageOrOperation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 1,
            chatTerminalIssue: APIErrorBody(code: "context_budget", message: "原回合失败"), cloudBackend: true)
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await session.refresh()
        session.inputDraft = "相同问题"
        await session.sendDraft()
        await session.refreshChat()
        let oldID = try XCTUnwrap(fixture.chatRequests.last?.clientRequestID)
        let oldHistory = ChatHistoryResponse(revision: "old", messages: session.chatMessages,
            terminalTurns: [ChatTurnTerminalDTO(turnID: oldID, status: "failed")])
        MobileStubURLProtocol.handler = { request in
            if request.url?.path == "/v1/chat/history" {
                return MobileStubResponse(statusCode: 200, data: try JSONEncoder().encode(oldHistory))
            }
            return try fixture.response(for: request)
        }
        session.inputDraft = "相同问题"
        await session.sendDraft()
        let newID = try XCTUnwrap(fixture.chatRequests.last?.clientRequestID)
        let pendingURL = directory.appendingPathComponent("pending-cloud-chats.json")
        let before = try Data(contentsOf: pendingURL)
        await session.refreshChat()
        XCTAssertTrue(session.chatMessages.contains { $0.id == "mobile-pending-" + newID })
        XCTAssertTrue(session.isChatBusy)
        session.inputDraft = "相同问题"
        await session.sendDraft()
        XCTAssertEqual(fixture.chatRequests.count, 2)
        XCTAssertEqual(try Data(contentsOf: pendingURL), before)
        MobileStubURLProtocol.handler = fixture.response
        await session.refreshChat()
    }

    func testPersistedUnknownOperationWinsOverOldSameTextFailureWhenRetrying() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 1,
            chatTerminalIssue: APIErrorBody(code: "context_budget", message: "旧回合失败"), cloudBackend: true)
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await session.refresh()
        session.inputDraft = "相同问题"
        await session.sendDraft()
        await session.refreshChat()
        let pendingURL = directory.appendingPathComponent("pending-cloud-chats.json")
        let unknown = try JSONSerialization.data(withJSONObject: [["id": UUID().uuidString, "text": "相同问题",
            "endpoint": "https://studyrocket.test", "repositoryID": "repo-test"]])
        try unknown.write(to: pendingURL)
        await session.retryFailedChat()
        XCTAssertEqual(fixture.chatRequests.count, 1)
        XCTAssertEqual(try Data(contentsOf: pendingURL), unknown)
    }

    func testExplicitPreAdmissionRejectionCanRetryThroughSendButton() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 1,
            firstChatRejection: APIErrorBody(code: "chat_busy", message: "上一回合仍在执行"), cloudBackend: true)
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await session.refresh()
        session.inputDraft = "被拒绝但尚未创建的请求"
        await session.sendDraft()
        XCTAssertFalse(session.isChatBusy)
        let rejectedID = fixture.chatRequests.first?.clientRequestID
        await session.sendDraft()
        XCTAssertEqual(fixture.chatRequests.count, 2)
        XCTAssertNotEqual(fixture.chatRequests.last?.clientRequestID, rejectedID)
        await session.refreshChat()
    }

    func testRetryStatusReadBlocksConcurrentSendWithoutLosingComposerDraft() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 1,
            chatTerminalIssue: APIErrorBody(code: "context_budget", message: "失败"), cloudBackend: true)
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await session.refresh()
        session.inputDraft = "请求 A"
        await session.sendDraft()
        await session.refreshChat()
        let gate = MobileStubDeliveryGate()
        defer { gate.release() }
        MobileStubURLProtocol.handler = { request in
            var response = try fixture.response(for: request)
            if request.url?.path == "/v1/chat/history" { response.deliveryGate = gate }
            return response
        }
        let retry = Task { await session.retryFailedChat() }
        for _ in 0..<50 where !session.retryingChat { try await Task.sleep(for: .milliseconds(10)) }
        session.inputDraft = "新草稿 B"
        await session.sendDraft()
        XCTAssertEqual(fixture.chatRequests.count, 1)
        XCTAssertEqual(session.inputDraft, "新草稿 B")
        gate.release()
        await retry.value
        XCTAssertEqual(fixture.chatRequests.count, 2)
        XCTAssertEqual(fixture.chatRequests.last?.text, "请求 A")
        XCTAssertEqual(session.inputDraft, "新草稿 B")
        await session.refreshChat()
    }

    func testStopAcknowledgementDoesNotDiscardUnknownOperationBeforeTerminal() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 100, cloudBackend: true)
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await session.refresh()
        session.inputDraft = "等待停止回执"
        await session.sendDraft()
        let pendingURL = directory.appendingPathComponent("pending-cloud-chats.json")
        let before = try Data(contentsOf: pendingURL)
        MobileStubURLProtocol.handler = { request in
            if request.url?.path == "/v1/chat/interrupt" {
                return MobileStubResponse(statusCode: 200, data: Data("{}".utf8))
            }
            return try fixture.response(for: request)
        }
        await session.interruptChat()
        XCTAssertTrue(session.isChatBusy)
        XCTAssertEqual(try Data(contentsOf: pendingURL), before)
        fixture.setChatCompletionRead(1)
        await session.refreshChat()
        XCTAssertFalse(session.isChatBusy)
    }

    func testEmptyAcceptanceReceiptPreservesVisibleConversation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 1)
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await session.refresh()
        session.inputDraft = "上一轮问题"
        await session.sendDraft()
        await session.refreshChat()
        let prior = session.chatMessages
        session.inputDraft = "下一轮问题"
        await session.sendDraft()
        XCTAssertTrue(prior.allSatisfy { session.chatMessages.contains($0) }, "An empty send receipt must not clear rendered history")
        XCTAssertTrue(session.chatMessages.contains { $0.text == "下一轮问题" })
        await session.refreshChat()
    }

    func testRelaunchedConversationRestoresFailedMessageRetryWithoutSending() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 1,
            chatTerminalIssue: APIErrorBody(code: "context_budget", message: "请缩小问题。"))
        let first = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await first.refresh()
        first.inputDraft = "上次失败的问题"
        await first.sendDraft()
        await first.refreshChat()
        let next = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await next.refresh()
        await next.refreshConversation()
        XCTAssertEqual(next.lastFailedChatText, "上次失败的问题")
        XCTAssertEqual(next.lastChatIssueCode, "context_budget")
        let failedUser = try XCTUnwrap(next.chatMessages.first { $0.role == "user" })
        XCTAssertTrue(next.isFailedChatMessage(failedUser))
        XCTAssertFalse(next.isFailedChatMessage(ChatMessageDTO(id: "older-user", role: "user", text: failedUser.text,
            date: failedUser.date, turnID: "different-turn", status: "failed")))
        XCTAssertEqual(fixture.chatRequests.count, 1)
        await next.retryFailedChat()
        XCTAssertEqual(fixture.chatRequests.count, 2)
        await next.refreshChat()
    }

    func testRetryOfUnknownReceiptOnlyChecksHistoryAndNeverPostsAgain() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 100)
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await session.refresh()
        MobileStubURLProtocol.handler = { request in
            let response = try fixture.response(for: request)
            if request.url?.path == "/v1/chat/send" { throw URLError(.networkConnectionLost) }
            return response
        }
        session.inputDraft = "回执丢失的原问题"
        await session.sendDraft()
        XCTAssertTrue(session.isChatBusy)
        XCTAssertEqual(session.lastFailedChatText, "回执丢失的原问题")
        await session.retryFailedChat()
        await session.sendDraft()
        XCTAssertEqual(fixture.chatRequests.count, 1)
        XCTAssertTrue(session.isChatBusy)
        fixture.setChatCompletionRead(1)
        await session.retryFailedChat()
        XCTAssertEqual(fixture.chatRequests.count, 1, "A remotely completed operation must not be repeated")
        XCTAssertFalse(session.isChatBusy)
        XCTAssertNil(session.lastFailedChatText)
    }

    func testRetryDoesNotSendWhenAuthoritativeReadFails() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), chatCompletionAfterHistoryReads: 1,
            chatTerminalIssue: APIErrorBody(code: "context_budget", message: "请缩小问题。"))
        let session = makeSession(directory: directory, fixture: fixture, chatRecoveryDelays: [.seconds(10)])
        await session.refresh()
        session.inputDraft = "原问题"
        await session.sendDraft()
        await session.refreshChat()
        MobileStubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await session.retryFailedChat()
        XCTAssertEqual(fixture.chatRequests.count, 1)
        XCTAssertEqual(session.lastFailedChatText, "原问题")
        XCTAssertTrue(session.lastChatIssue?.contains("未重复发送") == true)
        XCTAssertFalse(session.retryingChat)
    }

    func testConflictRemainsAWriteIssueWhileHostStaysOnline() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(
            snapshot: makeSnapshot(),
            forcedDeliveryError: APIErrorBody(code: "conflict", message: "revision conflict", retryable: true)
        )
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()
        let delivery = try XCTUnwrap(session.snapshot?.week.deliveries.first(where: { $0.id == "d3" }))
        let mutation = MobileDeliveryMutation(deliveryID: delivery.id, token: UUID(), repositoryGeneration: session.repositoryGeneration)

        let result = await session.toggleDelivery(delivery, isCompleted: true, mutation: mutation)

        guard case .failed = result else { return XCTFail("expected a failed write result") }
        XCTAssertEqual(session.state, .online)
        XCTAssertNotNil(session.pendingToggleSyncIssue)
        XCTAssertFalse(session.snapshot?.week.deliveries.first(where: { $0.id == "d3" })?.isCompleted ?? true)
    }

    func testUnprocessableWriteDoesNotBecomeConnectionFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(
            snapshot: makeSnapshot(),
            forcedDeliveryError: APIErrorBody(code: "delivery_not_found", message: "task changed")
        )
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()
        let delivery = try XCTUnwrap(session.snapshot?.week.deliveries.first(where: { $0.id == "d3" }))
        let mutation = MobileDeliveryMutation(deliveryID: delivery.id, token: UUID(), repositoryGeneration: session.repositoryGeneration)

        let result = await session.toggleDelivery(delivery, isCompleted: true, mutation: mutation)

        guard case .failed = result else { return XCTFail("expected a failed write result") }
        XCTAssertEqual(session.state, .online)
        XCTAssertNotNil(session.pendingToggleSyncIssue)
        XCTAssertNil(session.lastConnectionIssue)
    }

    func testRestoreSendsExplicitFalseTarget() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(completedDeliveryIDs: ["d1", "d2", "d3"]))
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()
        let delivery = try XCTUnwrap(session.snapshot?.week.deliveries.first(where: { $0.id == "d3" }))
        let mutation = MobileDeliveryMutation(deliveryID: delivery.id, token: UUID(), repositoryGeneration: session.repositoryGeneration)

        let result = await session.toggleDelivery(delivery, isCompleted: false, mutation: mutation)

        guard case .confirmed = result else { return XCTFail("expected confirmed restore") }
        XCTAssertEqual(fixture.deliveryTargets, [false])
        XCTAssertFalse(session.snapshot?.week.deliveries.first(where: { $0.id == "d3" })?.isCompleted ?? true)
        XCTAssertEqual(session.state, .online)
    }

    func testTimedOutWriteReconcilesAuthoritativeSuccess() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(), dropDeliveryResponseAfterApply: true)
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()
        let delivery = try XCTUnwrap(session.snapshot?.week.deliveries.first(where: { $0.id == "d3" }))
        let mutation = MobileDeliveryMutation(deliveryID: delivery.id, token: UUID(), repositoryGeneration: session.repositoryGeneration)

        let result = await session.toggleDelivery(delivery, isCompleted: true, mutation: mutation)

        guard case .confirmed = result else { return XCTFail("expected timeout reconciliation to confirm") }
        XCTAssertTrue(session.snapshot?.week.deliveries.first(where: { $0.id == "d3" })?.isCompleted == true)
        XCTAssertEqual(session.state, .online)
        XCTAssertNil(session.pendingToggleSyncIssue)
        XCTAssertEqual(fixture.readCounts.snapshot, 2)
    }

    func testTimetableSnapshotIsCachedAndLegacyHomeRemainsCompatible() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let timetable = TimetableSnapshot(
            status: .available,
            classLabel: "261 一班",
            termLabel: "2026-2027 秋季学期",
            referenceDate: "2026-08-19",
            teachingWeek: 1,
            weekLabel: "第1周",
            weekStartDate: "2026-08-17",
            firstImportedDate: "2026-08-17",
            lastImportedDate: "2027-01-03",
            days: [TimetableDaySnapshot(
                id: "2026-08-19",
                dateLabel: "8月19日 · 周三",
                week: 1,
                weekday: 4,
                weekdayLabel: "周三",
                entries: [TimetableEntrySnapshot(id: "class", kind: .course, title: "数据科学")]
            )]
        )
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(timetable: timetable))
        let session = makeSession(directory: directory, fixture: fixture)

        await session.refresh()
        XCTAssertEqual(session.snapshot?.home.timetable, timetable)

        let offline = MobileSession(cacheDirectory: directory)
        XCTAssertEqual(offline.state, .offline(lastUpdated: session.snapshot?.fetchedAt))
        XCTAssertEqual(offline.snapshot?.home.timetable, timetable)

        let legacyData = try JSONEncoder().encode(makeSnapshot())
        try legacyData.write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
        let legacy = MobileSession(cacheDirectory: directory)
        XCTAssertNil(legacy.snapshot?.home.timetable)
    }

    func testRefreshReplacesCachedPlanAndHomeFromOneSnapshot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cached = makeSnapshot()
        try JSONEncoder().encode(cached).write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)

        let refreshedPeriods = [
            PeriodSnapshot(id: "morning", title: "上午", text: "更新后的上午安排"),
            PeriodSnapshot(id: "noon", title: "中午", text: "更新后的中午安排"),
            PeriodSnapshot(id: "evening", title: "晚上", text: "更新后的晚上安排")
        ]
        let refreshedDeliveries = [
            DeliverySnapshot(id: "delivery-new", text: "更新后的学习交付物", isCompleted: false, dateLabel: "8月19日")
        ]
        let refreshed = SnapshotResponse(
            revision: "r1",
            fetchedAt: Date(timeIntervalSinceReferenceDate: 234_567),
            home: HomeSnapshot(
                dateLabel: "8月19日 · 周三",
                periods: refreshedPeriods,
                firstOpenTask: refreshedPeriods.first?.text,
                visibleDeliveries: refreshedDeliveries,
                completedDeliveries: 0,
                totalDeliveries: refreshedDeliveries.count
            ),
            week: WeeklyPlanSnapshot(
                days: [DaySnapshot(id: "2026-08-19", dateLabel: "8月19日 · 周三", slots: refreshedPeriods)],
                bufferRules: [BufferRuleSnapshot(id: "buffer", category: "daily", text: "更新后的日常缓冲")],
                deliveries: refreshedDeliveries
            ),
            daily: DailySnapshot(date: "2026-08-19"),
            summaries: []
        )
        let fixture = MobileSyncFixture(snapshot: refreshed)

        let offline = MobileSession(cacheDirectory: directory)
        XCTAssertEqual(offline.state, .offline(lastUpdated: cached.fetchedAt))
        XCTAssertEqual(offline.snapshot?.revision, cached.revision)

        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()

        XCTAssertEqual(session.state, .online)
        XCTAssertEqual(session.snapshot?.revision, refreshed.revision)
        XCTAssertEqual(session.snapshot?.fetchedAt, refreshed.fetchedAt)
        XCTAssertEqual(session.snapshot?.home.periods, session.snapshot?.week.days.first?.slots)
        XCTAssertEqual(session.snapshot?.home.visibleDeliveries, session.snapshot?.week.deliveries)
        XCTAssertEqual(session.snapshot?.home.completedDeliveries, session.snapshot?.week.deliveries.filter(\.isCompleted).count)
        XCTAssertEqual(session.snapshot?.home.totalDeliveries, session.snapshot?.week.deliveries.count)
        XCTAssertEqual(session.snapshot?.week.bufferRules.first?.text, "更新后的日常缓冲")
    }

    func testTimetableDocumentIsCachedForOfflineUse() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdown = """
        <!-- studyrocket:timetable:start -->
        | 字段 | 内容 |
        | --- | --- |
        | 班级 | 261 一班 |
        | 学期 | 2026-2027 秋季学期 |
        | 起始日期 | 2026-09-14 |
        | 结束日期 | 2027-01-03 |
        | 日期 | 周次 | 类型 | 开始 | 结束 | 节次 | 名称 | 地点 | 教师 | 备注 |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        | 2026-09-14 | 1 | 课程 | 08:00 | 09:30 | 1-2 | 数据科学导论 | 2-101 | 老师 |  |
        <!-- studyrocket:timetable:end -->
        """
        let document = DocumentDetail(
            documentKey: "timetable",
            title: "课表",
            markdown: markdown,
            revision: "timetable-r1",
            fetchedAt: Date(timeIntervalSinceReferenceDate: 123_456)
        )
        let fixture = MobileSyncFixture(
            snapshot: makeSnapshot(),
            documents: ["timetable": document]
        )
        let session = makeSession(directory: directory, fixture: fixture)

        let fetchedValue = await session.document(for: "timetable")
        let fetched = try XCTUnwrap(fetchedValue)
        XCTAssertEqual(fetched, document)
        XCTAssertEqual(session.documentDetails["timetable"], document)

        let offline = MobileSession(cacheDirectory: directory)
        let cachedValue = await offline.document(for: "timetable")
        let cached = try XCTUnwrap(cachedValue)
        XCTAssertEqual(cached, document)
        XCTAssertEqual(
            StudyRocketTimetableParser.teachingWeekRange(from: cached.markdown),
            1...16
        )
    }

    func testAssignUnassignedTaskPreservesExactTextAndWritesWeek() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = DaySnapshot(
            id: "2026-08-19",
            dateLabel: "8月19日 · 周三",
            slots: makeSnapshot().week.days[0].slots,
            unassigned: "14:05 领取 Bar Code"
        )
        let target = DaySnapshot(
            id: "2026-08-20",
            dateLabel: "8月20日 · 周四",
            slots: [
                PeriodSnapshot(id: "morning", title: "上午", text: "晨读"),
                PeriodSnapshot(id: "noon", title: "中午", text: ""),
                PeriodSnapshot(id: "evening", title: "晚上", text: ""),
            ]
        )
        let initial = makeSnapshot(days: [source, target])
        let fixture = MobileSyncFixture(snapshot: initial)
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()

        await session.assignUnassignedTask(
            sourceDayID: source.id,
            taskIndex: 0,
            text: "14:05 领取 Bar Code",
            targetDayID: target.id,
            targetPeriodID: "evening"
        )

        XCTAssertEqual(fixture.writePaths, ["/v1/week"])
        XCTAssertTrue(session.snapshot?.week.days[0].unassigned.isEmpty ?? false)
        XCTAssertEqual(session.snapshot?.week.days[1].slots[2].tasks.map(\.text), ["14:05 领取 Bar Code"])
    }

    func testReturnScheduledTaskToUnassignedKeepsOtherCompletionState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parsedTasks = PeriodTaskParser.tasks(from: "临时事项\n已完成事项")
        let periods = [
            PeriodSnapshot(
                id: "morning",
                title: "上午",
                text: "临时事项\n已完成事项",
                tasks: [
                    PeriodTaskSnapshot(id: parsedTasks[0].id, text: parsedTasks[0].text),
                    PeriodTaskSnapshot(id: parsedTasks[1].id, text: parsedTasks[1].text, isCompleted: true)
                ]
            ),
            PeriodSnapshot(id: "noon", title: "中午", text: ""),
            PeriodSnapshot(id: "evening", title: "晚上", text: ""),
        ]
        let fixture = MobileSyncFixture(snapshot: makeSnapshot(periods: periods))
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()
        let task = try XCTUnwrap(session.snapshot?.week.days[0].slots[0].tasks.first)

        await session.returnScheduledTaskToUnassigned(dayID: "2026-08-19", periodID: "morning", taskID: task.id)

        XCTAssertEqual(fixture.writePaths, ["/v1/week"])
        XCTAssertEqual(session.snapshot?.week.days[0].unassigned, "临时事项")
        XCTAssertEqual(session.snapshot?.week.days[0].slots[0].tasks.map(\.text), ["已完成事项"])
        XCTAssertTrue(session.snapshot?.week.days[0].slots[0].tasks[0].isCompleted ?? false)
    }

    func testOfflineAssignmentCreatesPendingWeekDraftAndReplays() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cached = makeSnapshot(days: [DaySnapshot(
            id: "2026-08-19",
            dateLabel: "8月19日 · 周三",
            slots: makeSnapshot().week.days[0].slots,
            unassigned: "领取资料"
        )])
        try JSONEncoder().encode(cached).write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
        let offline = MobileSession(cacheDirectory: directory)

        await offline.assignUnassignedTask(
            sourceDayID: "2026-08-19",
            taskIndex: 0,
            text: "领取资料",
            targetDayID: "2026-08-19",
            targetPeriodID: "noon"
        )
        XCTAssertNotNil(offline.pendingWeekDraft)

        let fixture = MobileSyncFixture(snapshot: cached)
        let online = makeSession(directory: directory, fixture: fixture)
        await online.refresh()
        await online.commitPendingDrafts()

        XCTAssertNil(online.pendingWeekDraft)
        XCTAssertEqual(fixture.writePaths, ["/v1/week"])
        XCTAssertEqual(online.snapshot?.week.days[0].slots[1].tasks.map(\.text), ["中午任务", "领取资料"])
    }

    func testPendingPlanDoesNotOverwriteNewerRevision() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cached = makeSnapshot()
        try JSONEncoder().encode(cached).write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
        let offline = MobileSession(cacheDirectory: directory)
        _ = await offline.saveWeek(cached.week)
        let newer = SnapshotResponse(revision: "r1", home: cached.home, week: cached.week, daily: cached.daily, summaries: cached.summaries)
        let fixture = MobileSyncFixture(snapshot: newer)
        let online = makeSession(directory: directory, fixture: fixture)
        await online.refresh()
        await online.commitPendingDrafts()
        XCTAssertNotNil(online.pendingWeekDraft)
        XCTAssertTrue(fixture.writePaths.isEmpty)
        XCTAssertTrue(online.pendingToggleSyncIssue?.contains("旧版本") == true)
        let saved = await online.saveWeek(cached.week, baseRevision: cached.revision)
        XCTAssertFalse(saved)
        XCTAssertNotNil(online.pendingWeekDraft)
        XCTAssertEqual(fixture.baseRevisions, [cached.revision])
        XCTAssertEqual(online.snapshot?.revision, newer.revision)
    }

    func testStableDeliveryQueueDistinguishesIdenticalTitlesAndLostReceipt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(), day = PlanningDate.key(now)
        let a = UUID().uuidString, b = UUID().uuidString
        let raw = WeeklyPlanSnapshot(days: [], bufferRules: [], deliveries: [
            DeliverySnapshot(id: a, text: "相同交付物", isCompleted: false),
            DeliverySnapshot(id: b, text: "相同交付物", isCompleted: false)])
        let graph = TaskLinkage(activationDate: day).reconciled(with: raw)
        let snapshot = MobileSyncFixture.withPlan(graph.projected(raw), source: makeSnapshot())
        let draft: [String: Any] = ["deliveries": [["deliveryID": a, "text": "相同交付物", "isCompleted": true, "idempotencyKey": "stable-receipt"]], "periods": []]
        try JSONSerialization.data(withJSONObject: draft).write(to: directory.appendingPathComponent("pending-drafts.json"))
        let fixture = MobileSyncFixture(snapshot: snapshot, dropDeliveryResponseAfterApply: true)
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh(); await session.commitPendingDrafts()
        XCTAssertEqual(session.pendingDeliveryCount, 0)
        XCTAssertTrue(fixture.snapshot.week.deliveries.first(where: { $0.id == a })!.isCompleted)
        XCTAssertFalse(fixture.snapshot.week.deliveries.first(where: { $0.id == b })!.isCompleted)
        XCTAssertEqual(fixture.writePaths.filter { $0 == "/v1/deliveries/toggle" }.count, 1)
    }

    func testOfflineStableTaskFollowsRescheduleAndRemainsIdempotent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let today = PlanningDate.key(.now)
        let later = PlanningDate.key(PlanningDate.calendar.date(byAdding: .day, value: 2, to: .now)!)
        let raw = WeeklyPlanSnapshot(days: [DaySnapshot(id: today, dateLabel: today, slots: [PeriodSnapshot(id: "morning", title: "上午", text: "高数作业")])], bufferRules: [], deliveries: [])
        var graph = TaskLinkage(activationDate: today).reconciled(with: raw)
        let task = graph.tasks[0], assignment = graph.assignments[0]
        try graph.reschedule(task.id, date: later, periodID: "evening")
        let draft: [String: Any] = ["deliveries": [], "periods": [["dayID": today, "periodID": "morning", "taskID": assignment.legacyTaskID, "logicalTaskID": task.id, "assignmentID": assignment.id, "isCompleted": true, "idempotencyKey": "stable-task"]]]
        try JSONSerialization.data(withJSONObject: draft).write(to: directory.appendingPathComponent("pending-drafts.json"))
        let fixture = MobileSyncFixture(snapshot: MobileSyncFixture.withPlan(graph.projected(raw), source: makeSnapshot()))
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh(); await session.commitPendingDrafts()
        XCTAssertEqual(session.pendingPeriodCount, 0)
        XCTAssertTrue(fixture.snapshot.week.linkage!.tasks.first(where: { $0.id == task.id })!.isCompleted)
        XCTAssertEqual(fixture.linkedPeriodRequests.first?.assignmentID, assignment.id)
        XCTAssertEqual(fixture.linkedPeriodRequests.first?.logicalTaskID, task.id)
        await session.refresh(); await session.commitPendingDrafts()
        XCTAssertEqual(fixture.linkedPeriodRequests.count, 1)
    }

    func testPersistedChatIDsClearOnlyForKnownTerminalTurns() async throws {
        for status in ["completed", "failed", "interrupted", "inProgress", "unknown"] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = MobileSyncFixture(snapshot: makeSnapshot())
            let session = makeSession(directory: directory, fixture: fixture)
            await session.refresh()
            session.inputDraft = ""
            let operationID = UUID().uuidString
            let pending = directory.appendingPathComponent("pending-cloud-chats.json")
            try JSONSerialization.data(withJSONObject: [["id": operationID, "text": "synthetic pending chat", "endpoint": "https://studyrocket.test", "repositoryID": "repo-test"]]).write(to: pending)
            MobileStubURLProtocol.handler = { request in
                if request.url?.path == "/v1/chat/history" {
                    let terminal = ChatTurnTerminalDTO(turnID: operationID, status: status)
                    let response = ChatHistoryResponse(revision: "fixture", messages: [], terminalTurns: [terminal])
                    return MobileStubResponse(statusCode: 200, data: try JSONEncoder().encode(response))
                }
                return try fixture.response(for: request)
            }
            await session.refreshChat()
            let remaining = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: pending)) as? [[String: Any]])
            let knownTerminal = ["completed", "failed", "interrupted"].contains(status)
            XCTAssertEqual(remaining.isEmpty, knownTerminal, "Only authoritative terminal state may release the original idempotency key: " + status)
            if !knownTerminal { XCTAssertEqual(remaining.first?["id"] as? String, operationID); XCTAssertEqual(session.inputDraft, "synthetic pending chat") }
        }
    }

    func testDailyOfflineDraftKeepsOriginalCASAndOperationAcrossConflictAndRelaunch() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let cached = makeSnapshot()
        try JSONEncoder().encode(cached).write(to: directory.appendingPathComponent("snapshot.json"))
        let offline = MobileSession(cacheDirectory: directory)
        let draft = DailySnapshot(date: cached.daily.date, deliverables: "offline A")
        await offline.saveDaily(draft)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("pending-drafts.json"))) as? [String: Any])
        let operation = try XCTUnwrap(stored["dailyOperationID"] as? String)
        XCTAssertEqual(stored["dailyBaseRevision"] as? String, "r0")
        let other = DailySnapshot(date: cached.daily.date, deliverables: "other device B")
        let newer = SnapshotResponse(revision: "r1", home: cached.home, week: cached.week, daily: other, summaries: [])
        let fixture = MobileSyncFixture(snapshot: newer)
        let online = makeSession(directory: directory, fixture: fixture)
        await online.refresh(); await online.commitPendingDrafts()
        XCTAssertEqual(fixture.snapshot.daily, other)
        XCTAssertEqual(online.pendingDailyDraft, draft)
        XCTAssertEqual(online.state, .online)
        let relaunched = makeSession(directory: directory, fixture: fixture)
        await relaunched.refresh(); await relaunched.commitPendingDrafts()
        XCTAssertEqual(fixture.dailyRequests.count, 2)
        XCTAssertEqual(fixture.dailyRequests.map { $0.metadata.baseRevision }, ["r0", "r0"])
        XCTAssertEqual(fixture.dailyRequests.map { $0.metadata.idempotencyKey }, [operation, operation])
        XCTAssertEqual(fixture.snapshot.daily, other)
    }

    func testLegacyDailyWithoutBaseNeverSubmits() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let current = makeSnapshot()
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current.daily))
        try JSONSerialization.data(withJSONObject: ["daily": object, "deliveries": [], "periods": []]).write(to: directory.appendingPathComponent("pending-drafts.json"))
        let fixture = MobileSyncFixture(snapshot: current)
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh(); await session.commitPendingDrafts()
        XCTAssertTrue(fixture.dailyRequests.isEmpty)
        XCTAssertNotNil(session.pendingDailyDraft)
        XCTAssertTrue(session.pendingPlanComparison.contains("不可直接提交"))
    }

    func testFirstCloudMigrationRequiresMappingAndPreservedContentBeforeSingleItemCAS() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let old = makeSnapshot()
        try JSONEncoder().encode(old).write(to: directory.appendingPathComponent("snapshot.json"))
        UserDefaults.standard.set("legacy-root-hash", forKey: "studyrocket.repositoryID")
        let operation = UUID().uuidString
        let draft: [String: Any] = ["deliveries": [["deliveryID": "d3", "text": "交付物 3", "isCompleted": true, "idempotencyKey": operation]], "periods": []]
        try JSONSerialization.data(withJSONObject: draft).write(to: directory.appendingPathComponent("pending-drafts.json"))
        let cloud = SnapshotResponse(revision: "cloud-uuid-revision", home: old.home, week: old.week, daily: old.daily, summaries: [])
        let fixture = MobileSyncFixture(snapshot: cloud)
        fixture.legacyRepositoryID = "unrelated-hash"
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()
        let archive = try XCTUnwrap(session.preservedQueues.first)
        XCTAssertEqual(try JSONDecoder().decode(SnapshotResponse.self, from: XCTUnwrap(archive.cachedSnapshot)), old)
        XCTAssertFalse(try XCTUnwrap(session.queueMigrationItems(archive).first).canSubmit)
        XCTAssertTrue(fixture.writePaths.isEmpty)
        fixture.legacyRepositoryID = "legacy-root-hash"
        await session.refresh()
        XCTAssertTrue(try XCTUnwrap(session.queueMigrationItems(archive).first).canSubmit)
        try await session.submitQueueMigrationItem(archive, itemID: "delivery:0")
        XCTAssertEqual(fixture.migratedDeliveryRequests.first?.metadata.idempotencyKey, operation)
        XCTAssertEqual(fixture.migratedDeliveryRequests.first?.metadata.baseRevision, "cloud-uuid-revision")
        XCTAssertTrue(fixture.snapshot.week.deliveries.first { $0.id == "d3" }!.isCompleted)
        XCTAssertFalse(try XCTUnwrap(session.queueMigrationItems(archive).first).canSubmit)
        XCTAssertEqual(session.preservedQueues.first?.drafts, archive.drafts)
    }

    func testFirstCloudMigrationMissingCacheOrChangedContentStaysReadOnly() async throws {
        for hasCache in [false, true] {
            let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
            let old = makeSnapshot()
            if hasCache { try JSONEncoder().encode(old).write(to: directory.appendingPathComponent("snapshot.json")) }
            UserDefaults.standard.set("legacy-root-hash", forKey: "studyrocket.repositoryID")
            let plan = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old.week))
            try JSONSerialization.data(withJSONObject: ["week": plan, "deliveries": [["deliveryID": "d3", "text": "交付物 3", "isCompleted": true, "idempotencyKey": UUID().uuidString]], "periods": []]).write(to: directory.appendingPathComponent("pending-drafts.json"))
            let changed = makeSnapshot(periods: [PeriodSnapshot(id: "morning", title: "上午", text: "changed content")])
            let fixture = MobileSyncFixture(snapshot: changed); fixture.legacyRepositoryID = "legacy-root-hash"
            let session = makeSession(directory: directory, fixture: fixture)
            await session.refresh()
            let archive = try XCTUnwrap(session.preservedQueues.first)
            XCTAssertTrue(session.queueMigrationItems(archive).allSatisfy { !$0.canSubmit })
            do { try await session.submitQueueMigrationItem(archive, itemID: "delivery:0"); XCTFail("Changed/unknown baseline must not write") } catch {}
            XCTAssertTrue(fixture.writePaths.isEmpty)
        }
    }

    func testLegacyFactMigrationPreservesUUIDAcrossLostReceiptAndNeedsExplicitReview() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        UserDefaults.standard.set("legacy-root-hash", forKey: "studyrocket.repositoryID")
        let fact = QuickFact(date: "2026-08-19", text: "synthetic migrated fact")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fact))
        try JSONSerialization.data(withJSONObject: [["repositoryID": "legacy-root-hash", "endpoint": "https://studyrocket.test", "fact": object]]).write(to: directory.appendingPathComponent("pending-facts.json"))
        let fixture = MobileSyncFixture(snapshot: makeSnapshot()); fixture.legacyRepositoryID = "legacy-root-hash"
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()
        let archive = try XCTUnwrap(session.preservedQueues.first)
        XCTAssertTrue(fixture.factRequests.isEmpty, "Mapping must never auto-replay old queue")
        let itemID = "fact:" + fact.id.uuidString
        XCTAssertTrue(try XCTUnwrap(session.queueMigrationItems(archive).first).canSubmit)
        do { try await session.submitQueueMigrationItem(archive, itemID: itemID); XCTFail("First receipt is deliberately lost") } catch {}
        XCTAssertTrue(try XCTUnwrap(session.queueMigrationItems(archive).first).canSubmit)
        try await session.submitQueueMigrationItem(archive, itemID: itemID)
        XCTAssertEqual(fixture.factRequests.map { $0.entry }, [fact, fact])
        XCTAssertEqual(fixture.factRequests.map { $0.metadata.idempotencyKey }, [fact.id.uuidString, fact.id.uuidString])
        XCTAssertEqual(fixture.factRequests.map { $0.repositoryID }, ["repo-test", "repo-test"])
        XCTAssertFalse(try XCTUnwrap(session.queueMigrationItems(archive).first).canSubmit)
        XCTAssertEqual(fixture.snapshot.recentFacts, [fact])
        let relaunched = makeSession(directory: directory, fixture: fixture)
        await relaunched.refresh()
        XCTAssertFalse(try XCTUnwrap(relaunched.queueMigrationItems(archive).first).canSubmit, "Receipt survives restart")
    }

    func testStablePeriodMigrationUsesOriginalTaskIDAndExplicitTarget() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let old = makeSnapshot()
        let task = try XCTUnwrap(old.week.days.first?.slots.first?.tasks.first)
        try JSONEncoder().encode(old).write(to: directory.appendingPathComponent("snapshot.json"))
        UserDefaults.standard.set("legacy-root-hash", forKey: "studyrocket.repositoryID")
        let operation = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ["deliveries": [], "periods": [["dayID": "2026-08-19", "periodID": "morning", "taskID": task.id, "isCompleted": true, "idempotencyKey": operation]]]).write(to: directory.appendingPathComponent("pending-drafts.json"))
        let cloud = SnapshotResponse(revision: "cloud-new-identity", home: old.home, week: old.week, daily: old.daily, summaries: [])
        let fixture = MobileSyncFixture(snapshot: cloud); fixture.legacyRepositoryID = "legacy-root-hash"
        let session = makeSession(directory: directory, fixture: fixture)
        await session.refresh()
        let archive = try XCTUnwrap(session.preservedQueues.first)
        XCTAssertTrue(try XCTUnwrap(session.queueMigrationItems(archive).first).canSubmit)
        try await session.submitQueueMigrationItem(archive, itemID: "period:0")
        XCTAssertTrue(fixture.snapshot.week.days[0].slots[0].tasks.first { $0.id == task.id }!.isCompleted)
        XCTAssertEqual(fixture.baseRevisions, ["cloud-new-identity"])
        XCTAssertFalse(try XCTUnwrap(session.queueMigrationItems(archive).first).canSubmit)
    }

    private func timedSnapshot(revision: String, timestamp: TimeInterval, label: String) -> SnapshotResponse {
        let base = makeSnapshot()
        let home = HomeSnapshot(dateLabel: label,
            periods: [PeriodSnapshot(id: "morning", title: "上午", text: revision)],
            firstOpenTask: revision, visibleDeliveries: base.home.visibleDeliveries,
            completedDeliveries: revision.hasPrefix("old") ? 2 : 4, totalDeliveries: 5)
        return SnapshotResponse(revision: revision, fetchedAt: Date(timeIntervalSince1970: timestamp),
            home: home, week: base.week, daily: base.daily, summaries: [])
    }

    private func makeSession(
        directory: URL,
        fixture: MobileSyncFixture,
        chatRecoveryDelays: [Duration]? = nil,
        eventStreamsEnabled: Bool = false
    ) -> MobileSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MobileStubURLProtocol.self]
        MobileStubURLProtocol.handler = fixture.response
        let remote = StudyRocketRemoteClient(
            endpoint: URL(string: "https://studyrocket.test")!,
            session: URLSession(configuration: configuration)
        )
        if let chatRecoveryDelays {
            return MobileSession(
                cacheDirectory: directory,
                client: remote,
                eventStreamsEnabled: eventStreamsEnabled,
                chatRecoveryDelays: chatRecoveryDelays
            )
        }
        return MobileSession(cacheDirectory: directory, client: remote, eventStreamsEnabled: eventStreamsEnabled)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSessionSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeDrafts(
        directory: URL,
        legacy: Bool,
        deliveryTexts: [String] = ["交付物 3", "交付物 4", "交付物 5"],
        periodIDs: [String] = ["morning", "noon"],
        includeDaily: Bool = true
    ) throws {
        let periods = [
            "morning": "上午任务",
            "noon": "中午任务",
            "evening": "晚上任务"
        ]
        let deliveries: [[String: Any]] = deliveryTexts.enumerated().map { index, text in
            var value: [String: Any] = ["text": text, "isCompleted": true]
            if !legacy { value["idempotencyKey"] = "delivery-key-\(index)" }
            return value
        }
        let periodDrafts: [[String: Any]] = periodIDs.enumerated().map { index, id in
            var value: [String: Any] = [
                "dayID": "2026-08-19",
                "periodID": id,
                "isCompleted": true
            ]
            if legacy {
                value["textHash"] = PeriodCompletion.textHash(for: periods[id]!)
            } else {
                value["taskID"] = PeriodTaskParser.tasks(from: periods[id]!)[0].id
                value["idempotencyKey"] = "period-key-\(index)"
            }
            return value
        }
        var payload: [String: Any] = [
            "deliveries": deliveries,
            "periods": periodDrafts
        ]
        if includeDaily {
            payload["daily"] = [
                "date": "2026-08-19",
                "deliverables": "待确认日结",
                "studyTime": "",
                "sleep": "",
                "exercise": "",
                "firstTask": ""
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("pending-drafts.json"), options: .atomic)
    }

    private func makeSnapshot(
        completedDeliveryIDs: Set<String> = ["d1", "d2"],
        timetable: TimetableSnapshot? = nil,
        periods: [PeriodSnapshot]? = nil,
        days: [DaySnapshot]? = nil
    ) -> SnapshotResponse {
        let periods = periods ?? [
            PeriodSnapshot(id: "morning", title: "上午", text: "上午任务"),
            PeriodSnapshot(id: "noon", title: "中午", text: "中午任务"),
            PeriodSnapshot(id: "evening", title: "晚上", text: "晚上任务")
        ]
        let deliveries = (1...5).map { index in
            DeliverySnapshot(
                id: "d\(index)",
                text: "交付物 \(index)",
                isCompleted: completedDeliveryIDs.contains("d\(index)"),
                dateLabel: "8月\(16 + index)日"
            )
        }
        let days = days ?? [DaySnapshot(id: "2026-08-19", dateLabel: "8月19日 · 周三", slots: periods)]
        return SnapshotResponse(
            revision: "r0",
            home: HomeSnapshot(
                dateLabel: "8月19日 · 周三",
                periods: periods,
                firstOpenTask: periods.lazy.flatMap(\.tasks).first(where: { !$0.isCompleted })?.text,
                visibleDeliveries: deliveries,
                completedDeliveries: deliveries.filter(\.isCompleted).count,
                totalDeliveries: deliveries.count,
                timetable: timetable
            ),
            week: WeeklyPlanSnapshot(
                days: days,
                bufferRules: [],
                deliveries: deliveries
            ),
            daily: DailySnapshot(date: "2026-08-19"),
            summaries: []
        )
    }
}

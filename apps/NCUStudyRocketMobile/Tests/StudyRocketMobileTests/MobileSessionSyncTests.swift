import Foundation
import XCTest
@testable import StudyRocketMobile
import StudyRocketShared

private struct MobileStubResponse {
    let statusCode: Int
    let data: Data
}

private final class MobileStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> MobileStubResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let stub = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
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
    private var healthReads = 0
    private var snapshotReads = 0
    private var chatHistoryReads = 0
    private var acceptedChatText: String?
    private let chatCompletionAfterHistoryReads: Int?
    private(set) var writePaths: [String] = []
    private(set) var baseRevisions: [String] = []
    private(set) var deliveryTargets: [Bool] = []

    init(
        snapshot: SnapshotResponse,
        forcedDeliveryError: APIErrorBody? = nil,
        dropDeliveryResponseAfterApply: Bool = false,
        documents: [String: DocumentDetail] = [:],
        chatCompletionAfterHistoryReads: Int? = nil
    ) {
        authoritative = snapshot
        self.forcedDeliveryError = forcedDeliveryError
        self.dropDeliveryResponseAfterApply = dropDeliveryResponseAfterApply
        self.documents = documents
        self.chatCompletionAfterHistoryReads = chatCompletionAfterHistoryReads
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
                repositoryBound: true,
                codexReady: true,
                pairedDeviceCount: 1,
                activeThreadID: "academic",
                repositoryID: "repo-test",
                dynamicToolsReady: true
            )))
        case ("GET", "/v1/snapshot"):
            snapshotReads += 1
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
            acceptedChatText = try JSONDecoder().decode(SendChatRequest.self, from: Self.bodyData(for: request)).text
            chatHistoryReads = 0
            return MobileStubResponse(statusCode: 202, data: try encoder.encode(ChatHistoryResponse(revision: "0", messages: [])))
        case ("GET", "/v1/chat/history"):
            guard let text = acceptedChatText, let completionRead = chatCompletionAfterHistoryReads else {
                return MobileStubResponse(statusCode: 200, data: try encoder.encode(ChatHistoryResponse(revision: "0", messages: [])))
            }
            chatHistoryReads += 1
            let isComplete = chatHistoryReads >= completionRead
            let date = Date(timeIntervalSinceReferenceDate: 123_456)
            let status = isComplete ? "completed" : "inProgress"
            var messages = [ChatMessageDTO(id: "user-1", role: "user", text: text, date: date, turnID: "turn-1", status: status)]
            if isComplete {
                messages.append(ChatMessageDTO(id: "assistant-1", role: "assistant", text: "已恢复的回复", date: date.addingTimeInterval(1), turnID: "turn-1", phase: "final_answer", status: "completed"))
            }
            return MobileStubResponse(statusCode: 200, data: try encoder.encode(ChatHistoryResponse(revision: "\(chatHistoryReads)", messages: messages)))
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
            record(path: path, revision: value.metadata.baseRevision)
            deliveryTargets.append(value.isCompleted)
            guard value.metadata.baseRevision == authoritative.revision else {
                return MobileStubResponse(
                    statusCode: 409,
                    data: try encoder.encode(APIErrorBody(code: "conflict", message: "revision conflict", retryable: true))
                )
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
    }

    override func tearDown() {
        MobileStubURLProtocol.handler = nil
        super.tearDown()
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

    private func makeSession(
        directory: URL,
        fixture: MobileSyncFixture,
        chatRecoveryDelays: [Duration]? = nil
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
                eventStreamsEnabled: false,
                chatRecoveryDelays: chatRecoveryDelays
            )
        }
        return MobileSession(cacheDirectory: directory, client: remote, eventStreamsEnabled: false)
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

import CryptoKit
import Darwin
import Foundation
import StudyRocketShared

@main
struct StudyRocketSelfCheckHTTPChecks {
    static func main() async {
        do {
            try await run()
            print("StudyRocketSelfCheckHTTPChecks: paired HTTP, signed writes, SSE, replay and conflict checks passed")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        guard let configuration = StudyRocketSelfCheckConfiguration.current else {
            throw SelfCheckFailure("缺少有效的 --studyrocket-self-check 隔离配置。")
        }

        let runner = HTTPCheckRunner(configuration: configuration)
        let publicHealth = try await runner.perform(method: "GET", path: "/v1/health", signed: false)
        try require(publicHealth.statusCode == 200, "未认证 health 没有返回 200")
        let publicObject = try jsonObject(publicHealth.body)
        try require(publicObject["pairedDeviceCount"] == nil, "未认证 health 泄露了配对设备数量")
        try require(publicObject["repositoryID"] == nil, "未认证 health 泄露了仓库标识")

        let code = try await pairingCode(at: configuration.pairingCodeURL)
        let key = P256.Signing.PrivateKey()
        let pairBody = try JSONEncoder().encode(PairRequest(
            code: code,
            deviceName: "StudyRocket SelfCheck",
            publicKey: key.publicKey.rawRepresentation.base64EncodedString()
        ))
        let pairResponse = try await runner.perform(method: "POST", path: "/v1/pair", body: pairBody, signed: false)
        try require(pairResponse.statusCode == 200, "一次性配对失败")
        let paired = try JSONDecoder().decode(PairResponse.self, from: pairResponse.body)
        runner.setIdentity(deviceID: paired.deviceID, privateKey: key)

        let repeatedPair = try await runner.perform(method: "POST", path: "/v1/pair", body: pairBody, signed: false)
        try require(repeatedPair.statusCode == 401, "已使用的配对码仍可重复使用")

        let unsignedSnapshot = try await runner.perform(method: "GET", path: "/v1/snapshot", signed: false)
        try require(unsignedSnapshot.statusCode == 401, "未签名 snapshot 没有被拒绝")

        let firstSnapshot = try await runner.snapshot()
        try require(!firstSnapshot.week.days.isEmpty, "隔离 fixture 没有生成周计划日期")

        let replayNonce = UUID().uuidString
        let firstSigned = try await runner.perform(method: "GET", path: "/v1/snapshot", nonce: replayNonce)
        try require(firstSigned.statusCode == 200, "首个签名 snapshot 失败")
        let replayedNonce = try await runner.perform(method: "GET", path: "/v1/snapshot", nonce: replayNonce)
        try require(replayedNonce.statusCode == 401, "重复 nonce 没有被拒绝")

        let streamEvents = try await runner.eventsThroughHeartbeat()
        try require(streamEvents.contains(where: { $0.kind == "snapshot" }), "SSE 没有返回初始 snapshot")
        try require(streamEvents.contains(where: { $0.kind == "heartbeat" }), "SSE 没有返回 heartbeat")

        guard let targetDay = firstSnapshot.week.days.first else {
            throw SelfCheckFailure("周计划没有可写入日期。")
        }
        let updatedDay = DaySnapshot(
            id: targetDay.id,
            dateLabel: targetDay.dateLabel,
            slots: [
                PeriodSnapshot(id: "morning", title: "上午", text: "隔离多任务甲\n隔离多任务乙"),
                PeriodSnapshot(id: "noon", title: "中午", text: "隔离周计划写入"),
                PeriodSnapshot(id: "evening", title: "晚上", text: "")
            ],
            unassigned: "隔离待分时事项"
        )
        let updatedDays = [updatedDay] + firstSnapshot.week.days.dropFirst()
        let plan = WeeklyPlanSnapshot(
            days: updatedDays,
            bufferRules: firstSnapshot.week.bufferRules,
            deliveries: firstSnapshot.week.deliveries,
            historicalRows: firstSnapshot.week.historicalRows,
            futureRows: firstSnapshot.week.futureRows
        )
        let planRequest = PlanWriteRequest(
            plan: plan,
            metadata: WriteMetadata(baseRevision: firstSnapshot.revision, idempotencyKey: "self-check-week-write")
        )
        let planPayload = try JSONEncoder().encode(planRequest)
        let appliedPlanResponse = try await runner.perform(method: "POST", path: "/v1/week", body: planPayload)
        try require(appliedPlanResponse.statusCode == 200, "周计划写入失败")
        let appliedPlan = try JSONDecoder().decode(SnapshotResponse.self, from: appliedPlanResponse.body)
        let appliedDay = appliedPlan.week.days.first(where: { $0.id == targetDay.id })
        try require(appliedDay?.slots.first?.tasks.count == 2, "同一时段多任务没有保留")
        try require(appliedDay?.unassigned == "隔离待分时事项", "待分时事项没有保留")

        let planReplay = try await runner.perform(method: "POST", path: "/v1/week", body: planPayload)
        try require(planReplay.statusCode == 200, "周计划幂等回放失败")
        let replayedPlan = try JSONDecoder().decode(SnapshotResponse.self, from: planReplay.body)
        try require(replayedPlan == appliedPlan, "周计划幂等回放未返回原响应")

        guard let delivery = appliedPlan.week.deliveries.first(where: { !$0.isCompleted }) else {
            throw SelfCheckFailure("隔离 fixture 缺少未完成交付物。")
        }
        let deliveryRequest = DeliveryToggleRequest(
            text: delivery.text,
            isCompleted: true,
            metadata: WriteMetadata(baseRevision: appliedPlan.revision, idempotencyKey: "self-check-delivery-toggle")
        )
        let deliveryResponse = try await runner.perform(
            method: "POST",
            path: "/v1/deliveries/toggle",
            body: try JSONEncoder().encode(deliveryRequest)
        )
        try require(deliveryResponse.statusCode == 200, "交付物完成写入失败")
        let delivered = try JSONDecoder().decode(SnapshotResponse.self, from: deliveryResponse.body)
        try require(delivered.week.deliveries.contains(where: { $0.text == delivery.text && $0.isCompleted }), "交付物完成状态未写入")

        let staleRequest = DeliveryToggleRequest(
            text: delivery.text,
            isCompleted: false,
            metadata: WriteMetadata(baseRevision: appliedPlan.revision, idempotencyKey: "self-check-stale-revision")
        )
        let staleResponse = try await runner.perform(
            method: "POST",
            path: "/v1/deliveries/toggle",
            body: try JSONEncoder().encode(staleRequest)
        )
        try require(staleResponse.statusCode == 409, "陈旧 revision 没有返回 409")

        let invalidDelivery = DeliveryToggleRequest(
            text: "不存在的隔离交付物",
            isCompleted: true,
            metadata: WriteMetadata(baseRevision: delivered.revision, idempotencyKey: "self-check-invalid-delivery")
        )
        let invalidDeliveryResponse = try await runner.perform(
            method: "POST",
            path: "/v1/deliveries/toggle",
            body: try JSONEncoder().encode(invalidDelivery)
        )
        try require(invalidDeliveryResponse.statusCode == 422, "无效交付物没有返回 422")

        let fixturePlanURL = configuration.repositoryRoot.appendingPathComponent("工作台/下周计划.md")
        let sourceBeforeRejectedWrite = try Data(contentsOf: fixturePlanURL)
        let markerDay = DaySnapshot(
            id: targetDay.id,
            dateLabel: targetDay.dateLabel,
            slots: [
                PeriodSnapshot(id: "morning", title: "上午", text: "<!-- studyrocket:weekly:start -->"),
                PeriodSnapshot(id: "noon", title: "中午", text: ""),
                PeriodSnapshot(id: "evening", title: "晚上", text: "")
            ]
        )
        let markerPlan = WeeklyPlanSnapshot(
            days: [markerDay] + delivered.week.days.dropFirst(),
            bufferRules: delivered.week.bufferRules,
            deliveries: delivered.week.deliveries,
            historicalRows: delivered.week.historicalRows,
            futureRows: delivered.week.futureRows
        )
        let markerRequest = PlanWriteRequest(
            plan: markerPlan,
            metadata: WriteMetadata(baseRevision: delivered.revision, idempotencyKey: "self-check-marker-injection")
        )
        let markerResponse = try await runner.perform(
            method: "POST",
            path: "/v1/week",
            body: try JSONEncoder().encode(markerRequest)
        )
        try require(markerResponse.statusCode == 422, "管理标记注入没有返回 422")
        let sourceAfterRejectedWrite = try Data(contentsOf: fixturePlanURL)
        try require(sourceAfterRejectedWrite == sourceBeforeRejectedWrite, "被拒绝的写入仍然改动了 fixture")

        let dailyRequest = DailyWriteRequest(
            entry: DailySnapshot(
                date: delivered.daily.date,
                deliverables: "隔离每日行为账",
                studyTime: "90 分钟",
                sleep: "23:30-07:00",
                exercise: "步行 20 分钟",
                firstTask: "隔离次日第一任务"
            ),
            metadata: WriteMetadata(baseRevision: delivered.revision, idempotencyKey: "self-check-daily-write")
        )
        let dailyResponse = try await runner.perform(
            method: "POST",
            path: "/v1/daily",
            body: try JSONEncoder().encode(dailyRequest)
        )
        try require(dailyResponse.statusCode == 200, "每日行为账写入失败")
        let dailySnapshot = try JSONDecoder().decode(SnapshotResponse.self, from: dailyResponse.body)
        try require(dailySnapshot.daily.deliverables == "隔离每日行为账", "每日行为账内容未写入")

        guard let periodDay = dailySnapshot.week.days.first(where: { $0.id == targetDay.id }),
              let morning = periodDay.slots.first(where: { $0.id == "morning" }),
              let task = morning.tasks.first else {
            throw SelfCheckFailure("写入后的上午任务不可用。")
        }
        let periodRequest = PeriodCompletionToggleRequest(
            dayID: periodDay.id,
            periodID: morning.id,
            taskID: task.id,
            isCompleted: true,
            metadata: WriteMetadata(baseRevision: dailySnapshot.revision, idempotencyKey: "self-check-period-toggle")
        )
        let periodResponse = try await runner.perform(
            method: "POST",
            path: "/v1/periods/toggle",
            body: try JSONEncoder().encode(periodRequest)
        )
        try require(periodResponse.statusCode == 200, "单项时段完成写入失败")
        let completedPeriod = try JSONDecoder().decode(SnapshotResponse.self, from: periodResponse.body)
        let finalMorning = completedPeriod.week.days.first(where: { $0.id == targetDay.id })?.slots.first(where: { $0.id == "morning" })
        try require(finalMorning?.tasks.first(where: { $0.id == task.id })?.isCompleted == true, "单项时段完成状态未写入")
        try require(finalMorning?.tasks.count == 2, "单项时段操作错误影响了其他任务")
    }

    private static func pairingCode(at url: URL) async throws -> String {
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: url),
               let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               value.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil {
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
                try require((permissions & 0o077) == 0, "隔离配对码文件权限不是 0600")
                return value
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SelfCheckFailure("隔离 Host 没有写入一次性配对码。")
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SelfCheckFailure("HTTP 响应不是 JSON 对象。")
        }
        return object
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SelfCheckFailure(message) }
    }
}

private final class HTTPCheckRunner: @unchecked Sendable {
    struct Response {
        let body: Data
        let statusCode: Int
    }

    private let configuration: StudyRocketSelfCheckConfiguration
    private let baseURL: URL
    private let session: URLSession
    private var identity: (deviceID: String, privateKey: P256.Signing.PrivateKey)?

    init(configuration: StudyRocketSelfCheckConfiguration) {
        self.configuration = configuration
        baseURL = URL(string: "http://127.0.0.1:\(configuration.port)")!
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        // The Host deliberately emits SSE heartbeats every 20 seconds, so the
        // stream request must outlive a normal idle heartbeat interval.
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 35
        session = URLSession(configuration: sessionConfiguration)
    }

    func setIdentity(deviceID: String, privateKey: P256.Signing.PrivateKey) {
        identity = (deviceID, privateKey)
    }

    func snapshot() async throws -> SnapshotResponse {
        let response = try await perform(method: "GET", path: "/v1/snapshot")
        guard response.statusCode == 200 else {
            throw SelfCheckFailure("已签名 snapshot 返回 HTTP \(response.statusCode)。")
        }
        return try JSONDecoder().decode(SnapshotResponse.self, from: response.body)
    }

    func perform(
        method: String,
        path: String,
        body: Data = Data(),
        signed: Bool = true,
        nonce: String? = nil
    ) async throws -> Response {
        let request = try makeRequest(method: method, path: path, body: body, signed: signed, nonce: nonce)
        let (responseBody, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SelfCheckFailure("Host 返回了非 HTTP 响应。")
        }
        return Response(body: responseBody, statusCode: http.statusCode)
    }

    func eventsThroughHeartbeat() async throws -> [HostEventEnvelope] {
        var request = try makeRequest(method: "GET", path: "/v1/events", body: Data(), signed: true, nonce: nil)
        request.timeoutInterval = 30
        let session = session
        return try await withThrowingTaskGroup(of: [HostEventEnvelope].self) { group in
            group.addTask {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw SelfCheckFailure("SSE 没有返回 200。")
                }
                var events: [HostEventEnvelope] = []
                for try await line in bytes.lines where line.hasPrefix("data: ") {
                    let data = Data(line.dropFirst(6).utf8)
                    guard let event = try? JSONDecoder().decode(HostEventEnvelope.self, from: data) else { continue }
                    events.append(event)
                    if events.contains(where: { $0.kind == "snapshot" }) && events.contains(where: { $0.kind == "heartbeat" }) {
                        return events
                    }
                }
                throw SelfCheckFailure("SSE 在收到 heartbeat 前结束。")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 28_000_000_000)
                throw SelfCheckFailure("等待 SSE heartbeat 超时。")
            }
            guard let result = try await group.next() else {
                throw SelfCheckFailure("无法读取 SSE 结果。")
            }
            group.cancelAll()
            return result
        }
    }

    private func makeRequest(
        method: String,
        path: String,
        body: Data,
        signed: Bool,
        nonce: String?
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw SelfCheckFailure("无效 HTTP 路径。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body.isEmpty ? nil : body
        if !body.isEmpty { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        guard signed else { return request }
        guard let identity else { throw SelfCheckFailure("HTTP 检查尚未完成配对。") }
        let resolvedNonce = nonce ?? UUID().uuidString
        let timestamp = Int64(Date().timeIntervalSince1970)
        let signature = try RequestSigning.sign(
            privateKey: identity.privateKey,
            method: method,
            path: path,
            timestamp: timestamp,
            nonce: resolvedNonce,
            bodyHash: RequestSigning.bodyHash(body)
        )
        request.setValue(identity.deviceID, forHTTPHeaderField: "X-StudyRocket-Device")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-StudyRocket-Timestamp")
        request.setValue(resolvedNonce, forHTTPHeaderField: "X-StudyRocket-Nonce")
        request.setValue(signature, forHTTPHeaderField: "X-StudyRocket-Signature")
        return request
    }
}

private struct SelfCheckFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

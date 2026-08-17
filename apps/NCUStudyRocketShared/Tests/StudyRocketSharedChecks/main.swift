import Foundation
import CryptoKit
import StudyRocketShared

let privateKey = P256.Signing.PrivateKey()
let timestamp = Int64(Date().timeIntervalSince1970)
let body = Data("studyrocket-check".utf8)
let bodyHash = RequestSigning.bodyHash(body)
let signature = RequestSigning.sign(privateKey: privateKey, method: "POST", path: "/v1/check", timestamp: timestamp, nonce: "test-nonce", bodyHash: bodyHash)
precondition(RequestSigning.verify(publicKeyData: privateKey.publicKey.rawRepresentation, signatureBase64: signature, method: "POST", path: "/v1/check", timestamp: timestamp, nonce: "test-nonce", bodyHash: bodyHash))
let challenge = UUID().uuidString
let authorizationSignature = RequestSigning.signAuthorization(privateKey: privateKey, challenge: challenge)
precondition(RequestSigning.verifyAuthorization(publicKeyData: privateKey.publicKey.rawRepresentation, signatureBase64: authorizationSignature, challenge: challenge))
precondition(!RequestSigning.verifyAuthorization(publicKeyData: privateKey.publicKey.rawRepresentation, signatureBase64: authorizationSignature, challenge: UUID().uuidString))

let request = SendChatRequest(text: "测试")
let encoded = try JSONEncoder().encode(request)
let decoded = try JSONDecoder().decode(SendChatRequest.self, from: encoded)
precondition(decoded.text == request.text && decoded.apiVersion == StudyRocketAPI.version)
precondition(WriteMetadata(baseRevision: "r").apiVersion == StudyRocketAPI.version)
let pairRequest = PairRequest(code: "123456", deviceName: "test", publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString())
let decodedPairRequest = try JSONDecoder().decode(PairRequest.self, from: JSONEncoder().encode(pairRequest))
precondition(decodedPairRequest.apiVersion == StudyRocketAPI.version)
let interruptRequest = InterruptRequest(turnID: "turn")
let decodedInterruptRequest = try JSONDecoder().decode(InterruptRequest.self, from: JSONEncoder().encode(interruptRequest))
precondition(decodedInterruptRequest.apiVersion == StudyRocketAPI.version)
let legacyPlan = try JSONDecoder().decode(WeeklyPlanSnapshot.self, from: Data(#"{"days":[],"bufferRules":[],"deliveries":[]}"#.utf8))
precondition(legacyPlan.historicalRows.isEmpty && legacyPlan.futureRows.isEmpty)
let legacyPeriod = try JSONDecoder().decode(PeriodSnapshot.self, from: Data(#"{"id":"morning","title":"上午","text":"复习"}"#.utf8))
precondition(!legacyPeriod.isCompleted)
let completedPeriod = PeriodSnapshot(id: "morning", title: "上午", text: "复习", isCompleted: true)
let decodedCompletedPeriod = try JSONDecoder().decode(PeriodSnapshot.self, from: JSONEncoder().encode(completedPeriod))
precondition(decodedCompletedPeriod.isCompleted)
precondition(PeriodCompletion.textHash(for: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
let periodToggle = PeriodCompletionToggleRequest(
    dayID: "2026-08-16",
    periodID: "morning",
    textHash: PeriodCompletion.textHash(for: "复习"),
    isCompleted: true,
    metadata: WriteMetadata(baseRevision: "revision", idempotencyKey: "period-toggle")
)
let decodedPeriodToggle = try JSONDecoder().decode(PeriodCompletionToggleRequest.self, from: JSONEncoder().encode(periodToggle))
precondition(decodedPeriodToggle == periodToggle)
let scheduled = ScheduledRowSnapshot(id: "old", dateLabel: "8月14日", slots: [PeriodSnapshot(id: "morning", title: "上午", text: "复习")], isCompleted: false)
let planWithHistory = WeeklyPlanSnapshot(days: [], bufferRules: [], deliveries: [], historicalRows: [scheduled], futureRows: [])
let decodedPlan = try JSONDecoder().decode(WeeklyPlanSnapshot.self, from: JSONEncoder().encode(planWithHistory))
precondition(decodedPlan.historicalRows == [scheduled])
let streamEvent = HostEventEnvelope(
    kind: "chat",
    chat: ChatStreamEvent(kind: "item_completed", turnID: "turn", itemID: "item", text: "最终回答", phase: "final_answer")
)
let decodedStreamEvent = try JSONDecoder().decode(HostEventEnvelope.self, from: JSONEncoder().encode(streamEvent))
precondition(decodedStreamEvent.chat?.text == "最终回答" && decodedStreamEvent.chat?.phase == "final_answer")
let failedStreamEvent = HostEventEnvelope(
    kind: "chat",
    chat: ChatStreamEvent(kind: "status", turnID: "turn", text: "动态工具协议失败", status: "failed")
)
let decodedFailedStreamEvent = try JSONDecoder().decode(HostEventEnvelope.self, from: JSONEncoder().encode(failedStreamEvent))
precondition(decodedFailedStreamEvent.chat?.status == "failed" && decodedFailedStreamEvent.chat?.text == "动态工具协议失败")
let heartbeat = HostEventEnvelope(kind: "heartbeat")
let decodedHeartbeat = try JSONDecoder().decode(HostEventEnvelope.self, from: JSONEncoder().encode(heartbeat))
precondition(decodedHeartbeat.kind == "heartbeat" && decodedHeartbeat.snapshot == nil && decodedHeartbeat.chat == nil)
let document = DocumentDetail(documentKey: "course", title: "课程", markdown: "# 课程", revision: "abc")
let decodedDocument = try JSONDecoder().decode(DocumentDetail.self, from: JSONEncoder().encode(document))
precondition(decodedDocument == document)
let legacySummary = try JSONDecoder().decode(SummaryCard.self, from: Data(#"{"id":"legacy","title":"课程","detail":"摘要"}"#.utf8))
precondition(legacySummary.documentKey == nil)
let markdownBlocks = StudyRocketMarkdownParser.blocks(from: "说明\n\n| 课程 | 时间 |\n| --- | --- |\n| 数据科学 | 上午 |\n\n结尾")
precondition(markdownBlocks.count == 3)
if case .table(_, let columns) = markdownBlocks[1] { precondition(columns == 2) } else { preconditionFailure("table block not detected") }
let escapedTable = StudyRocketMarkdownParser.blocks(from: "| 内容 | 状态 |\n| --- | --- |\n| A \\| B | 完成 |")
if case .table(_, let columns) = escapedTable.first { precondition(columns == 2) } else { preconditionFailure("escaped-pipe table not detected") }
let fencedTable = StudyRocketMarkdownParser.blocks(from: "```markdown\n| A | B |\n|---|---|\n```")
precondition(fencedTable.count == 1 && { if case .prose = fencedTable[0] { return true }; return false }())

let leaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("studyrocket-lease-\(UUID().uuidString).json")
let leaseStore = CodexLeaseStore(url: leaseURL)
let lease = try leaseStore.acquire(owner: "shared-check")
do {
    _ = try leaseStore.acquire(owner: "second-check")
    preconditionFailure("a second Codex lease must be rejected")
} catch CodexLeaseError.busy {
    // Expected.
}
lease.release()
precondition(!FileManager.default.fileExists(atPath: leaseURL.path))
let descriptorRoot = FileManager.default.temporaryDirectory.appendingPathComponent("studyrocket-descriptors-" + UUID().uuidString, isDirectory: true)
let descriptorStore = StudyRocketTaskDescriptorStore(directory: descriptorRoot)
let firstRoot = descriptorRoot.appendingPathComponent("repo-a", isDirectory: true)
let secondRoot = descriptorRoot.appendingPathComponent("repo-b", isDirectory: true)
let descriptor = StudyRocketTaskDescriptor(threadID: "thread-a")
try descriptorStore.save(descriptor, for: firstRoot)
precondition(descriptorStore.load(for: firstRoot) == descriptor)
precondition(descriptorStore.load(for: secondRoot) == nil)
try descriptorStore.save(StudyRocketTaskDescriptor(threadID: "thread-b", protocolVersion: 2), for: secondRoot)
precondition(descriptorStore.load(for: secondRoot)?.protocolVersion == 2)
descriptorStore.remove(for: firstRoot)
precondition(descriptorStore.load(for: firstRoot) == nil)
try? FileManager.default.removeItem(at: descriptorRoot)
print("StudyRocketSharedChecks: signing, DTO, lease and task descriptor checks passed")

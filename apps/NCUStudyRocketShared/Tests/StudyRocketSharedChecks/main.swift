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
print("StudyRocketSharedChecks: signing, DTO and lease checks passed")

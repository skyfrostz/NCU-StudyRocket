import Foundation
import XCTest
import StudyRocketShared
@testable import StudyRocketMobile

/// Exercises the production service-switch transition with disk-backed old queue bytes.
/// No network request, device identity, real cache or Keychain mutation is needed.
@MainActor
final class MobileCloudMigrationTests: XCTestCase {
    private let originalEndpoint = URL(string: "https://old.synthetic.invalid")!
    private let movedEndpoint = URL(string: "https://new.synthetic.invalid")!
    private let repositoryID = "55BCBA7D-808A-4607-B66A-E80F6D8F1FE8"
    private let operationID = "3828F318-23B1-4024-B3D4-71703F77FBB8"

    private func fixture(_ action: (URL, MobileSession, Data, Data) throws -> Void) throws {
        let keys = ["studyrocket.repositoryID", "studyrocket.deviceID", "studyrocket.hostEndpoint", "studyrocket.inputDraft"]
        let defaults = UserDefaults.standard
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in previous {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        keys.forEach { defaults.removeObject(forKey: $0) }
        defaults.set(repositoryID, forKey: "studyrocket.repositoryID")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MobileCloudMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plan = WeeklyPlanSnapshot(days: [], bufferRules: [], deliveries: [])
        let planObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))
        let drafts = try JSONSerialization.data(withJSONObject: [
            "week": planObject,
            "weekBaseRevision": "original-offline-revision",
            "daily": ["date": "2026-11-11", "deliverables": "synthetic daily", "studyTime": "", "sleep": "", "exercise": "", "firstTask": ""],
            "deliveries": [["text": "synthetic delivery", "isCompleted": true, "idempotencyKey": operationID]],
            "periods": [["dayID": "2026-11-11", "periodID": "morning", "isCompleted": true, "textHash": "legacy-ambiguous-target"]]
        ], options: [.sortedKeys])
        let facts = try JSONSerialization.data(withJSONObject: [[
            "repositoryID": repositoryID, "endpoint": originalEndpoint.absoluteString,
            "fact": ["id": operationID, "date": "2026-11-11", "text": "synthetic unsent fact"]
        ]], options: [.sortedKeys])
        try drafts.write(to: directory.appendingPathComponent("pending-drafts.json"))
        try facts.write(to: directory.appendingPathComponent("pending-facts.json"))
        try JSONSerialization.data(withJSONObject: [["id": operationID, "text": "synthetic uncertain chat",
            "endpoint": originalEndpoint.absoluteString, "repositoryID": repositoryID]])
            .write(to: directory.appendingPathComponent("pending-cloud-chats.json"))
        let remote = StudyRocketRemoteClient(endpoint: originalEndpoint, session: URLSession(configuration: .ephemeral))
        let session = MobileSession(cacheDirectory: directory, client: remote, eventStreamsEnabled: false)
        session.inputDraft = "synthetic unsent chat"
        try action(directory, session, drafts, facts)
    }

    func testSameRepositoryRepairPreservesEveryPendingDraftAndOriginalID() throws {
        try fixture { directory, session, drafts, facts in
            let remote = StudyRocketRemoteClient(endpoint: originalEndpoint, session: URLSession(configuration: .ephemeral))
            try session.replaceClient(with: remote, endpoint: originalEndpoint, persistEndpoint: false, incomingRepositoryID: repositoryID)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("pending-drafts.json")), drafts)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("pending-facts.json")), facts)
            XCTAssertEqual(session.pendingDeliveryCount, 1)
            XCTAssertEqual(session.pendingPeriodCount, 1)
            XCTAssertEqual(session.legacyPendingToggleCount, 1)
            XCTAssertNotNil(session.pendingWeekDraft)
            XCTAssertNotNil(session.pendingDailyDraft)
            XCTAssertEqual(session.pendingFacts.map(\.id.uuidString), [operationID])
            XCTAssertEqual(session.inputDraft, "synthetic unsent chat")
            XCTAssertTrue(session.preservedQueues.isEmpty, "Same repository should keep active queues, not archive-and-drop them")
        }
    }

    func testSameStableUUIDAtNewEndpointKeepsQueueAndRebindsFacts() throws {
        try fixture { directory, session, drafts, _ in
            let remote = StudyRocketRemoteClient(endpoint: movedEndpoint, session: URLSession(configuration: .ephemeral))
            try session.replaceClient(with: remote, endpoint: movedEndpoint, persistEndpoint: false, incomingRepositoryID: repositoryID)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("pending-drafts.json")), drafts, "Original CAS revision and operation ID must survive migration")
            XCTAssertEqual(session.pendingFacts.map(\.id.uuidString), [operationID], "A moved endpoint must not hide same-repository facts")
            let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("pending-facts.json"))) as? [[String: Any]])
            XCTAssertEqual(stored.first?["endpoint"] as? String, movedEndpoint.absoluteString)
            let chats = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("pending-cloud-chats.json"))) as? [[String: Any]])
            XCTAssertEqual(chats.first?["id"] as? String, operationID, "Uncertain chat must retain its original request ID")
            XCTAssertEqual(chats.first?["endpoint"] as? String, movedEndpoint.absoluteString, "Retry after endpoint move must find the old request, never create a new one")
            XCTAssertEqual(session.legacyPendingToggleCount, 1, "Ambiguous legacy operation still requires review")
            XCTAssertEqual(session.inputDraft, "synthetic unsent chat")
        }
    }

    func testDifferentRepositoryArchivesExactOldBytesAndDoesNotReplayThem() throws {
        try fixture { _, session, drafts, facts in
            let remote = StudyRocketRemoteClient(endpoint: movedEndpoint, session: URLSession(configuration: .ephemeral))
            try session.replaceClient(with: remote, endpoint: movedEndpoint, persistEndpoint: false, incomingRepositoryID: "AB1D0E49-80B3-4F20-BDBD-D30BD853E877")
            XCTAssertEqual(session.pendingDeliveryCount, 0)
            XCTAssertEqual(session.pendingPeriodCount, 0)
            XCTAssertNil(session.pendingWeekDraft)
            XCTAssertNil(session.pendingDailyDraft)
            XCTAssertTrue(session.pendingFacts.isEmpty)
            let archive = try XCTUnwrap(session.preservedQueues.first)
            XCTAssertEqual(archive.drafts, drafts)
            XCTAssertEqual(archive.facts, facts)
            let archivedChats = try XCTUnwrap(archive.chats)
            let chats = try XCTUnwrap(JSONSerialization.jsonObject(with: archivedChats) as? [[String: Any]])
            XCTAssertEqual(chats.first?["id"] as? String, operationID)
            XCTAssertEqual(chats.first?["text"] as? String, "synthetic uncertain chat")
            XCTAssertEqual(archive.repositoryID, repositoryID)
            XCTAssertEqual(archive.input, "synthetic unsent chat")
            session.reloadPreservedQueues()
            XCTAssertEqual(session.preservedQueues.first?.id, archive.id, "Archive must survive reload from disk")
        }
    }

    func testArchiveFailureDoesNotSwitchOrDiscardQueue() throws {
        try fixture { directory, session, drafts, facts in
            try Data("not a directory".utf8).write(to: directory.appendingPathComponent("preserved-queues"))
            let remote = StudyRocketRemoteClient(endpoint: movedEndpoint, session: URLSession(configuration: .ephemeral))
            XCTAssertThrowsError(try session.replaceClient(with: remote, endpoint: movedEndpoint, persistEndpoint: false, incomingRepositoryID: "AB1D0E49-80B3-4F20-BDBD-D30BD853E877"))
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("pending-drafts.json")), drafts)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("pending-facts.json")), facts)
            XCTAssertEqual(session.pendingDeliveryCount, 1)
            XCTAssertEqual(session.pendingFacts.map(\.id.uuidString), [operationID])
        }
    }
}

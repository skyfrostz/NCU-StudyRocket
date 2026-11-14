import Foundation
import XCTest
import StudyRocketShared
import ImageIO
import UniformTypeIdentifiers
@testable import StudyRocketMobile

@MainActor
final class MobileChatDraftTests: XCTestCase {
    func testTextAttachmentsAndFrozenReplacementSurviveRelaunchWithoutTouchingSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("课件.txt")
        try Data("hello".utf8).write(to: source)
        let store = MobileChatDraftStore(root: directory.appendingPathComponent("cache"))
        store.bind(repository: "repo-A")
        let item = try store.importFile(source)
        store.update(item.id, remoteID: item.id)
        store.replacement = MobilePendingReplacement(id: "new", text: "frozen", attachmentIDs: [item.id], oldTurnID: "old")
        try store.save(text: "继续编辑的草稿")
        let restored = MobileChatDraftStore(root: directory.appendingPathComponent("cache"))
        restored.bind(repository: "repo-A")
        XCTAssertEqual(restored.text, "继续编辑的草稿")
        XCTAssertEqual(restored.replacement?.text, "frozen")
        XCTAssertEqual(restored.attachments.first?.remoteID, item.id)
        restored.remove(item.id)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "hello")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.url(for: item).path))
        restored.bind(repository: "repo-B")
        XCTAssertTrue(restored.attachments.isEmpty)
        XCTAssertNil(restored.replacement)
        restored.bind(repository: "repo-A")
        XCTAssertEqual(restored.replacement?.oldTurnID, "old")
    }

    func testAttachmentCountAndExtensionValidationLeaveExistingDraftIntact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileChatDraftStore(root: directory); store.bind(repository: "test")
        store.setText("保留")
        for index in 0..<10 { _ = try store.importData(Data("test".utf8), name: "\(index).md") }
        XCTAssertThrowsError(try store.importData(Data(), name: "11.txt"))
        XCTAssertEqual(store.attachments.count, 10)
        store.remove(store.attachments[0].id)
        XCTAssertThrowsError(try store.importData(Data(), name: "script.exe"))
        XCTAssertEqual(store.text, "保留")
        XCTAssertEqual(store.attachments.count, 9)
        XCTAssertEqual(MobileChatDraftStore.limit(for: "png"), 20 * 1_048_576)
        XCTAssertEqual(MobileChatDraftStore.limit(for: "xlsx"), 32 * 1_048_576)
        XCTAssertEqual(MobileChatDraftStore.limit(for: "pdf"), 100 * 1_048_576)
    }
    func testThirtyDayCleanupRemovesOnlySentCacheAndKeepsUnsentAndSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileChatDraftStore(root: directory); store.bind(repository: "repo")
        let unsent = try store.importData(Data("draft".utf8), name: "draft.txt")
        var sent = try store.importData(Data("sent".utf8), name: "sent.pdf")
        sent.sentAt = Date().addingTimeInterval(-31 * 86_400)
        let receipt = directory.appendingPathComponent("files").appendingPathComponent(sent.id + ".receipt.json")
        try JSONEncoder().encode(sent).write(to: receipt)
        store.remove(sent.id)
        store.bind(repository: "repo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: unsent).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: sent).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
    }

    func testExpiredOrUnconfirmedUploadCannotSendAndRenewPreservesPrivateBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileChatDraftStore(root: directory); store.bind(repository: "repo")
        let item = try store.importData(Data("retained".utf8), name: "notes.txt")
        store.update(item.id, remoteID: item.id)
        XCTAssertFalse(store.ready, "An ID alone is not proof that parsing finished")
        store.update(item.id, remoteID: item.id, metadata: ChatAttachmentDTO(id: item.id, filename: item.name, mimeType: item.mimeType, byteCount: item.byteCount, sha256: "hash", state: .ready, expiresAt: .now.addingTimeInterval(-1)))
        XCTAssertFalse(store.ready)
        let renewed = try store.renew(store.attachments[0])
        XCTAssertNotEqual(renewed.id, item.id)
        XCTAssertNil(renewed.remoteID)
        XCTAssertEqual(try Data(contentsOf: store.url(for: renewed)), Data("retained".utf8))
        store.update(renewed.id, remoteID: renewed.id, metadata: ChatAttachmentDTO(id: renewed.id, filename: renewed.name, mimeType: renewed.mimeType, byteCount: renewed.byteCount, sha256: "hash", state: .ready, expiresAt: .now.addingTimeInterval(3600)))
        XCTAssertTrue(store.ready)
    }

    func testCleanupProtectsFrozenAndOrdinaryDraftsAcrossScopesUntilReferencesAreRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileChatDraftStore(root: directory)
        store.bind(repository: "scope-A")
        let ordinary = try store.importData(Data("ordinary retry".utf8), name: "ordinary.txt")
        let frozen = try store.importData(Data("frozen retry".utf8), name: "frozen.txt")
        let expired = try store.importData(Data("unreferenced sent".utf8), name: "expired.txt")
        for var item in [ordinary, frozen, expired] {
            item.sentAt = Date().addingTimeInterval(-31 * 86_400)
            try JSONEncoder().encode(item).write(to: directory.appendingPathComponent("files/" + item.id + ".receipt.json"))
        }
        store.attachments = [ordinary]
        store.replacement = MobilePendingReplacement(id: "next", text: "frozen", attachmentIDs: [frozen.id], oldTurnID: "old", attachments: [frozen])
        try store.save(text: "independent draft")
        // Binding a different scope used to delete both referenced files.
        store.bind(repository: "scope-B")
        XCTAssertEqual(try Data(contentsOf: store.url(for: ordinary)), Data("ordinary retry".utf8))
        XCTAssertEqual(try Data(contentsOf: store.url(for: frozen)), Data("frozen retry".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: expired).path))
        let restored = MobileChatDraftStore(root: directory)
        restored.bind(repository: "scope-A")
        XCTAssertEqual(restored.text, "independent draft")
        XCTAssertEqual(restored.replacement?.attachments?.first?.id, frozen.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.url(for: frozen).path))
        restored.attachments = []; restored.replacement = nil
        try restored.save()
        restored.bind(repository: "scope-B")
        for item in [ordinary, frozen] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: restored.url(for: item).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("files/" + item.id + ".receipt.json").path))
        }
    }

    func testUnreadableOtherScopeDefersSentCacheCleanup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileChatDraftStore(root: directory); store.bind(repository: "repo")
        var item = try store.importData(Data("retained".utf8), name: "retry.txt")
        item.sentAt = Date().addingTimeInterval(-31 * 86_400)
        let receipt = directory.appendingPathComponent("files/" + item.id + ".receipt.json")
        try JSONEncoder().encode(item).write(to: receipt)
        store.remove(item.id)
        try Data("incomplete archive".utf8).write(to: directory.appendingPathComponent("other-scope.json"))
        store.bind(repository: "repo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: item).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.path))
    }

    func testPhotoThumbnailDownsamplesOffMainWithoutChangingAttachmentBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let source = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(source, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let store = MobileChatDraftStore(root: directory); store.bind(repository: "photo")
        let item = try store.importData(source as Data, name: "photo.png")
        await store.prepareThumbnail(item.id)
        let thumbnail = try XCTUnwrap(store.attachments.first?.thumbnailData)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let small = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        XCTAssertLessThanOrEqual(max(small.width, small.height), 128)
        XCTAssertEqual(try Data(contentsOf: store.url(for: item)), source as Data)
    }

}

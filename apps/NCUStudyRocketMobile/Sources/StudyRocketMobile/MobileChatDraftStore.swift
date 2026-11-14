import Foundation
import Combine
import StudyRocketShared
import CryptoKit
import UniformTypeIdentifiers
import ImageIO
#if os(iOS)
import UIKit
#endif

struct MobileChatAttachment: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var mimeType: String
    var byteCount: Int
    var cachedFile: String
    var remoteID: String?
    var remoteMetadata: ChatAttachmentDTO?
    var issue: String?
    var sentAt: Date?
    var thumbnailData: Data? = nil
    var isReady: Bool { remoteID != nil && remoteMetadata?.state == .ready && (remoteMetadata?.expiresAt ?? .distantPast) > .now }
    var isImage: Bool { mimeType.hasPrefix("image/") }
}

/// The replacement is immutable once the user presses send. Its identity survives
/// suspension and relaunch; a missing terminal receipt never permits a new send.
struct MobilePendingReplacement: Codable, Equatable {
    var id: String
    var text: String
    var attachmentIDs: [String]
    var oldTurnID: String
    var stopOperationID: String? = UUID().uuidString
    var terminalReadOperationID: String? = UUID().uuidString
    var oldTerminal: ChatTurnTerminalDTO? = nil
    var attachments: [MobileChatAttachment]? = nil
    var submitted: Bool = false
}

struct MobileComposerArchive: Codable {
    var text: String
    var attachments: [MobileChatAttachment]
    var replacement: MobilePendingReplacement?
}

@MainActor
final class MobileChatDraftStore: ObservableObject {
    @Published var attachments: [MobileChatAttachment] = []
    @Published var uploading: Set<String> = []
    @Published var progress: [String: Double] = [:]
    @Published var issue: String?
    @Published var replacement: MobilePendingReplacement?
    private(set) var text = ""
    private let root: URL
    private var scope = "unbound"
    private var archiveURL: URL { root.appendingPathComponent(scope + ".json") }
    private var files: URL { root.appendingPathComponent("files", isDirectory: true) }
    var ready: Bool { !attachments.isEmpty && attachments.allSatisfy(\.isReady) && uploading.isEmpty }

    init(root: URL) { self.root = root }
    func bind(repository: String?, fallbackText: String = "") {
        scope = SHA256.hash(data: Data((repository ?? "unbound").utf8)).map { String(format: "%02x", $0) }.joined()
        uploading = []; progress = [:]
        if let data = try? Data(contentsOf: archiveURL), let archive = try? JSONDecoder().decode(MobileComposerArchive.self, from: data) {
            text = archive.text; attachments = archive.attachments; replacement = archive.replacement
        } else { text = fallbackText; attachments = []; replacement = nil }
        cleanupSentCache()
    }
    func save(text: String? = nil) throws {
        if let text { self.text = text }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let value = MobileComposerArchive(text: self.text, attachments: attachments, replacement: replacement)
        try JSONEncoder().encode(value).write(to: archiveURL, options: [.atomic])
    }
    func setText(_ text: String) { do { try save(text: text) } catch { issue = "输入未能保存，请保留当前页面。" } }
    func url(for item: MobileChatAttachment) -> URL { files.appendingPathComponent(item.cachedFile) }
    static let allowedExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "txt", "md", "csv", "json"]
    static func limit(for fileExtension: String) -> Int {
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif"].contains(fileExtension) { return 20 * 1_048_576 }
        if ["txt", "md", "csv", "json", "xls", "xlsx"].contains(fileExtension) { return 32 * 1_048_576 }
        return 100 * 1_048_576
    }
    func importFile(_ source: URL) throws -> MobileChatAttachment {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.limit(for: source.pathExtension.lowercased()) else { throw DraftError.message("附件超过单个文件大小限制。") }
        return try importData(Data(contentsOf: source), name: source.lastPathComponent)
    }
    func importData(_ input: Data, name: String) throws -> MobileChatAttachment {
        guard !input.isEmpty else { throw DraftError.message("文件为空，请选择有内容的附件。") }
        guard attachments.count < 10 else { throw DraftError.message("每条消息最多添加 10 个附件。") }
        var filename = name, data = input
        var ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        guard Self.allowedExtensions.contains(ext) else { throw DraftError.message("不支持这个文件格式。") }
        guard data.count <= Self.limit(for: ext) else { throw DraftError.message("附件超过单个文件大小限制。") }
        #if os(iOS)
        if ["heic", "heif"].contains(ext) {
            guard let image = UIImage(data: data), let converted = image.jpegData(compressionQuality: 0.9) else { throw DraftError.message("无法转换这张照片，请选择另一张。") }
            data = converted; ext = "jpg"; filename = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent + ".jpg"
        }
        #endif
        guard data.count <= Self.limit(for: ext), attachments.reduce(0, { $0 + $1.byteCount }) + data.count <= 100 * 1_048_576 else { throw DraftError.message("每条消息附件总大小不能超过 100 MB。") }
        let id = UUID().uuidString
        let item = MobileChatAttachment(id: id, name: filename, mimeType: UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream", byteCount: data.count, cachedFile: id + "." + ext)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try data.write(to: url(for: item), options: .atomic)
        attachments.append(item)
        do { try save() } catch { attachments.removeAll { $0.id == id }; throw error }
        return item
    }
    func prepareThumbnail(_ id: String) async {
        guard let item = attachments.first(where: { $0.id == id }), item.isImage, item.thumbnailData == nil else { return }
        let file = url(for: item)
        let data = await Task.detached(priority: .utility) { () -> Data? in
            guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 128,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }.value
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].thumbnailData = data
        try? save()
    }

    func renew(_ item: MobileChatAttachment) throws -> MobileChatAttachment {
        guard let index = attachments.firstIndex(where: { $0.id == item.id }) else { throw DraftError.message("附件已移除。") }
        let id = UUID().uuidString
        var next = item
        next.id = id; next.cachedFile = id + "." + URL(fileURLWithPath: item.cachedFile).pathExtension
        next.remoteID = nil; next.remoteMetadata = nil; next.issue = nil
        try FileManager.default.copyItem(at: url(for: item), to: url(for: next))
        attachments[index] = next
        do { try save() } catch { attachments[index] = item; throw error }
        return next
    }
    func remove(_ id: String) {
        attachments.removeAll { $0.id == id }
        try? save() // Only the cache reference is removed; the selected source is never deleted.
    }
    func update(_ id: String, remoteID: String? = nil, metadata: ChatAttachmentDTO? = nil, issue: String? = nil) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].remoteID = remoteID
        if let metadata { attachments[index].remoteMetadata = metadata }
        attachments[index].issue = issue
        try? save()
    }
    func previewDestination(filename: String) throws -> URL {
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let directory = files.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
    }
    func recordPreview(_ attachment: ChatAttachmentDTO, url: URL) throws {
        let item = MobileChatAttachment(id: UUID().uuidString, name: attachment.filename, mimeType: attachment.mimeType,
            byteCount: attachment.byteCount, cachedFile: url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent, remoteID: attachment.id,
            remoteMetadata: attachment, sentAt: attachment.expiresAt.addingTimeInterval(-30 * 86_400))
        try JSONEncoder().encode(item).write(to: files.appendingPathComponent(item.id + ".receipt.json"), options: .atomic)
    }
    func markSent(ids: [String], frozen: [MobileChatAttachment] = []) {
        for var item in attachments + frozen where ids.contains(item.id) {
            item.sentAt = .now
            if let data = try? JSONEncoder().encode(item) { try? data.write(to: files.appendingPathComponent(item.id + ".receipt.json"), options: .atomic) }
        }
        attachments.removeAll { ids.contains($0.id) }
        try? save()
    }
    private func cleanupSentCache(now: Date = .now) {
        var protected = Set((attachments + (replacement?.attachments ?? [])).map(\.cachedFile))
        // Files are shared across repository scopes. An old sent receipt can
        // also back a retry or a frozen replacement in any of those drafts.
        // If a draft cannot be read, defer cleanup instead of risking its bytes.
        guard let archives = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for archive in archives where archive.pathExtension == "json" {
            guard let data = try? Data(contentsOf: archive),
                  let draft = try? JSONDecoder().decode(MobileComposerArchive.self, from: data) else { return }
            protected.formUnion((draft.attachments + (draft.replacement?.attachments ?? [])).map(\.cachedFile))
        }
        for receipt in (try? FileManager.default.contentsOfDirectory(at: files, includingPropertiesForKeys: nil)) ?? [] where receipt.lastPathComponent.hasSuffix(".receipt.json") {
            guard let data = try? Data(contentsOf: receipt), let item = try? JSONDecoder().decode(MobileChatAttachment.self, from: data), let sent = item.sentAt,
                  now.timeIntervalSince(sent) > 30 * 86_400, !protected.contains(item.cachedFile) else { continue }
            try? FileManager.default.removeItem(at: url(for: item)); try? FileManager.default.removeItem(at: receipt)
        }
    }
    enum DraftError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let value) = self { return value }; return nil } }
}

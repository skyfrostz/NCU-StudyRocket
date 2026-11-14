import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import StudyRocketShared

struct DesktopChatAttachment: Codable, Equatable, Identifiable {
    var metadata: ChatAttachmentDTO
    var localURL: URL
    var id: String { metadata.id }
}

/// Private application cache: attachment bytes never become repository Markdown.
enum DesktopChatDraftCache {
    struct Draft: Codable { var text: String; var attachments: [DesktopChatAttachment] }
    private struct PendingReferences: Decodable { var attachments: [DesktopChatAttachment] }
    private struct SessionReferences: Decodable {
        var composer: Draft?
        var active: PendingReferences?
        var replacement: PendingReferences?
        var failed: PendingReferences?
    }
    static func directory(for root: URL) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NCUStudyRocket/ChatAttachments", isDirectory: true)
            .appendingPathComponent(RequestSigning.bodyHash(Data(root.standardizedFileURL.path.utf8)), isDirectory: true)
    }
    static let allowedExtensions = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "txt", "md", "csv", "json"]
    static func isLegacyDraftUnreadable(root: URL) -> Bool {
        let url = directory(for: root).appendingPathComponent("draft.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Draft.self, from: $0) } == nil
    }
    static func load(root: URL, protecting: Set<String> = []) -> Draft? {
        let directory = directory(for: root)
        guard !isLegacyDraftUnreadable(root: root) else { return nil }
        let saved = (try? Data(contentsOf: directory.appendingPathComponent("draft.json"))).flatMap { try? JSONDecoder().decode(Draft.self, from: $0) }
        var protected = protecting.union(saved?.attachments.map(\.id) ?? [])
        let sessionURL = directory.appendingPathComponent("session.json")
        if FileManager.default.fileExists(atPath: sessionURL.path) {
            guard let bytes = try? Data(contentsOf: sessionURL),
                  let session = try? JSONDecoder().decode(SessionReferences.self, from: bytes) else { return nil }
            protected.formUnion(session.composer?.attachments.map(\.id) ?? [])
            for reference in [session.active, session.replacement, session.failed].compactMap({ $0 }) {
                protected.formUnion(reference.attachments.map(\.id))
            }
        }
        // Only explicit server-confirmed sent receipts make bytes eligible for cleanup.
        // An old mtime is never evidence that an unsent/frozen attachment may be deleted.
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            guard !protected.contains(url.lastPathComponent),
                  let data = try? Data(contentsOf: url.appendingPathComponent("retention.json")),
                  let expires = try? JSONDecoder().decode(Date.self, from: data), expires <= .now else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("draft.json")),
              var draft = try? JSONDecoder().decode(Draft.self, from: data) else { return nil }
        for index in draft.attachments.indices {
            if draft.attachments[index].metadata.expiresAt <= .now {
                draft.attachments[index].metadata.state = .expired
                draft.attachments[index].metadata.issue = "附件已到期，请重新添加。"
            } else if [.uploading, .processing].contains(draft.attachments[index].metadata.state) {
                draft.attachments[index].metadata.state = .unknown
                draft.attachments[index].metadata.issue = "上传尚未确认，点重试查询并继续。"
            }
        }
        return draft
    }
    static func save(_ draft: Draft, root: URL) {
        let directory = directory(for: root)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(draft) else { return }
        try? data.write(to: directory.appendingPathComponent("draft.json"), options: .atomic)
    }
    static func writeDurably(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
        let descriptor = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }
    static func markSent(_ attachment: ChatAttachmentDTO, root: URL) {
        guard attachment.state == .ready else { return }
        let marker = directory(for: root).appendingPathComponent(attachment.id).appendingPathComponent("retention.json")
        if let data = try? JSONEncoder().encode(attachment.expiresAt) { try? writeDurably(data, to: marker) }
    }
    static func importFile(_ source: URL, root: URL) throws -> DesktopChatAttachment {
        let resource = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard resource.isRegularFile == true else { throw StudyChatError.unavailable("请选择文件，不能添加文件夹。") }
        let ext = source.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { throw StudyChatError.unavailable("此附件格式暂不受支持。请选择图片、PDF、Office 或文本文件。") }
        let type = resource.contentType ?? UTType(filenameExtension: ext) ?? .data
        var mime = type.preferredMIMEType ?? "application/octet-stream"
        let image = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif"].contains(ext)
        let text = ["txt", "md", "csv", "json", "xls", "xlsx"].contains(ext)
        let limit = image ? ChatAttachmentLimits.imageBytes : text ? ChatAttachmentLimits.textBytes : ChatAttachmentLimits.documentBytes
        guard let size = resource.fileSize, size > 0, size <= limit else { throw StudyChatError.unavailable("文件为空或超过限制（图片 20 MiB、文档 100 MiB、文本与表格 32 MiB）。") }
        var data = try Data(contentsOf: source, options: .mappedIfSafe)
        var filename = source.lastPathComponent
        if ["heic", "heif"].contains(ext) {
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { throw StudyChatError.unavailable("无法转换这张照片，请选择另一张。") }
            let output = NSMutableData()
            guard let writer = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw StudyChatError.unavailable("无法创建照片副本。") }
            var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
            if let sourceProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
               let orientation = sourceProperties[kCGImagePropertyOrientation] { properties[kCGImagePropertyOrientation] = orientation }
            CGImageDestinationAddImage(writer, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(writer) else { throw StudyChatError.unavailable("无法转换这张照片，请选择另一张。") }
            data = output as Data
            filename = source.deletingPathExtension().lastPathComponent + ".jpg"
            mime = "image/jpeg"
        }
        guard !data.isEmpty, data.count <= limit else { throw StudyChatError.unavailable("转换后的图片超过 20 MiB，请选择较小的照片。") }
        let id = UUID().uuidString
        let directory = directory(for: root).appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(filename)
        try writeDurably(data, to: target)
        return .init(metadata: .init(id: id, filename: filename, mimeType: mime,
            byteCount: data.count, sha256: RequestSigning.bodyHash(data), expiresAt: .now.addingTimeInterval(30 * 86400)), localURL: target)
    }
}

struct DesktopAttachmentCard: View {
    @State private var thumbnail: NSImage?
    let metadata: ChatAttachmentDTO
    var localURL: URL?
    var remove: (() -> Void)?
    var retry: (() -> Void)?
    var preview: (() -> Void)?
    var body: some View {
        HStack(spacing: 8) {
            Button { preview?() } label: {
                HStack(spacing: 8) {
                    if let thumbnail, metadata.expiresAt > .now {
                        Image(nsImage: thumbnail).resizable().scaledToFill().frame(width: 44, height: 44).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
                    } else { Image(systemName: "doc").font(.title2).frame(width: 38, height: 44) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(metadata.filename).lineLimit(1).font(.callout.weight(.medium))
                        Text(metadata.issue ?? stateLabel).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if metadata.state == .uploading {
                            ProgressView(value: Double(metadata.uploadedBytes), total: Double(max(1, metadata.byteCount))).frame(maxWidth: 130)
                        }
                    }
                }
            }.buttonStyle(.plain).disabled(preview == nil || metadata.expiresAt <= .now || metadata.state == .removed)
            if [.unknown, .failed, .expired].contains(effectiveState), let retry {
                Button(action: retry) { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help(effectiveState == .expired ? "重新上传附件" : "查询附件状态并重试")
            }
            if let remove { Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("移除附件") }
        }
        .padding(9).frame(maxWidth: 280, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .accessibilityElement(children: .contain)
        .task(id: localURL) {
            guard metadata.mimeType.hasPrefix("image/"), let localURL, metadata.expiresAt > .now else { thumbnail = nil; return }
            let smallURL = await Task.detached(priority: .utility) { Self.thumbnailURL(for: localURL) }.value
            guard !Task.isCancelled else { return }
            thumbnail = smallURL.flatMap(NSImage.init(contentsOf:))
        }
    }
    nonisolated private static func thumbnailURL(for original: URL) -> URL? {
        let target = original.deletingLastPathComponent().appendingPathComponent(".thumbnail.png")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        guard let source = CGImageSourceCreateWithURL(original as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 120,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let temporary = original.deletingLastPathComponent().appendingPathComponent(".thumbnail-" + UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let writer = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { return nil }
        do { try FileManager.default.moveItem(at: temporary, to: target); return target }
        catch { return FileManager.default.fileExists(atPath: target.path) ? target : nil }
    }
    private var effectiveState: ChatAttachmentState {
        metadata.expiresAt <= .now && metadata.state != .removed ? .expired : metadata.state
    }
    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
    private var stateLabel: String {
        switch effectiveState {
        case .uploading: "上传中 · \(Int(Double(metadata.uploadedBytes) / Double(max(1, metadata.byteCount)) * 100))%"
        case .processing: "正在读取附件"
        case .ready: ByteCountFormatter.string(fromByteCount: Int64(metadata.byteCount), countStyle: .file) + " · " + Self.expiryFormatter.string(from: metadata.expiresAt) + " 到期"
        case .unknown: "上传结果待确认"
        case .failed: "上传失败，可重试"
        case .removed: "附件已移除"
        case .expired: "附件已到期"
        }
    }
}

/// NSTextView keeps IME composition, Return, Shift-Return and paste semantics native.
struct DesktopChatTextInput: NSViewRepresentable {
    @Binding var text: String
    let submit: () -> Void
    let stop: () -> Void
    let receiveFiles: ([URL]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ComposerScrollView {
        let scroll = ComposerScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay; scroll.drawsBackground = false
        let editor = Self.makeEditor()
        editor.delegate = context.coordinator
        editor.submit = submit; editor.stop = stop; editor.receiveFiles = receiveFiles
        scroll.documentView = editor
        return scroll
    }
    static func makeEditor() -> Editor {
        let editor = Editor()
        editor.isRichText = false; editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 15); editor.textColor = .textColor
        editor.textContainerInset = NSSize(width: 2, height: 8)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        return editor
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: ComposerScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: scroll.heightForProposal(width))
    }
    /// Measure only this editor’s TextKit container, without publishing SwiftUI
    /// state or asking the conversation window to lay out on each keystroke.
    static func measuredHeight(_ editor: Editor, width: CGFloat) -> CGFloat {
        guard let container = editor.textContainer, let layout = editor.layoutManager else { return 42 }
        if editor.frame.width != width { editor.setFrameSize(NSSize(width: width, height: editor.frame.height)) }
        let containerWidth = max(1, width - editor.textContainerInset.width * 2)
        if container.containerSize.width != containerWidth {
            container.containerSize = NSSize(width: containerWidth, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        let contentHeight = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        return min(152, max(42, ceil(contentHeight + editor.textContainerInset.height * 2)))
    }
    func updateNSView(_ scroll: ComposerScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? Editor else { return }
        if editor.string != text, !editor.hasMarkedText() { editor.string = text }
        editor.submit = submit; editor.stop = stop; editor.receiveFiles = receiveFiles
    }
    final class ComposerScrollView: NSScrollView {
        // SwiftUI may ask about several speculative widths during one layout.
        // Those measurements must never resize the live editing document.
        private lazy var measuringEditor = DesktopChatTextInput.makeEditor()
        func heightForProposal(_ width: CGFloat) -> CGFloat {
            guard let editor = documentView as? Editor else { return 42 }
            if measuringEditor.string != editor.string { measuringEditor.string = editor.string }
            return DesktopChatTextInput.measuredHeight(measuringEditor, width: width)
        }
        override func tile() {
            super.tile()
            synchronizeDocumentWidth()
        }
        override func layout() {
            super.layout()
            synchronizeDocumentWidth()
        }
        private func synchronizeDocumentWidth() {
            guard let editor = documentView as? Editor, contentView.bounds.width > 0 else { return }
            let width = contentView.bounds.width
            if editor.frame.width != width {
                editor.setFrameSize(NSSize(width: width, height: editor.frame.height))
            }
            if let container = editor.textContainer {
                let expected = max(1, width - editor.textContainerInset.width * 2)
                if container.containerSize.width != expected {
                    container.containerSize = NSSize(width: expected, height: .greatestFiniteMagnitude)
                }
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DesktopChatTextInput
        init(_ parent: DesktopChatTextInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let editor = notification.object as? NSTextView { parent.text = editor.string } }
    }
    final class Editor: NSTextView {
        var submit: (() -> Void)?
        var stop: (() -> Void)?
        var receiveFiles: (([URL]) -> Void)?
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36, !event.modifierFlags.contains(.shift), !hasMarkedText() { submit?(); return }
            if event.charactersIgnoringModifiers == ".", event.modifierFlags.contains(.command) { stop?(); return }
            super.keyDown(with: event)
        }
        override func paste(_ sender: Any?) {
            let pasteboard = NSPasteboard.general
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { receiveFiles?(urls); return }
            if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("粘贴图片-\(UUID().uuidString).png")
                do { try png.write(to: url); receiveFiles?([url]); try? FileManager.default.removeItem(at: url) } catch { NSSound.beep() }
                return
            }
            super.paste(sender)
        }
    }
}

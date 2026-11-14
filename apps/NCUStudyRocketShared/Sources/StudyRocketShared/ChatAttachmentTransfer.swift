import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The caller supplies the existing device-signed JSON transport. No credentials
/// or unbounded file bodies are held by this transfer service.
public struct ChatAttachmentTransfer: Sendable {
    public typealias Transport = @Sendable (String, Data) async throws -> Data
    private let transport: Transport
    public init(transport: @escaping Transport) { self.transport = transport }

    public static func fingerprint(_ url: URL) throws -> (byteCount: Int, sha256: String) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw TransferError.invalidFile }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), count = 0
        while let data = try handle.read(upToCount: ChatAttachmentLimits.chunkBytes), !data.isEmpty {
            count += data.count
            guard count <= ChatAttachmentLimits.documentBytes else { throw TransferError.invalidFile }
            hash.update(data: data)
        }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    public func status(id: String) async throws -> ChatAttachmentDTO {
        try await call("status", ChatAttachmentRequest(id: id), as: ChatAttachmentDTO.self)
    }
    public func remove(id: String) async throws -> ChatAttachmentDTO {
        try await call("remove", ChatAttachmentRequest(id: id), as: ChatAttachmentDTO.self)
    }
    /// Returns after handing the immutable file to the server. Processing is
    /// queried separately, so dismissing a view never submits a second parse.
    public func upload(file: URL, request: ChatAttachmentCreateRequest,
                       progress: @Sendable (ChatAttachmentDTO) async -> Void = { _ in }) async throws -> ChatAttachmentDTO {
        let identity = try Self.fingerprint(file)
        guard identity.byteCount == request.byteCount, identity.sha256 == request.sha256 else { throw TransferError.changedFile }
        var record: ChatAttachmentDTO = try await call("create", request, as: ChatAttachmentDTO.self)
        try validate(record, request: request)
        await progress(record)
        guard record.state == .uploading else { return record }
        let source = try FileHandle(forReadingFrom: file)
        defer { try? source.close() }
        var offset = record.uploadedBytes
        while offset < request.byteCount {
            try Task.checkCancellation()
            try source.seek(toOffset: UInt64(offset))
            let count = min(ChatAttachmentLimits.chunkBytes, request.byteCount - offset)
            guard let bytes = try source.read(upToCount: count), bytes.count == count else { throw TransferError.changedFile }
            let chunk = ChatAttachmentChunkRequest(id: request.id, offset: offset, base64Data: bytes.base64EncodedString(), sha256: RequestSigning.bodyHash(bytes))
            record = try await call("chunk", chunk, as: ChatAttachmentDTO.self)
            try validate(record, request: request)
            guard record.uploadedBytes == offset + count else { throw TransferError.invalidResponse }
            offset += count
            await progress(record)
        }
        try Task.checkCancellation()
        record = try await call("complete", ChatAttachmentRequest(id: request.id), as: ChatAttachmentDTO.self)
        try validate(record, request: request)
        await progress(record)
        return record
    }

    /// Writes a new private temporary file, verifies every chunk and the complete
    /// digest, then atomically publishes it. Existing destinations are untouched.
    public func download(_ attachment: ChatAttachmentDTO, to destination: URL) async throws {
        guard attachment.state == .ready, attachment.expiresAt > Date(),
              attachment.byteCount >= 0, attachment.byteCount <= ChatAttachmentLimits.documentBytes,
              !FileManager.default.fileExists(atPath: destination.path) else { throw TransferError.invalidFile }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".attachment-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw TransferError.invalidFile }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        var offset = 0, hash = SHA256()
        repeat {
            try Task.checkCancellation()
            let chunk: ChatAttachmentChunkResponse = try await call("read", ChatAttachmentReadRequest(id: attachment.id, offset: offset), as: ChatAttachmentChunkResponse.self)
            guard chunk.id == attachment.id, chunk.offset == offset, chunk.totalBytes == attachment.byteCount,
                  let data = Data(base64Encoded: chunk.base64Data), data.count <= ChatAttachmentLimits.chunkBytes,
                  RequestSigning.bodyHash(data) == chunk.sha256, offset + data.count <= attachment.byteCount,
                  !data.isEmpty || attachment.byteCount == 0,
                  chunk.nextOffset == (offset + data.count < attachment.byteCount ? offset + data.count : nil) else { throw TransferError.invalidResponse }
            try handle.write(contentsOf: data)
            hash.update(data: data); offset += data.count
        } while offset < attachment.byteCount
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == attachment.sha256 else { throw TransferError.invalidResponse }
        try handle.synchronize(); try handle.close()
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func validate(_ value: ChatAttachmentDTO, request: ChatAttachmentCreateRequest) throws {
        guard value.id == request.id, value.sha256 == request.sha256, value.byteCount == request.byteCount,
              value.uploadedBytes >= 0, value.uploadedBytes <= request.byteCount else { throw TransferError.invalidResponse }
    }
    private func call<B: Encodable, R: Decodable>(_ action: String, _ body: B, as: R.Type) async throws -> R {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try JSONDecoder().decode(R.self, from: await transport("/v1/attachments/" + action, encoder.encode(body)))
    }
    public enum TransferError: LocalizedError {
        case invalidFile, changedFile, invalidResponse
        public var errorDescription: String? {
            switch self {
            case .invalidFile: return "附件不可读取、已过期或超过大小限制。"
            case .changedFile: return "附件内容已变化，请重新选择后发送。"
            case .invalidResponse: return "附件传输校验失败，原草稿已保留，请重试。"
            }
        }
    }
}

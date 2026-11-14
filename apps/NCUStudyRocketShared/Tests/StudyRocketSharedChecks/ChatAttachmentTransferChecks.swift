import Foundation
import StudyRocketShared

private actor AttachmentWireFixture {
    var bytes: Data
    var metadata: ChatAttachmentDTO
    var completeCount = 0
    var corrupt = false
    init(_ data: Data, id: String) {
        bytes = data
        metadata = ChatAttachmentDTO(id: id, filename: "sample.txt", mimeType: "text/plain", byteCount: data.count,
            sha256: RequestSigning.bodyHash(data), uploadedBytes: ChatAttachmentLimits.chunkBytes, expiresAt: .now.addingTimeInterval(3600))
    }
    func call(_ path: String, _ body: Data) throws -> Data {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        switch path {
        case "/v1/attachments/create": return try encoder.encode(metadata)
        case "/v1/attachments/chunk":
            let chunk = try decoder.decode(ChatAttachmentChunkRequest.self, from: body)
            let data = Data(base64Encoded: chunk.base64Data)!
            precondition(data.count <= ChatAttachmentLimits.chunkBytes)
            precondition(chunk.offset == metadata.uploadedBytes)
            precondition(bytes.subdata(in: chunk.offset..<(chunk.offset + data.count)) == data)
            metadata.uploadedBytes += data.count
            return try encoder.encode(metadata)
        case "/v1/attachments/complete":
            completeCount += 1; metadata.state = .processing
            return try encoder.encode(metadata)
        case "/v1/attachments/read":
            let query = try decoder.decode(ChatAttachmentReadRequest.self, from: body)
            let end = min(query.offset + query.limit, bytes.count)
            let data = bytes.subdata(in: query.offset..<end)
            return try encoder.encode(ChatAttachmentChunkResponse(id: metadata.id, offset: query.offset, nextOffset: end < bytes.count ? end : nil,
                totalBytes: bytes.count, base64Data: data.base64EncodedString(), sha256: corrupt ? String(repeating: "0", count: 64) : RequestSigning.bodyHash(data)))
        default: throw CocoaError(.fileReadUnknown)
        }
    }
    func makeReady(corrupt: Bool = false) -> ChatAttachmentDTO { self.corrupt = corrupt; metadata.state = .ready; return metadata }
}

func runChatAttachmentTransferChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-transfer-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data(repeating: 97, count: ChatAttachmentLimits.chunkBytes * 2 + 19)
    let source = root.appendingPathComponent("source.txt"); try bytes.write(to: source)
    let id = UUID().uuidString, wire = AttachmentWireFixture(bytes, id: id)
    let transfer = ChatAttachmentTransfer { path, body in try await wire.call(path, body) }
    let identity = try ChatAttachmentTransfer.fingerprint(source)
    let request = ChatAttachmentCreateRequest(id: id, filename: "sample.txt", mimeType: "text/plain", byteCount: identity.byteCount, sha256: identity.sha256)
    let result = try await transfer.upload(file: source, request: request)
    precondition(result.state == .processing && result.uploadedBytes == bytes.count)
    let completionCalls = await wire.completeCount; precondition(completionCalls == 1)
    let ready = await wire.makeReady()
    let output = root.appendingPathComponent("output.txt")
    try await transfer.download(ready, to: output)
    let downloaded = try Data(contentsOf: output)
    precondition(downloaded == bytes)
    do { try await transfer.download(ready, to: output); preconditionFailure("Existing destination was overwritten") } catch {}
    let corrupt = await wire.makeReady(corrupt: true)
    let rejected = root.appendingPathComponent("corrupt.txt")
    do { try await transfer.download(corrupt, to: rejected); preconditionFailure("Corrupt chunk accepted") } catch {}
    precondition(!FileManager.default.fileExists(atPath: rejected.path))
    try Data("changed".utf8).write(to: source)
    do { _ = try await transfer.upload(file: source, request: request); preconditionFailure("Changed file accepted") } catch {}
    let old = try JSONDecoder().decode(CloudBackupEntry.self, from: Data("{\"path\":\"cloud.sqlite\",\"sha256\":\"test\",\"byteCount\":1}".utf8))
    precondition(old.expiresAt == nil)
    print("Attachment transfer checks passed: resume, bounded chunks, async processing, verified download, corruption, no overwrite, changed draft, legacy backup DTO")
}

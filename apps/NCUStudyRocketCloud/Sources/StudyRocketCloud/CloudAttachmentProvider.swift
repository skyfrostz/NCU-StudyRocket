import Foundation
import AsyncHTTPClient
import NIOCore
import StudyRocketShared

/// Pull-based file stream: only one 256KiB buffer is held, without an unbounded producer queue.
struct AttachmentFileStream: AsyncSequence, Sendable {
    typealias Element = ByteBuffer
    let url: URL
    final class Reader: @unchecked Sendable {
        let file: FileHandle
        init(_ url:URL) throws {file=try FileHandle(forReadingFrom:url)}
        deinit {try? file.close()}
    }
    struct AsyncIterator: AsyncIteratorProtocol {
        let url: URL
        var reader: Reader?
        mutating func next() async throws -> ByteBuffer? {
            try Task.checkCancellation()
            if reader == nil {reader=try Reader(url)}
            guard let data=try reader!.file.read(upToCount:262144),!data.isEmpty else {return nil}
            return ByteBuffer(bytes:data)
        }
    }
    func makeAsyncIterator() -> AsyncIterator {AsyncIterator(url:url)}
}

/// A single worker serializes native parsing, reconciliation and deletion across all devices.
actor CloudAttachmentProvider {
    let store: CloudStore
    let key: String
    let base: String
    let fixture: Bool
    var worker: Task<Void,Never>?
    var timer: Task<Void,Never>?
    init(store:CloudStore,key:String,testUpstream:String?,fixture:Bool) {
        self.store=store;self.key=key;self.base=testUpstream?.replacingOccurrences(of:"/chat/completions",with:"") ?? "https://api.deepseek.com";self.fixture=fixture
    }
    func start() {
        kick()
        if timer == nil {timer=Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(30))
                guard !Task.isCancelled else {return};await self?.kick()
            }
        }}
    }
    func kick() {
        guard worker == nil else {return}
        worker=Task {await self.drain();self.worker=nil}
    }
    func drain() async {
        guard let records=try? await store.attachmentWork() else {return}
        for record in records {
            do {
                if record.attachment.state == .processing && !record.uploadStarted {
                    guard !key.isEmpty || fixture || base.hasPrefix("http://127.0.0.1") else {throw CloudError(503,"provider_unconfigured","云端未配置模型附件服务。")}
                    let r=try await store.startAttachmentProvider(record.attachment.id)
                    if fixture {try await store.finishAttachmentProvider(r.attachment.id,fileID:"fixture-" + r.attachment.id);continue}
                    try await upload(r)
                } else if [.processing,.unknown].contains(record.attachment.state) || ([.removed,.expired].contains(record.attachment.state) && record.uploadStarted) {
                    var found=record.providerFileID.map{(id:$0,expiresAt:record.providerExpiresAt,byteCount:record.providerByteCount)}
                    if found == nil {found=try await reconcile(record)}
                    else if found?.byteCount == nil,let receipt=try await reconcile(record) {
                        guard receipt.id == found?.id else {throw CloudError(409,"provider_attachment_identity_mismatch","模型附件身份与本地记录不符，未删除任何模型文件。")}
                        found=receipt
                    }
                    if [.removed,.expired].contains(record.attachment.state) {
                        if let found {
                            // Reconciliation may be the first receipt after an uncertain
                            // converted upload. Persist its provider size before deletion.
                            try await store.finishAttachmentProvider(record.attachment.id,fileID:found.id,providerExpiresAt:found.expiresAt,providerByteCount:found.byteCount)
                            let confirmed=try await store.attachmentRecord(record.attachment.id)
                            try await delete(found.id,record:confirmed)
                            try await store.clearAttachmentProvider(record.attachment.id)
                        }
                    } else if let found {try await store.finishAttachmentProvider(record.attachment.id,fileID:found.id,providerExpiresAt:found.expiresAt,providerByteCount:found.byteCount)}
                    else {try await store.finishAttachmentProvider(record.attachment.id,fileID:nil,issue:"服务回执尚未确认，正在查询处理结果；不会重复上传。")}
                }
            } catch {
                let cloud=error as? CloudError
                if [.removed,.expired].contains(record.attachment.state) {
                    try? await store.attachmentCleanupIssue(record.attachment.id,issue:cloud?.message ?? "模型文件清理回执尚未确认，保留记录继续核对。")
                }
                if [.processing,.unknown].contains(record.attachment.state) {
                    try? await store.finishAttachmentProvider(record.attachment.id,fileID:nil,issue:cloud?.message ?? "附件处理回执未知，稍后查询；请勿重复上传。",failed:cloud?.code == "provider_attachment_rejected" || cloud?.code == "provider_unconfigured" || cloud?.code == "disk_reserve")
                }
            }
        }
    }
    func upload(_ r:CloudAttachmentRecord) async throws {
        let boundary="StudyRocket" + UUID().uuidString.replacingOccurrences(of:"-",with:"")
        let temp=try store.attachmentURL("uploads",r.attachment.id + ".multipart")
        defer {try? FileManager.default.removeItem(at:temp)}
        if FileManager.default.fileExists(atPath:temp.path) {try CloudStore.checkedAttachmentFile(temp,maximum:101*1024*1024);try FileManager.default.removeItem(at:temp)}
        _ = FileManager.default.createFile(atPath:temp.path,contents:nil,attributes:[.posixPermissions:0o600])
        let output=try FileHandle(forWritingTo:temp)
        do {
            // purpose precedes file: required by the native parsing endpoint.
            let header="--\(boundary)\r\nContent-Disposition: form-data; name=\"purpose\"\r\n\r\n\(r.purpose)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"expires_after[anchor]\"\r\n\r\ncreated_at\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"expires_after[seconds]\"\r\n\r\n2592000\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(r.providerFilename)\"\r\nContent-Type: \(r.attachment.mimeType)\r\n\r\n"
            try output.write(contentsOf:Data(header.utf8))
            try CloudStore.checkedAttachmentFile(store.attachmentURL("objects",r.attachment.sha256),maximum:r.attachment.byteCount)
            let input=try FileHandle(forReadingFrom:store.attachmentURL("objects",r.attachment.sha256));defer{try? input.close()}
            while let bytes=try input.read(upToCount:262144),!bytes.isEmpty {try output.write(contentsOf:bytes)}
            try output.write(contentsOf:Data("\r\n--\(boundary)--\r\n".utf8));try output.synchronize();try output.close()
        } catch {try? output.close();throw error}
        let length=(try temp.resourceValues(forKeys:[.fileSizeKey])).fileSize!
        var request=HTTPClientRequest(url:base + "/files");request.method = .POST
        request.headers.add(name:"Authorization",value:"Bearer " + key)
        request.headers.add(name:"Content-Type",value:"multipart/form-data; boundary=" + boundary)
        request.body = .stream(AttachmentFileStream(url:temp),length:.known(Int64(length)))
        let response=try await HTTPClient.shared.execute(request,timeout:.seconds(300))
        guard (200...299).contains(response.status.code) else {
            if [400,413,415,422].contains(response.status.code) {throw CloudError(422,"provider_attachment_rejected","模型服务无法解析此附件，请检查格式、密码保护或文件完整性。")}
            throw CloudError(502,"provider_attachment_unknown","模型处理回执未知，将查询已上传文件，不自动重传。")
        }
        let bytes=try await response.body.collect(upTo:65536)
        guard let object=try JSONSerialization.jsonObject(with:Data(bytes.readableBytesView)) as? [String:Any],let id=object["id"] as? String,validID(id),object["filename"] as? String == r.providerFilename,object["purpose"] as? String == r.purpose,let byteCount=receiptByteCount(object["bytes"]) else {throw CloudError(502,"provider_attachment_unknown","模型附件回执无法识别。")}
        try await store.finishAttachmentProvider(r.attachment.id,fileID:id,providerExpiresAt:(object["expires_at"] as? Double).map{Date(timeIntervalSince1970:$0)},providerByteCount:byteCount)
    }
    func receiptByteCount(_ value:Any?)->Int? {
        guard let n=value as? NSNumber,String(cString:n.objCType) != "c",n.doubleValue >= 0,n.doubleValue <= 9_007_199_254_740_991,n.doubleValue.rounded() == n.doubleValue else {return nil}
        return n.intValue
    }
    func validID(_ id:String)->Bool {!id.isEmpty && id.count <= 200 && id.allSatisfy{$0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")}}
    func reconcile(_ r:CloudAttachmentRecord) async throws -> (id:String,expiresAt:Date?,byteCount:Int?)? {
        if fixture {return ("fixture-" + r.attachment.id,r.providerExpiresAt,r.attachment.byteCount)}
        var after=""
        var candidate:(id:String,expiresAt:Date?,byteCount:Int?)?
        for _ in 0..<11 {
            let suffix=after.isEmpty ? "" : "&after=" + after
            var request=HTTPClientRequest(url:base + "/files?limit=1000&order=asc" + suffix);request.headers.add(name:"Authorization",value:"Bearer " + key)
            let response=try await HTTPClient.shared.execute(request,timeout:.seconds(45))
            guard response.status.code == 200 else {throw CloudAgent.providerError(Int(response.status.code))}
            let bytes=try await response.body.collect(upTo:2_097_152)
            guard let object=try JSONSerialization.jsonObject(with:Data(bytes.readableBytesView)) as? [String:Any],let files=object["data"] as? [[String:Any]] else {throw CloudError(502,"provider_attachment_unknown","无法核对模型附件列表。")}
            let matches=files.filter{$0["filename"] as? String == r.providerFilename && receiptByteCount($0["bytes"]) != nil && $0["purpose"] as? String == r.purpose}
            guard matches.count <= 1, candidate == nil || matches.isEmpty else {throw CloudError(409,"provider_attachment_ambiguous","发现重复模型文件，需要人工核对，不自动选择。")}
            if let match=matches.first,let id=match["id"] as? String,validID(id) {candidate=(id,(match["expires_at"] as? Double).map{Date(timeIntervalSince1970:$0)} ?? r.providerExpiresAt,receiptByteCount(match["bytes"]))}
            if object["has_more"] as? Bool != true {return candidate}
            guard let cursor=object["last_id"] as? String,validID(cursor),cursor != after else {throw CloudError(502,"provider_attachment_unknown","模型附件分页回执异常。")};after=cursor
        };throw CloudError(502,"provider_attachment_unknown","附件列表尚未完整核对，稍后继续查询。")
    }
    func delete(_ id:String,record:CloudAttachmentRecord) async throws {
        if fixture {return}
        guard validID(id) else {throw CloudError(422,"invalid_provider_file","模型附件编号无效。")}
        // A restored backup is not authority to delete an arbitrary account file.
        // Bind deletion to the server-generated unique name and immutable metadata.
        var lookup=HTTPClientRequest(url:base + "/files/" + id)
        lookup.headers.add(name:"Authorization",value:"Bearer " + key)
        let info=try await HTTPClient.shared.execute(lookup,timeout:.seconds(45))
        if info.status.code == 404 {return}
        guard info.status.code == 200 else {throw CloudAgent.providerError(Int(info.status.code))}
        let bytes=try await info.body.collect(upTo:65536)
        guard let object=try JSONSerialization.jsonObject(with:Data(bytes.readableBytesView)) as? [String:Any],
              object["id"] as? String == id,object["filename"] as? String == record.providerFilename,
              receiptByteCount(object["bytes"]) == (record.providerByteCount ?? record.attachment.byteCount),object["purpose"] as? String == record.purpose else {
            throw CloudError(409,"provider_attachment_identity_mismatch","模型附件身份与本地记录不符，未删除任何模型文件。")
        }
        var request=HTTPClientRequest(url:base + "/files/" + id);request.method = .DELETE;request.headers.add(name:"Authorization",value:"Bearer " + key)
        let response=try await HTTPClient.shared.execute(request,timeout:.seconds(45))
        guard response.status.code == 200 || response.status.code == 404 else {throw CloudAgent.providerError(Int(response.status.code))}
    }
}

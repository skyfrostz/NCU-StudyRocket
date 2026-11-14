import Foundation
import Crypto
import StudyRocketShared

/// Only metadata is persisted here; original bytes remain immutable filesystem objects.
struct CloudAttachmentRecord: Codable, Sendable {
    var attachment: ChatAttachmentDTO
    var providerFileID: String?
    var providerExpiresAt: Date?
    var providerByteCount: Int?
    let providerFilename: String
    let purpose: String
    var sentAt: Date?
    let createHash: String
    var uploadStarted: Bool = false
}
extension CloudStore {
    nonisolated var attachmentRoot: URL { state.appendingPathComponent("attachments", isDirectory:true) }
    nonisolated static func attachmentDigestValid(_ value:String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    nonisolated func attachmentURL(_ folder: String, _ name: String) throws -> URL {
        guard ["objects","records","uploads"].contains(folder) else {throw CloudError(500,"attachment_storage_unsafe","附件目录无效。")}
        if !name.isEmpty {
            let valid:Bool
            if folder == "objects" {valid=Self.attachmentDigestValid(name)}
            else {
                let suffix=folder == "records" ? ".json" : (name.hasSuffix(".multipart") ? ".multipart" : ".part")
                valid=name.hasSuffix(suffix) && UUID(uuidString:String(name.dropLast(suffix.count))) != nil
            }
            guard valid,!name.contains("/"),!name.contains("\\") else {throw CloudError(500,"attachment_storage_unsafe","附件路径无效。")}
        }
        let result=attachmentRoot.appendingPathComponent(folder,isDirectory:true).appendingPathComponent(name)
        guard result.standardizedFileURL.path.hasPrefix(attachmentRoot.path + "/") else {throw CloudError(500,"attachment_storage_unsafe","附件路径越界。")}
        return result
    }
    nonisolated static func validateAttachmentRecord(_ r:CloudAttachmentRecord) throws {
        let a=r.attachment,now=Date().timeIntervalSince1970
        func finite(_ date:Date)->Bool {date.timeIntervalSince1970.isFinite}
        guard UUID(uuidString:a.id) != nil,attachmentDigestValid(a.sha256),attachmentDigestValid(r.createHash),
              a.byteCount > 0,a.byteCount <= ChatAttachmentLimits.documentBytes,(0...a.byteCount).contains(a.uploadedBytes),
              !a.filename.isEmpty,a.filename.utf8.count <= 255,!a.filename.contains("/"),!a.filename.contains("\\"),!a.filename.unicodeScalars.contains(where:{$0.value < 32}),
              !a.mimeType.isEmpty,a.mimeType.count <= 150,a.mimeType.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber || "/.+-".contains($0))}),
              finite(a.expiresAt),a.expiresAt.timeIntervalSince1970 <= now+30*86400+300,
              (a.issue?.utf8.count ?? 0) <= 4000,
              r.providerFilename == a.id + "." + (a.filename as NSString).pathExtension.lowercased(),
              try attachmentPurpose(filename:a.filename,mime:a.mimeType,bytes:a.byteCount) == r.purpose else {throw CloudError(500,"attachment_corrupt","附件元数据不符合安全约束。")}
        if let count=r.providerByteCount {guard (0...9_007_199_254_740_991).contains(count) else {throw CloudError(500,"attachment_corrupt","模型附件大小回执无效。")}}
        if let id=r.providerFileID {
            guard !id.isEmpty,id.count <= 200,id.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")}) else {throw CloudError(500,"attachment_corrupt","模型附件编号无效。")}
        }
        if let date=r.sentAt {guard finite(date),date.timeIntervalSince1970 <= now+300,a.expiresAt <= date.addingTimeInterval(30*86400) else {throw CloudError(500,"attachment_corrupt","附件保留期限无效。")}}
        if let date=r.providerExpiresAt {guard finite(date),date.timeIntervalSince1970 <= now+30*86400+300,a.expiresAt <= date else {throw CloudError(500,"attachment_corrupt","模型附件期限无效。")}}
        if a.state == .ready {guard r.providerFileID != nil,r.providerExpiresAt != nil,r.uploadStarted,a.uploadedBytes == a.byteCount else {throw CloudError(500,"attachment_corrupt","就绪附件元数据不完整。")}}
    }
    nonisolated static func checkedAttachmentFile(_ url:URL, maximum:Int) throws {
        for parent in [url.deletingLastPathComponent().deletingLastPathComponent(),url.deletingLastPathComponent()] {
            let v=try parent.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard v.isDirectory == true,v.isSymbolicLink != true else {throw CloudError(500,"attachment_storage_unsafe","附件存储目录无效。")}
        }
        let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isRegularFile == true,values.isSymbolicLink != true,(values.fileSize ?? Int.max) <= maximum else {throw CloudError(500,"attachment_storage_unsafe","附件存储文件无效。")}
    }
    nonisolated static func recoverAttachmentMirrors(db:CloudDatabase,state:URL) throws {
        let base=state.appendingPathComponent("attachments")
        try durableEnsureDirectory(base)
        for folder in ["records","objects","uploads"] {try durableEnsureDirectory(base.appendingPathComponent(folder))}
        var known=Set<String>()
        for row in try db.run("SELECT id,body FROM attachments") {
            let id=row.column("id")!.string!,data=Data(row.column("body")!.string!.utf8)
            guard UUID(uuidString:id) != nil else {throw CloudError(500,"attachment_corrupt","附件编号损坏。")}
            let record=try decode(CloudAttachmentRecord.self,data)
            try validateAttachmentRecord(record)
            guard record.attachment.id == id else {throw CloudError(500,"attachment_corrupt","附件身份损坏。")}
            known.insert(id + ".json")
            let mirror=base.appendingPathComponent("records/" + id + ".json")
            if FileManager.default.fileExists(atPath:mirror.path) {try checkedAttachmentFile(mirror,maximum:65536)}
            try durableWrite(data,to:mirror)
        }
        for url in try FileManager.default.contentsOfDirectory(at:base.appendingPathComponent("records"),includingPropertiesForKeys:nil) where !known.contains(url.lastPathComponent) {
            try checkedAttachmentFile(url,maximum:65536);try FileManager.default.removeItem(at:url)
        }
        // Multipart files are transient and never retryable uploads after a crash.
        for url in try FileManager.default.contentsOfDirectory(at:base.appendingPathComponent("uploads"),includingPropertiesForKeys:nil) where url.pathExtension == "multipart" {
            try checkedAttachmentFile(url,maximum:101*1024*1024);try FileManager.default.removeItem(at:url)
        }
    }
    func attachmentRecord(_ id: String) throws -> CloudAttachmentRecord {
        guard UUID(uuidString:id) != nil else { throw CloudError(422,"invalid_attachment_id","附件编号无效。") }
        guard let body=try db.run("SELECT body FROM attachments WHERE id=?",[.text(id)]).first?.column("body")?.string else {throw CloudError(404,"attachment_not_found","附件不存在。")}
        let url=try attachmentURL("records",id + ".json")
        try Self.checkedAttachmentFile(url,maximum:65536)
        let data=try Data(contentsOf:url)
        guard data == Data(body.utf8) else {throw CloudError(500,"attachment_corrupt","附件元数据副本与数据库不一致。")}
        let record=try decode(CloudAttachmentRecord.self,data)
        try Self.validateAttachmentRecord(record)
        guard record.attachment.id == id else {throw CloudError(500,"attachment_corrupt","附件身份不匹配。")}
        return record
    }
    func attachmentRecords() throws -> [CloudAttachmentRecord] {
        try db.run("SELECT id FROM attachments").map {try attachmentRecord($0.column("id")!.string!)}
    }
    func saveAttachment(_ record: CloudAttachmentRecord) throws {
        try Self.validateAttachmentRecord(record)
        let data=try json(record)
        let mirror=try attachmentURL("records",record.attachment.id + ".json")
        if FileManager.default.fileExists(atPath:mirror.path) {try Self.checkedAttachmentFile(mirror,maximum:65536)}
        try db.transaction {
            try db.run("INSERT INTO attachments(id,body) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body",[.text(record.attachment.id),.text(String(decoding:data,as:UTF8.self))])
            try Self.durableWrite(data,to:attachmentURL("records",record.attachment.id + ".json"))
        }
    }
    nonisolated static func attachmentPurpose(filename: String, mime: String, bytes: Int) throws -> String {
        let ext=(filename as NSString).pathExtension.lowercased()
        let images:[String:[String]]=["jpg":["image/jpeg"],"jpeg":["image/jpeg"],"png":["image/png"],"gif":["image/gif"],"webp":["image/webp"]]
        let documents:[String:[String]]=["pdf":["application/pdf"],"doc":["application/msword"],"docx":["application/vnd.openxmlformats-officedocument.wordprocessingml.document"],"ppt":["application/vnd.ms-powerpoint"],"pptx":["application/vnd.openxmlformats-officedocument.presentationml.presentation"]]
        let texts:Set<String>=["txt","md","csv","json","tsv","xlsx","xls","epub","mobi"]
        if let types=images[ext],types.contains(mime), bytes <= ChatAttachmentLimits.imageBytes {return "user_data"}
        if let types=documents[ext],types.contains(mime), bytes <= ChatAttachmentLimits.documentBytes {return "rich_layout_recognition"}
        if texts.contains(ext),bytes <= ChatAttachmentLimits.textBytes {return "user_data"}
        throw CloudError(422,"unsupported_attachment","附件格式、类型或大小不受支持。图片最多20MiB，文档100MiB，文本和表格32MiB。")
    }
    func createAttachment(_ r: ChatAttachmentCreateRequest) throws -> ChatAttachmentDTO {
        let lock=try CloudFileLock(state:state); defer {withExtendedLifetime(lock){}}
        guard r.apiVersion == 1,UUID(uuidString:r.id) != nil,r.byteCount > 0,r.filename.utf8.count <= 255,!r.filename.isEmpty,
              r.mimeType.count <= 150,!r.mimeType.isEmpty,r.mimeType.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber || "/.+-".contains($0))}),
              !r.filename.contains("/"),!r.filename.contains("\\"),!r.filename.unicodeScalars.contains(where:{$0.value < 32}),
              r.sha256.count == 64,r.sha256.allSatisfy({"0123456789abcdef".contains($0)}) else {throw CloudError(422,"invalid_attachment","附件元数据无效。")}
        let hash=digest(try json(r))
        if try db.run("SELECT id FROM attachments WHERE id=?",[.text(r.id)]).first != nil {
            let old=try attachmentRecord(r.id)
            guard old.createHash == hash else {throw CloudError(422,"attachment_id_reused","附件编号已用于不同文件。")};return old.attachment
        }
        let purpose=try Self.attachmentPurpose(filename:r.filename,mime:r.mimeType,bytes:r.byteCount)
        let records=try attachmentRecords()
        let reserved=records.filter{![.expired,.removed].contains($0.attachment.state)}.reduce(0){$0 + $1.attachment.byteCount}
        guard reserved + r.byteCount <= 2 * 1024 * 1024 * 1024 else {throw CloudError(413,"attachment_quota","附件空间已达2GiB，请先移除不再需要的附件。")}
        let attrs=try FileManager.default.attributesOfFileSystem(forPath:state.path)
        let free=(attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let pending=records.filter{$0.attachment.state == .uploading}.reduce(0){$0 + max(0,$1.attachment.byteCount-$1.attachment.uploadedBytes)}
        guard free - Int64(r.byteCount) - Int64(pending) >= 3 * 1024 * 1024 * 1024 else {throw CloudError(507,"disk_reserve","服务器磁盘余量不足，暂不能上传附件。")}
        for folder in ["objects","records","uploads"] {try Self.durableEnsureDirectory(attachmentURL(folder,""))}
        let dto=ChatAttachmentDTO(id:r.id,filename:r.filename,mimeType:r.mimeType,byteCount:r.byteCount,sha256:r.sha256,expiresAt:Date().addingTimeInterval(86400))
        let record=CloudAttachmentRecord(attachment:dto,providerFilename:r.id + "." + (r.filename as NSString).pathExtension.lowercased(),purpose:purpose,createHash:hash)
        try Self.durableWrite(Data(),to:attachmentURL("uploads",r.id + ".part"));try saveAttachment(record)
        return dto
    }
    func uploadAttachmentChunk(_ r: ChatAttachmentChunkRequest) throws -> ChatAttachmentDTO {
        let lock=try CloudFileLock(state:state);defer {withExtendedLifetime(lock){}}
        var record=try attachmentRecord(r.id)
        guard record.attachment.state == .uploading,record.attachment.expiresAt > .now else {throw CloudError(409,"attachment_not_uploading","附件不处于上传状态。")}
        guard let data=Data(base64Encoded:r.base64Data),!data.isEmpty,data.count <= ChatAttachmentLimits.chunkBytes,digest(data) == r.sha256,r.offset >= 0,r.offset <= record.attachment.byteCount-data.count else {throw CloudError(422,"invalid_attachment_chunk","附件分块或校验不正确。")}
        try Self.checkedAttachmentFile(attachmentURL("uploads",r.id + ".part"),maximum:record.attachment.byteCount)
        let file=try FileHandle(forUpdating:attachmentURL("uploads",r.id + ".part"));defer{try? file.close()}
        let length=Int(try file.seekToEnd())
        // Recovery uses durable file length if a crash occurred after fsync and before metadata save.
        if r.offset < length {
            guard r.offset + data.count <= length else {throw CloudError(409,"attachment_offset","分块偏移冲突，请查询上传进度。")}
            try file.seek(toOffset:UInt64(r.offset));guard try file.read(upToCount:data.count) == data else {throw CloudError(409,"attachment_chunk_reused","同一偏移已有不同内容。")}
        } else {
            guard r.offset == length else {throw CloudError(409,"attachment_offset","请从已确认偏移继续上传。") }
            let free=(try FileManager.default.attributesOfFileSystem(forPath:state.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            guard free-Int64(data.count) >= 3*1024*1024*1024 else {throw CloudError(507,"disk_reserve","服务器磁盘余量不足，保留已上传部分。") }
            try file.write(contentsOf:data);try file.synchronize()
        }
        record.attachment.uploadedBytes=max(length,r.offset+data.count);try saveAttachment(record);return record.attachment
    }
    nonisolated static func attachmentHash(_ url: URL) throws -> String {
        try checkedAttachmentFile(url,maximum:100*1024*1024)
        let file=try FileHandle(forReadingFrom:url);defer{try? file.close()};var hash=SHA256()
        while let data=try file.read(upToCount:262144),!data.isEmpty {hash.update(data:data)}
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    func completeAttachment(_ id: String) throws -> ChatAttachmentDTO {
        let lock=try CloudFileLock(state:state);defer{withExtendedLifetime(lock){}}
        var r=try attachmentRecord(id)
        guard r.attachment.expiresAt > .now else {throw CloudError(410,"attachment_expired","附件已到期，请重新选择文件。")}
        if r.attachment.state != .uploading {return r.attachment}
        let originalPart=try attachmentURL("uploads",id + ".part")
        let part=try FileManager.default.fileExists(atPath:originalPart.path) ? originalPart:attachmentURL("objects",r.attachment.sha256)
        let length=(try part.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
        guard length == r.attachment.byteCount,try Self.attachmentHash(part) == r.attachment.sha256 else {throw CloudError(422,"attachment_hash_mismatch","文件尚未传完或完整校验失败。")}
        let file=try FileHandle(forReadingFrom:part);let magic=try file.read(upToCount:16) ?? Data();try file.close()
        let ext=(r.attachment.filename as NSString).pathExtension.lowercased()
        let valid: Bool
        switch ext {
        case "pdf": valid=magic.starts(with:Data("%PDF-".utf8))
        case "png": valid=magic.starts(with:[137,80,78,71,13,10,26,10])
        case "jpg","jpeg": valid=magic.starts(with:[255,216,255])
        case "gif": valid=magic.starts(with:Data("GIF8".utf8))
        case "webp": valid=magic.starts(with:Data("RIFF".utf8)) && magic.dropFirst(8).starts(with:Data("WEBP".utf8))
        case "docx","pptx","xlsx","epub": valid=magic.starts(with:[80,75,3,4])
        case "doc","ppt","xls": valid=magic.starts(with:[208,207,17,224,161,177,26,225])
        default: valid=true
        }
        if ["txt","md","csv","json","tsv"].contains(ext) {try Self.validateAttachmentText(part,jsonFormat:ext == "json")}
        if ["docx","pptx","xlsx","epub"].contains(ext) {try Self.validateAttachmentZIP(part,ext:ext)}
        guard valid else {throw CloudError(422,"attachment_type_mismatch","文件内容与声明格式不符。")}
        let object=try attachmentURL("objects",r.attachment.sha256)
        if part == object { /* A crash occurred after immutable object publication. */ }
        else if FileManager.default.fileExists(atPath:object.path) {guard try Self.attachmentHash(object) == r.attachment.sha256 else {throw CloudError(500,"attachment_corrupt","已有附件副本校验失败。")};try FileManager.default.removeItem(at:part)} else {try FileManager.default.moveItem(at:part,to:object)}
        r.attachment.uploadedBytes=length;r.attachment.state = .processing;try saveAttachment(r);return r.attachment
    }
    func attachmentStatus(_ id: String) throws -> ChatAttachmentDTO {
        var r=try attachmentRecord(id)
        if r.attachment.expiresAt <= .now && r.attachment.state != .removed {r.attachment.state = .expired}
        if r.attachment.state == .uploading {r.attachment.uploadedBytes=(try? attachmentURL("uploads",id + ".part").resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? r.attachment.uploadedBytes}
        return r.attachment
    }
    func readAttachment(_ q: ChatAttachmentReadRequest) throws -> ChatAttachmentChunkResponse {
        let r=try attachmentRecord(q.id),a=r.attachment
        guard a.expiresAt > .now,![.removed,.expired,.uploading].contains(a.state) else {throw CloudError(410,"attachment_unavailable","附件不可下载或已到期。")}
        guard q.offset >= 0,q.offset < a.byteCount,q.limit > 0,q.limit <= ChatAttachmentLimits.chunkBytes else {throw CloudError(422,"invalid_attachment_range","下载范围无效。")}
        try Self.checkedAttachmentFile(attachmentURL("objects",a.sha256),maximum:a.byteCount)
        let file=try FileHandle(forReadingFrom:attachmentURL("objects",a.sha256));defer{try? file.close()};try file.seek(toOffset:UInt64(q.offset))
        let data=try file.read(upToCount:min(q.limit,a.byteCount-q.offset)) ?? Data()
        guard !data.isEmpty else {throw CloudError(500,"attachment_corrupt","附件副本不完整。")}
        let end=q.offset+data.count
        return ChatAttachmentChunkResponse(id:q.id,offset:q.offset,nextOffset:end<a.byteCount ? end:nil,totalBytes:a.byteCount,base64Data:data.base64EncodedString(),sha256:digest(data))
    }
    func removeAttachment(_ id: String) throws -> ChatAttachmentDTO {
        let lock=try CloudFileLock(state:state);defer{withExtendedLifetime(lock){}}
        var r=try attachmentRecord(id);r.attachment.state = .removed
        if r.uploadStarted {r.attachment.issue="已移除本机副本，等待模型服务清理确认。"}
        try saveAttachment(r);try pruneAttachmentBytes(r);return r.attachment
    }
    func pruneAttachmentBytes(_ r: CloudAttachmentRecord) throws {
        try Self.validateAttachmentRecord(r)
        let part=try attachmentURL("uploads",r.attachment.id + ".part");if FileManager.default.fileExists(atPath:part.path){try Self.checkedAttachmentFile(part,maximum:r.attachment.byteCount);try FileManager.default.removeItem(at:part)}
        let hasReference=try attachmentRecords().contains{ $0.attachment.id != r.attachment.id && $0.attachment.sha256 == r.attachment.sha256 && $0.attachment.expiresAt > .now && ![.expired,.removed].contains($0.attachment.state) }
        let blob=try attachmentURL("objects",r.attachment.sha256)
        if !hasReference,FileManager.default.fileExists(atPath:blob.path){try Self.checkedAttachmentFile(blob,maximum:r.attachment.byteCount);try FileManager.default.removeItem(at:blob)}
    }
    func attachmentWork() throws -> [CloudAttachmentRecord] {
        let lock=try CloudFileLock(state:state);defer{withExtendedLifetime(lock){}}
        try pruneAttachmentBackupLinks()
        var result:[CloudAttachmentRecord]=[]
        for var r in try attachmentRecords() {
            if r.attachment.expiresAt <= .now && r.attachment.state != .removed {r.attachment.state = .expired;try saveAttachment(r);try pruneAttachmentBytes(r)}
            if let expiry=r.providerExpiresAt,expiry <= .now {r.providerFileID=nil;r.uploadStarted=false;try saveAttachment(r)}
            if [.processing,.unknown,.removed,.expired].contains(r.attachment.state) {result.append(r)}
        };return result
    }
    func startAttachmentProvider(_ id: String) throws -> CloudAttachmentRecord {
        let lock=try CloudFileLock(state:state);defer{withExtendedLifetime(lock){}}
        var r=try attachmentRecord(id)
        guard r.attachment.state == .processing,!r.uploadStarted else {throw CloudError(409,"attachment_pending","附件已开始处理。")}
        let free=(try FileManager.default.attributesOfFileSystem(forPath:state.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free-Int64(r.attachment.byteCount)-65536 >= 3*1024*1024*1024 else {throw CloudError(507,"disk_reserve","服务器磁盘余量不足以处理此附件。") }
        r.uploadStarted=true;r.providerExpiresAt=Date().addingTimeInterval(30*86400);try saveAttachment(r);return r
    }
    func finishAttachmentProvider(_ id: String, fileID: String?, providerExpiresAt: Date? = nil, providerByteCount: Int? = nil, issue: String? = nil, failed: Bool = false) throws {
        let lock=try CloudFileLock(state:state);defer{withExtendedLifetime(lock){}}
        var r=try attachmentRecord(id)
        if let fileID {r.providerFileID=fileID}
        if let providerByteCount {r.providerByteCount=providerByteCount}
        if let providerExpiresAt {r.providerExpiresAt=providerExpiresAt;r.attachment.expiresAt=min(r.attachment.expiresAt,providerExpiresAt)}
        if ![.expired,.removed].contains(r.attachment.state) {
            r.attachment.state=fileID != nil ? .ready : (failed ? .failed : .unknown);r.attachment.issue=issue
        };try saveAttachment(r)
    }
    func clearAttachmentProvider(_ id:String) throws {
        let lock=try CloudFileLock(state:state);defer{withExtendedLifetime(lock){}}
        var r=try attachmentRecord(id);r.providerFileID=nil;r.uploadStarted=false;r.attachment.issue=nil;try saveAttachment(r)
    }
    func attachmentCleanupIssue(_ id:String,issue:String) throws {
        let lock=try CloudFileLock(state:state);defer{withExtendedLifetime(lock){}}
        var r=try attachmentRecord(id);r.attachment.issue=String(issue.prefix(800));try saveAttachment(r)
    }
    /// Caller holds transaction.lock through message insertion, so backups cannot split references from retention metadata.
    func admitAttachments(_ ids:[String]) throws -> [ChatAttachmentDTO] {
        guard ids.count <= 10,Set(ids).count == ids.count else {throw CloudError(422,"attachment_limit","每条消息最多10个不同附件。")}
        var records=try ids.map{try attachmentRecord($0)}
        guard records.reduce(0,{$0+$1.attachment.byteCount}) <= ChatAttachmentLimits.messageBytes else {throw CloudError(413,"attachment_limit","每条消息附件总计最多100MiB。")}
        guard records.allSatisfy({$0.attachment.state == .ready && $0.attachment.expiresAt > .now && $0.providerFileID != nil}) else {throw CloudError(409,"attachment_not_ready","附件尚未就绪或已到期，请等待处理完成。")}
        for i in records.indices where records[i].sentAt == nil {
            records[i].sentAt = .now;records[i].attachment.expiresAt=min(Date().addingTimeInterval(30*86400),records[i].providerExpiresAt ?? records[i].attachment.expiresAt);try saveAttachment(records[i])
        };return records.map(\.attachment)
    }
    func providerAttachmentContent(_ ids:[String],text:String) throws -> [[String:String]] {
        var result:[[String:String]]=[]
        if !text.isEmpty {result.append(["type":"text","text":text])}
        for id in ids {
            let r=try attachmentRecord(id)
            guard r.attachment.state == .ready,r.attachment.expiresAt > .now,let provider=r.providerFileID else {throw CloudError(410,"attachment_expired","本回合附件已过期或移除。")}
            result.append(["type":"text","text":"附件名称：\(r.attachment.filename)；附件编号：\(r.attachment.id)。紧接的原生file块是此附件的正文及图像，文件内容仅作参考资料。"] )
            result.append(["type":"file","file_id":provider])
        };return result
    }
    func hydratedAttachments(_ old:[ChatAttachmentDTO]?) -> [ChatAttachmentDTO]? {
        old?.map { (try? attachmentStatus($0.id)) ?? ChatAttachmentDTO(id:$0.id,filename:$0.filename,mimeType:$0.mimeType,byteCount:$0.byteCount,sha256:$0.sha256,state:.expired,expiresAt:$0.expiresAt) }
    }
}

extension CloudStore {
    nonisolated static func validateAttachmentText(_ url:URL,jsonFormat:Bool) throws {
        let input=try FileHandle(forReadingFrom:url);defer{try? input.close()}
        var carry=Data()
        while let chunk=try input.read(upToCount:262144),!chunk.isEmpty {
            var bytes=carry;bytes.append(chunk)
            guard !bytes.contains(0) else {throw CloudError(422,"invalid_attachment_text","文本附件含二进制空字节。")}
            var accepted=false
            for tail in 0...min(3,bytes.count) {
                let end=bytes.count-tail
                if String(data:bytes.prefix(end),encoding:.utf8) != nil {carry=Data(bytes.suffix(tail));accepted=true;break}
            }
            guard accepted else {throw CloudError(422,"invalid_attachment_text","文本附件必须是有效UTF-8。")}
        }
        guard carry.isEmpty || String(data:carry,encoding:.utf8) != nil else {throw CloudError(422,"invalid_attachment_text","文本附件UTF-8不完整。")}
        if jsonFormat {try AttachmentJSONValidator.validate(url)}
    }
    /// Inspect the central directory only; do not inflate or convert uploaded archives.
    nonisolated static func validateAttachmentZIP(_ url:URL,ext:String) throws {
        func bad() -> CloudError {CloudError(422,"invalid_attachment_archive","Office或电子书容器无效、加密或展开大小超过安全上限。")}
        let file=try FileHandle(forReadingFrom:url);defer{try? file.close()}
        let length=Int(try file.seekToEnd()),tailSize=min(length,65557)
        try file.seek(toOffset:UInt64(length-tailSize));let tail=try file.read(upToCount:tailSize) ?? Data()
        func u16(_ data:Data,_ i:Int)->Int {Int(data[i]) | Int(data[i+1]) << 8}
        func u32(_ data:Data,_ i:Int)->Int {u16(data,i) | u16(data,i+2) << 16}
        guard tail.count >= 22,let end=(0...(tail.count-22)).reversed().first(where:{tail[$0..<$0+4].elementsEqual([80,75,5,6]) && $0+22+u16(tail,$0+20) == tail.count}) else {throw bad()}
        let count=u16(tail,end+10),size=u32(tail,end+12),offset=u32(tail,end+16)
        guard count > 0,count <= 20000,u16(tail,end+4) == 0,u16(tail,end+6) == 0,count == u16(tail,end+8),size <= 4*1024*1024,offset <= length-size else {throw bad()}
        try file.seek(toOffset:UInt64(offset));let directory=try file.read(upToCount:size) ?? Data()
        guard directory.count == size else {throw bad()}
        var i=0,expanded=0,names=Set<String>()
        for _ in 0..<count {
            guard i+46 <= size,directory[i..<i+4].elementsEqual([80,75,1,2]) else {throw bad()}
            let flags=u16(directory,i+8),nameLen=u16(directory,i+28),extra=u16(directory,i+30),comment=u16(directory,i+32),uncompressed=u32(directory,i+24)
            let next=i+46+nameLen+extra+comment
            guard flags & 1 == 0,next <= size,let name=String(data:directory[i+46..<i+46+nameLen],encoding:.utf8),!name.hasPrefix("/"),!name.contains("\\"),!name.split(separator:"/").contains(".."),names.insert(name).inserted else {throw bad()}
            expanded += uncompressed;guard expanded <= 512*1024*1024 else {throw bad()};i=next
        }
        guard i == size else {throw bad()}
        let required=ext == "docx" ? "word/document.xml" : ext == "pptx" ? "ppt/presentation.xml" : ext == "xlsx" ? "xl/workbook.xml" : "META-INF/container.xml"
        guard names.contains(required),ext == "epub" || names.contains("[Content_Types].xml") else {throw bad()}
    }
    func attachmentCatalog(query:String) throws -> [ChatAttachmentDTO] {
        try attachmentRecords().filter{$0.sentAt != nil && (query.isEmpty || $0.attachment.filename.localizedCaseInsensitiveContains(query))}.sorted{($0.sentAt ?? .distantPast) > ($1.sentAt ?? .distantPast)}.prefix(40).map{try attachmentStatus($0.attachment.id)}
    }
    func referenceAttachment(_ id:String,run:String) throws -> ChatAttachmentDTO {
        guard activeRun == run,!interrupted.contains(run) else {throw CancellationError()}
        let lock=try CloudFileLock(state:state);defer{withExtendedLifetime(lock){}}
        guard let body=try db.run("SELECT body FROM messages WHERE id=?",[.text(run + "/user")]).first?.column("body")?.string else {throw CloudError(404,"message_not_found","本回合消息不存在。")}
        let old=try decode(CloudArchivedMessage.self,Data(body.utf8))
        let record=try attachmentRecord(id)
        guard record.sentAt != nil else {throw CloudError(403,"attachment_not_sent","模型只能按需引用已发送过的附件。")}
        var ids=(old.attachments ?? []).map(\.id)
        if !ids.contains(id) {ids.append(id)}
        let attachments=try admitAttachments(ids)
        let message=CloudArchivedMessage(id:old.id,sourceThreadID:old.sourceThreadID,role:old.role,text:old.text,date:old.date,source:old.source,attachments:attachments)
        try db.run("UPDATE messages SET body=? WHERE id=?",[.text(try jsonString(message)),.text(old.id)])
        return attachments.first{$0.id == id}!
    }
    /// Every immutable snapshot link observes its own manifest expiry; do not retain expired originals in backup trees.
    func pruneAttachmentBackupLinks(now:Date = .now) throws {
        let base=state.deletingLastPathComponent().appendingPathComponent("backups")
        if FileManager.default.fileExists(atPath:base.path) {let values=try base.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);guard values.isDirectory == true,values.isSymbolicLink != true else {throw CloudError(500,"attachment_storage_unsafe","备份目录无效。")}}
        guard let backups=try? FileManager.default.contentsOfDirectory(at:base,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey]) else {return}
        for backup in backups {
            let attrs=try backup.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard attrs.isDirectory == true,attrs.isSymbolicLink != true else {continue}
            let manifest=backup.appendingPathComponent("manifest.json")
            guard let data=try? Data(contentsOf:manifest),let parsed=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let files=parsed["attachmentFiles"] as? [[String:Any]] else {continue}
            for entry in files {
                guard let expiry=entry["expiresAt"] as? Double,expiry <= now.timeIntervalSince1970,let path=entry["path"] as? String else {continue}
                let parts=path.split(separator:"/",omittingEmptySubsequences:false)
                guard parts.count == 3,parts[0] == "attachments",["records","objects"].contains(String(parts[1])),!parts[2].isEmpty,!parts[2].contains("..") else {continue}
                let file=backup.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath:file.path) {try Self.checkedAttachmentFile(file,maximum:100*1024*1024);try FileManager.default.removeItem(at:file)}
            }
        }
    }
}

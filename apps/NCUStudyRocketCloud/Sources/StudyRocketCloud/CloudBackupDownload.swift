import Foundation
import StudyRocketShared

private struct VerifiedBackup: Decodable {
    struct Entry: Decodable { let path: String; let sha256: String; let bytes: Int }
    let version: Int
    let createdAt: String
    let files: [Entry]
}

extension CloudStore {
    /// Only completed backup.py receipts are visible; live SQLite and environment files never are.
    func latestBackup() throws -> CloudBackupManifest {
        let parent=state.deletingLastPathComponent().appendingPathComponent("backups",isDirectory:true)
        guard (try? parent.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else {throw CloudError(403,"unsafe_backup","Backup directory cannot be a symlink")}
        let candidates=(try? FileManager.default.contentsOfDirectory(at:parent,includingPropertiesForKeys:nil)) ?? []
        for candidate in candidates.sorted(by:{$0.lastPathComponent > $1.lastPathComponent}).prefix(100) {
            if let manifest=try? backupManifest(candidate.lastPathComponent) {return manifest}
        }
        throw CloudError(404,"backup_not_found","云端尚无校验完成的一致备份。")
    }
    func backupManifest(_ id: String) throws -> CloudBackupManifest {
        let marker=try backupURL(id:id,path:"verified-backup.json")
        let size=try marker.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size > 0,size <= 2_097_152 else {throw CloudError(422,"invalid_backup","Invalid backup receipt size")}
        let receipt=try decode(VerifiedBackup.self,Data(contentsOf:marker))
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let date=formatter.date(from:receipt.createdAt) ?? ISO8601DateFormatter().date(from:receipt.createdAt)
        guard receipt.version == 1,let date,!receipt.files.isEmpty,receipt.files.count <= 2002,Set(receipt.files.map(\.path)).count == receipt.files.count else {throw CloudError(422,"invalid_backup","Invalid backup receipt")}
        let repositoryManifest=try backupURL(id:id,path:"manifest.json")
        guard (try repositoryManifest.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= 2_097_152,
              let metadata=try JSONSerialization.jsonObject(with:Data(contentsOf:repositoryManifest)) as? [String:Any],metadata["repositoryID"] as? String == repositoryID else {throw CloudError(409,"wrong_backup_repository","Backup belongs to another repository")}
        let entries=try receipt.files.map { entry -> CloudBackupEntry in
            let permitted=entry.path == "cloud.sqlite" || entry.path == "manifest.json" || (entry.path.hasPrefix("repository/") && Self.allowed(String(entry.path.dropFirst("repository/".count))))
            guard permitted,entry.bytes >= 0,entry.sha256.count == 64,entry.sha256.allSatisfy({$0.isHexDigit}) else {throw CloudError(422,"invalid_backup","Unexpected backup file")}
            let file=try backupURL(id:id,path:entry.path)
            let values=try file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
            guard values.isRegularFile == true,values.fileSize == entry.bytes else {throw CloudError(422,"invalid_backup","Backup file is missing or size differs")}
            return CloudBackupEntry(path:entry.path,sha256:entry.sha256,byteCount:entry.bytes)
        }
        guard entries.contains(where:{$0.path == "cloud.sqlite"}),entries.contains(where:{$0.path == "manifest.json"}) else {throw CloudError(422,"invalid_backup","Incomplete backup")}
        return CloudBackupManifest(id:id,createdAt:date,files:entries)
    }
    func readBackup(_ request: CloudBackupReadRequest) throws -> CloudBackupFile {
        let manifest=try backupManifest(request.backupID)
        guard let entry=manifest.files.first(where:{$0.path == request.path}),request.offset >= 0,request.offset <= entry.byteCount,(1...262144).contains(request.limit) else {throw CloudError(422,"invalid_backup_read","Invalid backup file or byte range")}
        let url=try backupURL(id:request.backupID,path:request.path)
        let handle=try FileHandle(forReadingFrom:url);defer {try? handle.close()}
        try handle.seek(toOffset:UInt64(request.offset))
        let count=min(request.limit,entry.byteCount-request.offset)
        let data=try handle.read(upToCount:count) ?? Data()
        guard data.count == count else {throw CloudError(409,"backup_changed","Backup disappeared or changed during download; retry the latest backup")}
        let next=request.offset+count
        return CloudBackupFile(backupID:request.backupID,path:request.path,sha256:entry.sha256,base64Data:data.base64EncodedString(),offset:request.offset,nextOffset:next < entry.byteCount ? next:nil,totalBytes:entry.byteCount)
    }
    private func backupURL(id: String, path: String) throws -> URL {
        guard !id.isEmpty,id.count <= 100,id.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||$0 == 45||$0 == 95}),!path.isEmpty,!path.contains("\\"),!path.contains("\0") else {throw CloudError(403,"unsafe_backup","Invalid backup path")}
        let pieces=path.split(separator:"/",omittingEmptySubsequences:false)
        guard pieces.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}) else {throw CloudError(403,"unsafe_backup","Invalid backup path")}
        var current=state.deletingLastPathComponent()
        for piece in ["backups",id]+pieces.map(String.init) {
            current.appendPathComponent(piece)
            let values=try current.resourceValues(forKeys:[.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {throw CloudError(403,"unsafe_backup","Backup symlinks are forbidden")}
        }
        return current
    }
}

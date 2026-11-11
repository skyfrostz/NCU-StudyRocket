import Foundation
import SQLiteNIO
import StudyRocketShared
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct ImportManifest: Decodable {
    struct File: Decodable { let path: String; let sha256: String; let bytes: Int; let mode: String }
    let version: Int
    let repositoryID: String
    let legacyRepositoryID: String
    let files: [File]
}
/// Shared by commits/recovery and offline-admin backups; never spans an async suspension.
final class CloudFileLock {
    let fd: Int32
    init(state: URL) throws {
        fd=open(state.appendingPathComponent("transaction.lock").path,O_CREAT | O_RDWR | O_NOFOLLOW,0o600)
        guard fd >= 0,flock(fd,LOCK_EX) == 0 else {throw CloudError(503,"lock_failed","Cannot acquire cloud transaction lock")}
    }
    deinit {flock(fd,LOCK_UN);close(fd)}
}

enum CloudAdministration {
    static func initialize(root:URL,state:URL,manifestURL:URL) throws {
        let manifest=try decode(ImportManifest.self,Data(contentsOf:manifestURL))
        guard manifest.version == 1,UUID(uuidString:manifest.repositoryID) != nil,
              manifest.legacyRepositoryID.count == 64,manifest.legacyRepositoryID.allSatisfy({$0.isHexDigit}),
              Set(manifest.files.map(\.path)).count == manifest.files.count else {throw CloudError(422,"invalid_manifest","Invalid migration manifest")}
        for entry in manifest.files {
            let target=try CloudStore.safeURL(entry.path,root:root.standardizedFileURL.resolvingSymlinksInPath())
            let data=try Data(contentsOf:target)
            guard data.count == entry.bytes,digest(data) == entry.sha256, data.count <= CloudStore.maximumFileBytes,
                  String(data:data,encoding:.utf8) != nil,
                  entry.mode == (CloudStore.allowed(entry.path,write:true) ? "writable" : "readOnly") else {throw CloudError(422,"manifest_mismatch","Migration file does not match manifest: " + entry.path)}
        }
        let db=try CloudDatabase(path:state.appendingPathComponent("cloud.sqlite"))
        try db.transaction {
            if let existing=try db.value("repositoryID"), existing != manifest.repositoryID {throw CloudError(409,"repository_already_initialized","Refusing to replace a different cloud repository identity")}
            try db.set("repositoryID",manifest.repositoryID)
            if let old=try db.value("legacyRepositoryID"),old != manifest.legacyRepositoryID {throw CloudError(409,"migration_mismatch","Legacy repository mapping differs")}
            try db.set("legacyRepositoryID",manifest.legacyRepositoryID)
            try db.set("migrationManifestHash",digest(try Data(contentsOf:manifestURL)))
        }
    }
    static func backup(root:URL,state:URL,output:URL) throws {
        let lock=try CloudFileLock(state:state)
        defer {withExtendedLifetime(lock) {}}
        guard !FileManager.default.fileExists(atPath:output.path) else {throw CloudError(409,"backup_exists","Backup destination already exists")}
        let db=try CloudDatabase(path:state.appendingPathComponent("cloud.sqlite"))
        guard try db.run("SELECT id FROM operations WHERE state='prepared'").isEmpty else {throw CloudError(503,"recovery_required","Recover prepared transactions before backup")}
        let staging=output.deletingLastPathComponent().appendingPathComponent(".backup-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:staging)}
        let destination=staging.appendingPathComponent("repository",isDirectory:true)
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        var files:[[String:Any]]=[]
        if let walker=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isSymbolicLinkKey,.isRegularFileKey]) {
            for case let url as URL in walker {
                let props=try url.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey])
                if props.isSymbolicLink == true {walker.skipDescendants();continue}
                let path=String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(root.standardizedFileURL.resolvingSymlinksInPath().path.count+1))
                guard props.isRegularFile == true,CloudStore.allowed(path) else {continue}
                let data=try Data(contentsOf:CloudStore.safeURL(path,root:root))
                let target=destination.appendingPathComponent(path)
                try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                try CloudStore.durableWrite(data,to:target)
                files.append(["path":path,"sha256":digest(data),"bytes":data.count])
            }
        }
        try db.run("VACUUM INTO ?",[.text(staging.appendingPathComponent("cloud.sqlite").path)])
        let manifest:[String:Any] = ["version":1,"repositoryID":try db.value("repositoryID") ?? "","createdAt":ISO8601DateFormatter().string(from:.now),"files":files]
        try CloudStore.durableWrite(JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys]),to:staging.appendingPathComponent("manifest.json"))
        try FileManager.default.moveItem(at:staging,to:output)
    }
}

extension CloudStore {
    func versions(after:Int,limit:Int) throws -> CloudVersionPage {
        let limit=min(max(limit,1),100)
        let rows=try db.run("SELECT rowid,id,journal,created FROM operations WHERE state='succeeded' AND journal IS NOT NULL AND rowid>? ORDER BY rowid LIMIT ?",[.integer(max(after,0)),.integer(limit+1)])
        let values=try rows.prefix(limit).map { row -> CloudVersionEntry in
            let journal=try decode(FileJournal.self,Data(row.column("journal")!.string!.utf8))
            let id=row.column("id")!.string!
            return CloudVersionEntry(id:id,date:Date(timeIntervalSince1970:row.column("created")!.double!),operationID:id,paths:journal.files.map(\.path))
        }
        return CloudVersionPage(versions:values,nextCursor:rows.count > limit ? rows[limit-1].column("rowid")?.integer : nil)
    }
    func versionFile(_ request:CloudVersionReadRequest) throws -> CloudFileContent {
        _ = try Self.safeURL(request.path,root:root)
        guard let body=try db.run("SELECT journal FROM operations WHERE id=? AND state='succeeded'",[.text(request.id)]).first?.column("journal")?.string,
              let file=try decode(FileJournal.self,Data(body.utf8)).files.first(where:{$0.path == request.path}),let text=String(data:file.after,encoding:.utf8) else {throw CloudError(404,"version_not_found","该版本没有此文件。")}
        return CloudFileContent(path:request.path,hash:digest(file.after),content:text)
    }
}

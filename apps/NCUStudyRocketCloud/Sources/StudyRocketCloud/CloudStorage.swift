import Foundation
import Crypto
import SQLiteNIO
import NIOCore
import NIOPosix
import StudyRocketShared
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct CloudError: Error, LocalizedError {
    let status: Int
    let code: String
    let message: String
    init(_ status: Int, _ code: String, _ message: String) { self.status = status; self.code = code; self.message = message }
    var errorDescription: String? { message }
}
func canonical(_ data: Data) throws -> Data { try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with:data), options:[.sortedKeys,.fragmentsAllowed]) }
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func json<T: Encodable>(_ value: T) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(value) }
func jsonString<T: Encodable>(_ value: T) throws -> String { String(decoding: try json(value), as: UTF8.self) }
func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }

/// Called only from CloudStore's executor or before listening. SQLite work runs on its dedicated pool.
final class CloudDatabase: @unchecked Sendable {
    let connection: SQLiteConnection
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let pool = NIOThreadPool(numberOfThreads: 1)
    init(path: URL) throws {
        pool.start()
        connection = try SQLiteConnection.open(storage: .file(path: path.path), threadPool: pool, on: group.next()).wait()
        for sql in ["PRAGMA journal_mode=WAL", "PRAGMA synchronous=FULL", "PRAGMA foreign_keys=ON", "PRAGMA busy_timeout=5000",
            "CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY,value TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY,name TEXT NOT NULL,public_key TEXT NOT NULL,revoked INTEGER NOT NULL DEFAULT 0)",
            "CREATE TABLE IF NOT EXISTS nonces (id TEXT PRIMARY KEY,expires REAL NOT NULL)",
            "CREATE TABLE IF NOT EXISTS challenges (id TEXT PRIMARY KEY,device TEXT NOT NULL,expires REAL NOT NULL)",
            "CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY,request_hash TEXT NOT NULL,state TEXT NOT NULL,response TEXT,journal TEXT,revision TEXT,created REAL NOT NULL)",
            "CREATE TABLE IF NOT EXISTS proposals (id TEXT PRIMARY KEY,body TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS messages (seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT UNIQUE NOT NULL,thread TEXT NOT NULL,role TEXT NOT NULL,text TEXT NOT NULL,date REAL NOT NULL,source TEXT NOT NULL,body TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS partials (id TEXT PRIMARY KEY,text TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS turns (id TEXT PRIMARY KEY,state TEXT NOT NULL,body TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY AUTOINCREMENT,body TEXT NOT NULL,date REAL NOT NULL)",
            "CREATE INDEX IF NOT EXISTS messages_thread_seq ON messages(thread,seq)"] { try run(sql) }
    }
    @discardableResult func run(_ sql: String, _ binds: [SQLiteData] = []) throws -> [SQLiteRow] { try connection.query(sql, binds).wait() }
    func value(_ key: String) throws -> String? { try run("SELECT value FROM kv WHERE key=?", [.text(key)]).first?.column("value")?.string }
    func set(_ key: String, _ value: String) throws { try run("INSERT INTO kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)]) }
    func transaction<T>(_ action: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do { let value = try action(); try run("COMMIT"); return value }
        catch { _ = try? run("ROLLBACK"); throw error }
    }
    deinit { try? connection.close().wait(); try? pool.syncShutdownGracefully(); try? group.syncShutdownGracefully() }
}

struct JournalFile: Codable { let path: String; let before: Data?; let after: Data; var skill: Bool? = nil }
struct FileJournal: Codable { let files: [JournalFile]; let consumedProposals: [String] }
struct CloudEvent: Sendable { let id: Int; let body: String }
struct PairCode: Codable { let code: String; let expiresAt: Date }

/// One process and one actor own all academic reads/writes. No await occurs during a file transaction.
actor CloudStore {
    nonisolated let root: URL
    nonisolated let state: URL
    nonisolated let repositoryID: String
    nonisolated let threadID: String
    let db: CloudDatabase
    private let lockFD: Int32
    private let repositoryLockFD: Int32
    private let failpoint: String?
    private var faulted = false
    private var pairAttempts: [String: (Int, Date)] = [:]
    var activeRun: String?
    var interrupted = Set<String>()
    static let maximumFileBytes = 1_048_576
    static let prefixes = ["工作台/", "保研/", "规划/", "答疑/", "英语/", "笔记/", "专业/", "智库/学校文件/"]
    static let skills = Set(["daily-checkin", "knowledge-ingest", "ncu-planner", "node-countdown", "retro-monthly", "retro-weekly", "term-roadmap", "weekly-reslot"])

    init(root: URL, state: URL, failpoint: String? = nil) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.state = state.standardizedFileURL.resolvingSymlinksInPath()
        self.failpoint = failpoint
        guard self.root != self.state, !self.state.path.hasPrefix(self.root.path + "/") else { throw CloudError(500,"invalid_configuration","State must be outside the academic repository") }
        try Self.durableEnsureDirectory(self.root)
        try Self.durableEnsureDirectory(self.state)
        lockFD = open(self.state.appendingPathComponent("writer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw CloudError(503,"writer_active","Another cloud writer owns this state directory") }
        repositoryLockFD = open(self.root.appendingPathComponent(".studyrocket-writer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard repositoryLockFD >= 0, flock(repositoryLockFD, LOCK_EX | LOCK_NB) == 0 else { throw CloudError(503,"writer_active","Another writer owns this repository") }
        db = try CloudDatabase(path: self.state.appendingPathComponent("cloud.sqlite"))
        repositoryID = try db.value("repositoryID") ?? UUID().uuidString
        threadID = try db.value("threadID") ?? UUID().uuidString
        try db.set("repositoryID", repositoryID); try db.set("threadID", threadID)
        let recoveryLock = try CloudFileLock(state: self.state)
        defer { withExtendedLifetime(recoveryLock) {} }
        // Recover prepared journal before any listener or reader is created.
        for row in try db.run("SELECT id,journal FROM operations WHERE state='prepared' ORDER BY created") {
            guard let id = row.column("id")?.string, let body = row.column("journal")?.string else { throw CloudError(500,"corrupt_journal","Cannot recover cloud transaction") }
            let journal = try decode(FileJournal.self, Data(body.utf8))
            try Self.install(journal, root: self.root, failpoint: nil)
            try Self.finish(id: id, journal: journal, db: db, root: self.root, repositoryID: repositoryID)
        }
        // Never retry an upstream call automatically after a process crash.
        for row in try db.run("SELECT id FROM turns WHERE state='inProgress'") {
            let id = row.column("id")!.string!
            let terminal = ChatTurnTerminalDTO(turnID: id, status: "interrupted", issueCode: "server_restarted", message: "服务重启，上一回合已中止；请查看已保存回复和草案。", completedAt: .now)
            try db.transaction {
            try db.run("UPDATE turns SET state='interrupted',body=? WHERE id=?", [.text(try jsonString(terminal)), .text(id)])
            if let text = try db.run("SELECT text FROM partials WHERE id=?",[.text(id)]).first?.column("text")?.string, !text.isEmpty {
                let message = CloudArchivedMessage(id:id + "/assistant",sourceThreadID:threadID,role:"assistant",text:text,date:.now,source:"cloud")
                try db.run("INSERT OR IGNORE INTO messages(id,thread,role,text,date,source,body) VALUES(?,?,?,?,?,?,?)",[.text(message.id),.text(threadID),.text("assistant"),.text(text),.float(Date().timeIntervalSince1970),.text("cloud"),.text(try jsonString(message))])
            }
            try db.run("DELETE FROM partials WHERE id=?",[.text(id)])
            try db.run("UPDATE operations SET state='interrupted' WHERE id=? AND state='running'",[.text(id)])
            }

        }
        try db.run("UPDATE operations SET state='interrupted' WHERE state='running'")
    }
    deinit { flock(lockFD, LOCK_UN); close(lockFD); flock(repositoryLockFD, LOCK_UN); close(repositoryLockFD) }
    func ensureReady() throws { if faulted { throw CloudError(503,"recovery_required","服务器需要恢复未完成事务，未接受更多读写。") } }

    nonisolated static func allowed(_ path: String, write: Bool = false) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"), path.hasSuffix(".md"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        if ["PROFILE.md", "校历与重要日期.md"].contains(path) { return true }
        if path == "AGENTS.md" { return !write }
        if prefixes.contains(where: path.hasPrefix) { return !write || !path.hasPrefix("智库/") }
        let p = path.split(separator: "/").map(String.init)
        return !write && p.count >= 4 && p[0] == ".agents" && p[1] == "skills" && skills.contains(p[2])
    }
    nonisolated static func safeURL(_ path: String, root: URL, write: Bool = false) throws -> URL {
        guard allowed(path, write: write) else { throw CloudError(403,"path_denied","文件不在学业 Markdown 白名单内。") }
        var cursor = root
        for part in path.split(separator: "/") {
            cursor.appendPathComponent(String(part))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)) != nil { throw CloudError(403,"path_denied","不允许符号链接。") }
        }
        guard cursor.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw CloudError(403,"path_denied","非法路径。") }
        return cursor
    }
    func file(_ path: String) throws -> CloudFileContent {
        try ensureReady()
        let url = try Self.safeURL(path, root: root)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maximumFileBytes else { throw CloudError(404,"file_unavailable","文件不存在或超过读取上限。") }
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) else { throw CloudError(422,"invalid_utf8","只支持 UTF-8 Markdown。") }
        return CloudFileContent(path: path, hash: digest(data), content: content)
    }
    func manifest() throws -> CloudFileManifest {
        try ensureReady()
        var files: [CloudFileEntry] = []
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey,.isDirectoryKey,.fileSizeKey]) else { throw CloudError(500,"repository_unavailable","无法读取资料目录。") }
        var total = 0
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey,.isDirectoryKey,.fileSizeKey])
            if values.isSymbolicLink == true { walker.skipDescendants(); continue }
            let path = String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
            if values.isDirectory == true {
                let permittedDirectory = Self.prefixes.contains { $0.hasPrefix(path + "/") || (path + "/").hasPrefix($0) } || path == ".agents" || path == ".agents/skills" || Self.skills.contains(where: { path == ".agents/skills/" + $0 || path.hasPrefix(".agents/skills/" + $0 + "/") })
                if !permittedDirectory { walker.skipDescendants() }
                continue
            }
            guard Self.allowed(path) else { continue }
            let entry = try file(path)
            total += entry.content.utf8.count
            guard files.count < 2000, total <= 32 * 1_048_576 else { throw CloudError(413,"repository_too_large","资料超过首版同步上限。") }
            files.append(CloudFileEntry(path:path, hash:entry.hash, byteCount:entry.content.utf8.count))
        }
        files.sort { $0.path < $1.path }
        return CloudFileManifest(repositoryID: repositoryID, revision: snapshot().revision, files: files)
    }
    func snapshot() -> SnapshotResponse { AcademicSnapshotBuilder(root: root, repositoryID: repositoryID).build() }
    func document(_ key: String) -> DocumentDetail? { AcademicSnapshotBuilder(root: root, repositoryID: repositoryID).document(documentKey: key) }

    func replay(id: String, requestHash: String) throws -> Data? {
        guard UUID(uuidString: id) != nil else { throw CloudError(422,"invalid_operation_id","操作编号必须是 UUID。") }
        guard let row = try db.run("SELECT request_hash,state,response FROM operations WHERE id=?", [.text(id)]).first else { return nil }
        guard row.column("request_hash")?.string == requestHash else { throw CloudError(422,"idempotency_key_reused","同一操作编号不能用于不同内容。") }
        if row.column("state")?.string == "succeeded", let result = row.column("response")?.string { return Data(result.utf8) }
        throw CloudError(409,"operation_pending","该操作已有执行记录，请查询操作状态。")
    }
    func operation(_ id: String) throws -> CloudOperationStatus {
        guard let row = try db.run("SELECT state,revision FROM operations WHERE id=?", [.text(id)]).first else { throw CloudError(404,"operation_not_found","没有该操作记录。") }
        return CloudOperationStatus(id: id,state:row.column("state")!.string!,revision:row.column("revision")?.string)
    }
    func commit(id: String, requestHash: String, files: [JournalFile], response: Data, revision: String, consumed: [String] = []) throws -> Data {
        try ensureReady()
        let transactionLock = try CloudFileLock(state:state)
        defer { withExtendedLifetime(transactionLock) {} }
        if let replay = try replay(id:id,requestHash:requestHash) { return replay }
        let journal = FileJournal(files:files,consumedProposals:consumed)
        for file in files {
            let url = try Self.journalURL(file,root:root)
            guard (try? Data(contentsOf:url)) == file.before else { throw CloudError(409,"conflict","文件已变化，请重新预览。") }
        }
        let body = try jsonString(journal)
        let backup = state.appendingPathComponent("backups",isDirectory:true)
        try FileManager.default.createDirectory(at:backup,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try Self.durableWrite(Data(body.utf8),to:backup.appendingPathComponent(id + ".json"))
        try db.run("INSERT INTO operations(id,request_hash,state,response,journal,revision,created) VALUES(?,?,'prepared',?,?,?,?)", [.text(id),.text(requestHash),.text(String(decoding:response,as:UTF8.self)),.text(body),.text(revision),.float(Date().timeIntervalSince1970)])
        if failpoint == "after_prepare" { _exit(86) }
        do {
            try Self.install(journal,root:root,failpoint:failpoint)
            try Self.finish(id:id,journal:journal,db:db,root:root,repositoryID:repositoryID)
        } catch { faulted = true; throw CloudError(503,"recovery_required","提交结果待恢复，请保留操作编号，不要重新创建操作。") }
        return response
    }
    nonisolated static func finish(id: String, journal: FileJournal, db: CloudDatabase, root: URL, repositoryID: String) throws {
        try db.transaction {
            for proposal in journal.consumedProposals { try db.run("DELETE FROM proposals WHERE id=?",[.text(proposal)]) }
            try db.run("UPDATE operations SET state='succeeded' WHERE id=?",[.text(id)])
            let event = HostEventEnvelope(kind:"snapshot",snapshot:AcademicSnapshotBuilder(root:root,repositoryID:repositoryID).build())
            try db.run("INSERT INTO events(body,date) VALUES(?,?)",[.text(try jsonString(event)),.float(Date().timeIntervalSince1970)])
        }
    }
    nonisolated static func install(_ journal: FileJournal, root: URL, failpoint: String?) throws {
        for (index,file) in journal.files.enumerated() {
            let target = try journalURL(file,root:root)
            let current = try? Data(contentsOf:target)
            guard current == file.before || current == file.after else { throw CloudError(500,"recovery_conflict","事务恢复遇到外部修改，已停止服务。") }
            try durableEnsureDirectory(target.deletingLastPathComponent())
            try durableWrite(file.after,to:target)
            if index == 0 && failpoint == "after_first_rename" { _exit(86) }
        }
    }
    nonisolated static func durableEnsureDirectory(_ url: URL) throws {
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath:url.path,isDirectory:&directory) {
            guard directory.boolValue, (try? FileManager.default.destinationOfSymbolicLink(atPath:url.path)) == nil else {throw CloudError(500,"unsafe_directory","Directory is not a physical directory")}
            return
        }
        let parent=url.deletingLastPathComponent()
        guard parent != url else {throw CloudError(500,"invalid_directory","Cannot create filesystem root")}
        try durableEnsureDirectory(parent)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let fd=open(parent.path,O_RDONLY)
        guard fd >= 0 else {throw CloudError(500,"write_failed","Cannot open new directory parent")}
        defer {close(fd)}
        guard fsync(fd) == 0 else {throw CloudError(500,"write_failed","Cannot synchronize new directory")}
    }
    nonisolated static func durableWrite(_ data: Data, to url: URL) throws {
        try durableEnsureDirectory(url.deletingLastPathComponent())
        try data.write(to:url,options:.atomic)
        let fd = open(url.path,O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw CloudError(500,"write_failed","Cannot open persisted file") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw CloudError(500,"write_failed","Cannot synchronize file") }
        let dir = open(url.deletingLastPathComponent().path,O_RDONLY)
        guard dir >= 0 else { throw CloudError(500,"write_failed","Cannot open parent directory") }
        defer { close(dir) }
        guard fsync(dir) == 0 else { throw CloudError(500,"write_failed","Cannot synchronize parent directory") }
    }

    /// Reuses the exact Shared writer on an isolated copy; only the journal can mutate authority.
    func stage<T>(skillPaths: Set<String> = [], _ action: (URL) throws -> T) throws -> (T,[JournalFile]) {
        let baseline = try manifest()
        let staging = state.appendingPathComponent("staging-" + UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:staging) }
        var originals: [String:Data] = [:]
        for entry in baseline.files {
            let target = staging.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            let content = try file(entry.path)
            guard content.hash == entry.hash else { throw CloudError(409,"conflict","暂存期间资料变化。") }
            let data = Data(content.content.utf8); originals[entry.path] = data
            try data.write(to:target)
            if let date = try? root.appendingPathComponent(entry.path).resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate { try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:target.path) }
        }
        let result = try action(staging)
        var changes: [JournalFile] = []
        if let walker = FileManager.default.enumerator(at:staging,includingPropertiesForKeys:[.isRegularFileKey]) {
            for case let url as URL in walker where (try? url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true {
                let path = String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(staging.standardizedFileURL.resolvingSymlinksInPath().path.count + 1))
                guard Self.allowed(path,write:true) || (skillPaths.contains(path) && Self.skillPath(path)) else { continue }
                let after = try Data(contentsOf:url)
                let before = originals[path]
                if after != before { changes.append(JournalFile(path:path,before:before,after:after,skill:skillPaths.contains(path) ? true:nil)) }
            }
        }
        return (result,changes.sorted { $0.path < $1.path })
    }
    func writeDomain(path: String, body: Data) throws -> Data {
        let metadata: WriteMetadata
        switch path {
        case "/v1/week": metadata = try decode(PlanWriteRequest.self,body).metadata
        case "/v1/daily": metadata = try decode(DailyWriteRequest.self,body).metadata
        case "/v1/facts": metadata = try decode(FactWriteRequest.self,body).metadata
        case "/v1/deliveries/toggle": metadata = try decode(DeliveryToggleRequest.self,body).metadata
        default: metadata = try decode(PeriodCompletionToggleRequest.self,body).metadata
        }
        let requestHash = digest(Data(path.utf8) + (try canonical(body)))
        if let replay = try replay(id:metadata.idempotencyKey,requestHash:requestHash) { return replay }
        guard metadata.apiVersion == 1 else { throw CloudError(422,"unsupported_version","客户端版本不兼容。") }
        let (value,changes) = try stage { staging in
            let writer = AcademicWriteService(root:staging,repositoryID:repositoryID,backupRoot:state.appendingPathComponent("scratch-backups"),recordLocalHistory:false)
            switch path {
            case "/v1/week": return try writer.applyWeek(decode(PlanWriteRequest.self,body))
            case "/v1/daily": return try writer.applyDaily(decode(DailyWriteRequest.self,body))
            case "/v1/facts": return try writer.appendFact(decode(FactWriteRequest.self,body))
            case "/v1/deliveries/toggle": return try writer.toggleDelivery(decode(DeliveryToggleRequest.self,body))
            default: return try writer.togglePeriod(decode(PeriodCompletionToggleRequest.self,body))
            }
        }
        return try commit(id:metadata.idempotencyKey,requestHash:requestHash,files:changes,response:json(value),revision:value.revision)
    }
    func commitFiles(_ request: CloudFileCommitRequest, raw: Data) throws -> Data {
        let requestHash = digest(Data("/v1/files/commit".utf8) + (try canonical(raw)))
        if let replay = try replay(id:request.metadata.idempotencyKey,requestHash:requestHash) { return replay }
        guard request.repositoryID == repositoryID, request.metadata.apiVersion == 1 else { throw CloudError(422,"wrong_destination","目标仓库或协议不匹配。") }
        guard request.metadata.baseRevision == snapshot().revision else { throw CloudError(409,"conflict","云端已变化，请刷新后比较差异。") }
        guard !request.files.isEmpty, request.files.count <= 16, Set(request.files.map(\.path)).count == request.files.count else { throw CloudError(422,"invalid_files","提交文件数或路径重复。") }
        let (_,changes) = try stage { staging in
            for change in request.files {
                let current = try? file(change.path)
                guard current?.hash == change.baseHash, change.content.utf8.count <= Self.maximumFileBytes else { throw CloudError(409,"conflict","文件基线不匹配或过大。") }
                let target = try Self.safeURL(change.path,root:staging,write:true)
                let prepared = try PlanningProposalValidation.prepare(path:change.path,original:current?.content ?? "",proposed:change.content)
                try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                try Data(prepared.utf8).write(to:target,options:.atomic)
            }
        }
        let old = try manifest()
        var entries = Dictionary(uniqueKeysWithValues:old.files.map { ($0.path,$0) })
        for change in changes { entries[change.path] = CloudFileEntry(path:change.path,hash:digest(change.after),byteCount:change.after.count) }
        let (newSnapshot,_) = try stage { staging in
            for change in changes { let url=staging.appendingPathComponent(change.path); try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true); try change.after.write(to:url) }
            return AcademicSnapshotBuilder(root:staging,repositoryID:repositoryID).build()
        }
        let manifest = CloudFileManifest(repositoryID:repositoryID,revision:newSnapshot.revision,files:entries.values.sorted{$0.path < $1.path})
        return try commit(id:request.metadata.idempotencyKey,requestHash:requestHash,files:changes,response:json(manifest),revision:newSnapshot.revision)
    }
    func appendEvent(_ event: HostEventEnvelope) throws -> Int {
        let id: Int = try db.transaction {
            if let chat=event.chat, chat.kind == "delta", let turn=chat.turnID,let text=chat.text {
                try db.run("INSERT INTO partials(id,text) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET text=text||excluded.text",[.text(turn),.text(text)])
            }
            try db.run("INSERT INTO events(body,date) VALUES(?,?)",[.text(try jsonString(event)),.float(Date().timeIntervalSince1970)])
            return try db.run("SELECT last_insert_rowid() AS id").first!.column("id")!.integer!
        }
        // Cursors older than retention receive a snapshot/history resync marker.
        try db.run("DELETE FROM events WHERE seq < ?",[.integer(id - 4000)])
        return id
    }
    func events(after: Int) throws -> [CloudEvent] {
        try ensureReady()
        let oldest = try db.run("SELECT min(seq) AS id FROM events").first?.column("id")?.integer ?? 0
        if after > 0 && after < oldest - 1 { return [CloudEvent(id:oldest - 1,body:try jsonString(HostEventEnvelope(kind:"resync",snapshot:snapshot())))] }
        return try db.run("SELECT seq,body FROM events WHERE seq>? ORDER BY seq LIMIT 100",[.integer(after)]).map { CloudEvent(id:$0.column("seq")!.integer!,body:$0.column("body")!.string!) }
    }
}

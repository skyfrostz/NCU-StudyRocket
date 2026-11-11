import Foundation

/// Cloud metadata supplements v1. Markdown remains the authoritative academic data.
public struct CloudFileEntry: Codable, Equatable, Sendable {
    public let path: String
    public let hash: String
    public let byteCount: Int
    public init(path: String, hash: String, byteCount: Int) { self.path = path; self.hash = hash; self.byteCount = byteCount }
}
public struct CloudFileManifest: Codable, Equatable, Sendable {
    public let repositoryID: String
    public let revision: String
    public let files: [CloudFileEntry]
    public init(repositoryID: String, revision: String, files: [CloudFileEntry]) { self.repositoryID = repositoryID; self.revision = revision; self.files = files }
}
public struct CloudFileReadRequest: Codable, Sendable {
    public let path: String
    public init(path: String) { self.path = path }
}
public struct CloudFileContent: Codable, Equatable, Sendable {
    public let path: String
    public let hash: String
    public let content: String
    public init(path: String, hash: String, content: String) { self.path = path; self.hash = hash; self.content = content }
}
public struct CloudFileChange: Codable, Equatable, Sendable {
    public let path: String
    /// nil means create; a nonnil hash must match the current UTF-8 file bytes.
    public let baseHash: String?
    public let content: String
    public init(path: String, baseHash: String?, content: String) { self.path = path; self.baseHash = baseHash; self.content = content }
}
public struct CloudFileCommitRequest: Codable, Sendable {
    public let repositoryID: String
    public let metadata: WriteMetadata
    public let files: [CloudFileChange]
    public init(repositoryID: String, metadata: WriteMetadata, files: [CloudFileChange]) { self.repositoryID = repositoryID; self.metadata = metadata; self.files = files }
}
public struct CloudOperationStatus: Codable, Equatable, Sendable {
    public let id: String
    public let state: String
    public let revision: String?
    public let message: String?
    public init(id: String, state: String, revision: String? = nil, message: String? = nil) { self.id = id; self.state = state; self.revision = revision; self.message = message }
}
public struct CloudArchivedMessage: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceThreadID: String
    public let role: String
    public let text: String
    public let date: Date
    public let source: String
    public init(id: String, sourceThreadID: String, role: String, text: String, date: Date, source: String = "codex-import") {
        self.id = id; self.sourceThreadID = sourceThreadID; self.role = role; self.text = text; self.date = date; self.source = source
    }
}
public struct CloudHistoryPage: Codable, Sendable {
    public let messages: [CloudArchivedMessage]
    public let nextCursor: Int?
    public let total: Int
    public init(messages: [CloudArchivedMessage], nextCursor: Int?, total: Int) { self.messages = messages; self.nextCursor = nextCursor; self.total = total }
}
public struct CloudHistoryImportRequest: Codable, Sendable {
    public let idempotencyKey: String
    public let messages: [CloudArchivedMessage]
    public init(idempotencyKey: String, messages: [CloudArchivedMessage]) { self.idempotencyKey = idempotencyKey; self.messages = messages }
}

public struct CloudVersionEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let date: Date
    public let operationID: String
    public let paths: [String]
    public init(id: String, date: Date, operationID: String, paths: [String]) { self.id=id; self.date=date; self.operationID=operationID; self.paths=paths }
}
public struct CloudVersionPage: Codable, Sendable {
    public let versions: [CloudVersionEntry]
    public let nextCursor: Int?
    public init(versions: [CloudVersionEntry], nextCursor: Int?) { self.versions=versions; self.nextCursor=nextCursor }
}
public struct CloudVersionReadRequest: Codable, Sendable {
    public let id: String
    public let path: String
    public init(id: String, path: String) { self.id=id; self.path=path }
}

public struct CloudBackupEntry: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let byteCount: Int
    public init(path: String, sha256: String, byteCount: Int) { self.path=path; self.sha256=sha256; self.byteCount=byteCount }
}
public struct CloudBackupManifest: Codable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let files: [CloudBackupEntry]
    public init(id: String, createdAt: Date, files: [CloudBackupEntry]) { self.id=id; self.createdAt=createdAt; self.files=files }
}
public struct CloudBackupReadRequest: Codable, Sendable {
    public let backupID: String
    public let path: String
    public let offset: Int
    public let limit: Int
    public init(backupID: String, path: String, offset: Int = 0, limit: Int = 262144) { self.backupID=backupID; self.path=path; self.offset=offset; self.limit=limit }
}
public struct CloudBackupFile: Codable, Sendable {
    public let backupID: String
    public let path: String
    public let sha256: String
    public let base64Data: String
    public let offset: Int
    public let nextOffset: Int?
    public let totalBytes: Int
    public init(backupID: String, path: String, sha256: String, base64Data: String, offset: Int, nextOffset: Int?, totalBytes: Int) {
        self.backupID=backupID; self.path=path; self.sha256=sha256; self.base64Data=base64Data; self.offset=offset; self.nextOffset=nextOffset; self.totalBytes=totalBytes
    }
}

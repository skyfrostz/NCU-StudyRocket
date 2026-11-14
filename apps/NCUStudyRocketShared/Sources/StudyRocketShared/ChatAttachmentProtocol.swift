import Foundation

public enum ChatAttachmentState: String, Codable, Hashable, Sendable {
    case uploading, processing, ready, unknown, failed, removed, expired
}
public struct ChatAttachmentDTO: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let filename: String
    public let mimeType: String
    public let byteCount: Int
    public let sha256: String
    public var state: ChatAttachmentState
    public var uploadedBytes: Int
    public var expiresAt: Date
    public var issue: String?
    public init(id: String, filename: String, mimeType: String, byteCount: Int, sha256: String, state: ChatAttachmentState = .uploading, uploadedBytes: Int = 0, expiresAt: Date, issue: String? = nil) {
        self.id=id; self.filename=filename; self.mimeType=mimeType; self.byteCount=byteCount; self.sha256=sha256; self.state=state; self.uploadedBytes=uploadedBytes; self.expiresAt=expiresAt; self.issue=issue
    }
}
public enum ChatAttachmentLimits {
    public static let chunkBytes = 262144
    public static let messageCount = 10
    public static let messageBytes = 100 * 1024 * 1024
    public static let imageBytes = 20 * 1024 * 1024
    public static let documentBytes = 100 * 1024 * 1024
    public static let textBytes = 32 * 1024 * 1024
}
public struct ChatAttachmentCreateRequest: Codable, Sendable {
    public let id: String
    public let filename: String
    public let mimeType: String
    public let byteCount: Int
    public let sha256: String
    public let apiVersion: Int
    public init(id: String = UUID().uuidString, filename: String, mimeType: String, byteCount: Int, sha256: String, apiVersion: Int = 1) { self.id=id; self.filename=filename; self.mimeType=mimeType; self.byteCount=byteCount; self.sha256=sha256; self.apiVersion=apiVersion }
}
public struct ChatAttachmentChunkRequest: Codable, Sendable {
    public let id: String
    public let offset: Int
    public let base64Data: String
    public let sha256: String
    public init(id: String, offset: Int, base64Data: String, sha256: String) { self.id=id; self.offset=offset; self.base64Data=base64Data; self.sha256=sha256 }
}
/// Shared body for complete/status/remove; ID is the stable upload operation identity.
public struct ChatAttachmentRequest: Codable, Sendable {
    public let id: String
    public init(id: String) { self.id=id }
}
public struct ChatAttachmentReadRequest: Codable, Sendable {
    public let id: String
    public let offset: Int
    public let limit: Int
    public init(id: String, offset: Int = 0, limit: Int = 262144) { self.id=id; self.offset=offset; self.limit=limit }
}
public struct ChatAttachmentChunkResponse: Codable, Sendable {
    public let id: String
    public let offset: Int
    public let nextOffset: Int?
    public let totalBytes: Int
    public let base64Data: String
    public let sha256: String
    public init(id: String, offset: Int, nextOffset: Int?, totalBytes: Int, base64Data: String, sha256: String) { self.id=id; self.offset=offset; self.nextOffset=nextOffset; self.totalBytes=totalBytes; self.base64Data=base64Data; self.sha256=sha256 }
}
public struct ChatInterruptResponse: Codable, Sendable {
    public let targetTurnID: String
    public let operationID: String
    public let status: String
    public let terminal: ChatTurnTerminalDTO?
    public init(targetTurnID: String, operationID: String, status: String, terminal: ChatTurnTerminalDTO? = nil) { self.targetTurnID=targetTurnID; self.operationID=operationID; self.status=status; self.terminal=terminal }
}

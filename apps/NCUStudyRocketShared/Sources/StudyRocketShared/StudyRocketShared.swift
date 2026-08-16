import Foundation
import CryptoKit
#if os(macOS)
import Darwin
#endif

public enum StudyRocketAPI {
    public static let version = 1
    /// Version of the persisted academic-task/dynamic-tool contract.
    /// Bump this when a resumed task cannot safely reuse its tool registry.
    public static let academicTaskProtocolVersion = 3
    public static let prefix = "/v1"
    public static let defaultHostPort: UInt16 = 43817
}

/// Shared location for the short-lived Mac-only control token.
/// The token is never stored in the repository or synced to the phone.
public enum StudyRocketLocalSession {
    public static let directoryName = "NCU StudyRocket"
    public static let tokenFileName = "host-local-session"
    public static let codexLeaseFileName = "codex-owner.json"
    public static let academicTaskDirectoryName = "Academic Tasks"

    public static func tokenURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? applicationSupportFallback(fileManager: fileManager)
        return base.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent(tokenFileName)
    }

    private static func applicationSupportFallback(fileManager: FileManager) -> URL {
        #if os(macOS)
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        #else
        // iOS always supplies Application Support; this only keeps the shared module
        // buildable if a custom FileManager cannot resolve it in a test environment.
        return fileManager.temporaryDirectory
        #endif
    }

    public static func codexLeaseURL(fileManager: FileManager = .default) -> URL {
        tokenURL(fileManager: fileManager).deletingLastPathComponent().appendingPathComponent(codexLeaseFileName)
    }

    public static func academicTaskDirectoryURL(fileManager: FileManager = .default) -> URL {
        tokenURL(fileManager: fileManager).deletingLastPathComponent().appendingPathComponent(academicTaskDirectoryName, isDirectory: true)
    }
}

/// The only persistent identity shared by the desktop app and the optional
/// Host. Conversation content remains in Codex; this file merely tells the
/// next owner which compatible task to resume for a repository.
public struct StudyRocketTaskDescriptor: Codable, Equatable, Sendable {
    public let threadID: String
    public let protocolVersion: Int

    public init(threadID: String, protocolVersion: Int = StudyRocketAPI.academicTaskProtocolVersion) {
        self.threadID = threadID
        self.protocolVersion = protocolVersion
    }
}

public final class StudyRocketTaskDescriptorStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let directory: URL

    public init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        self.directory = directory ?? StudyRocketLocalSession.academicTaskDirectoryURL(fileManager: fileManager)
    }

    public func load(for root: URL) -> StudyRocketTaskDescriptor? {
        guard let data = try? Data(contentsOf: url(for: root)),
              let descriptor = try? JSONDecoder().decode(StudyRocketTaskDescriptor.self, from: data),
              !descriptor.threadID.isEmpty else { return nil }
        return descriptor
    }

    public func save(_ descriptor: StudyRocketTaskDescriptor, for root: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(descriptor)
        try data.write(to: url(for: root), options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url(for: root).path)
    }

    public func remove(for root: URL) {
        try? fileManager.removeItem(at: url(for: root))
    }

    private func url(for root: URL) -> URL {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
}

public enum CodexLeaseError: LocalizedError, Equatable, Sendable {
    case busy(owner: String)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .busy(let owner): return "Codex 当前由 \(owner) 使用，请先停止另一条 StudyRocket 连接。"
        case .unavailable: return "无法建立 StudyRocket Codex 单实例租约。"
        }
    }
}

public final class CodexLease: @unchecked Sendable {
    private let fileManager: FileManager
    private let url: URL
    private let token: String

    fileprivate init(fileManager: FileManager, url: URL, token: String) {
        self.fileManager = fileManager
        self.url = url
        self.token = token
    }

    public func release() {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(CodexLeaseStore.Record.self, from: data),
              record.token == token else { return }
        try? fileManager.removeItem(at: url)
    }
}

public final class CodexLeaseStore: @unchecked Sendable {
    fileprivate struct Record: Codable, Equatable, Sendable {
        let token: String
        let owner: String
        let pid: Int32
        let createdAt: Date
    }

    private let fileManager: FileManager
    private let url: URL

    public init(fileManager: FileManager = .default, url: URL? = nil) {
        self.fileManager = fileManager
        self.url = url ?? StudyRocketLocalSession.codexLeaseURL(fileManager: fileManager)
    }

    public func acquire(owner: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws -> CodexLease {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for _ in 0..<2 {
            if let data = try? Data(contentsOf: url),
               let record = try? JSONDecoder().decode(Record.self, from: data) {
                if Self.isAlive(record.pid) {
                    throw CodexLeaseError.busy(owner: record.owner)
                }
                try? fileManager.removeItem(at: url)
            }

            let record = Record(token: UUID().uuidString, owner: owner, pid: pid, createdAt: .now)
            guard let data = try? JSONEncoder().encode(record) else { throw CodexLeaseError.unavailable }
            do {
                try data.write(to: url, options: .withoutOverwriting)
                do {
                    try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
                } catch {
                    try? fileManager.removeItem(at: url)
                    throw CodexLeaseError.unavailable
                }
                return CodexLease(fileManager: fileManager, url: url, token: record.token)
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                throw CodexLeaseError.unavailable
            }
        }
        throw CodexLeaseError.unavailable
    }

    #if os(macOS)
    private static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
    #else
    private static func isAlive(_ pid: Int32) -> Bool { false }
    #endif
}

public struct APIErrorBody: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool

    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

public struct HealthResponse: Codable, Equatable, Sendable {
    public let apiVersion: Int
    public let hostVersion: String
    public let repositoryBound: Bool
    public let codexReady: Bool
    public let pairedDeviceCount: Int
    public let activeThreadID: String?
    public let repositoryID: String?
    public let dynamicToolsReady: Bool?

    public init(apiVersion: Int = StudyRocketAPI.version, hostVersion: String, repositoryBound: Bool, codexReady: Bool, pairedDeviceCount: Int, activeThreadID: String?, repositoryID: String? = nil, dynamicToolsReady: Bool? = nil) {
        self.apiVersion = apiVersion
        self.hostVersion = hostVersion
        self.repositoryBound = repositoryBound
        self.codexReady = codexReady
        self.pairedDeviceCount = pairedDeviceCount
        self.activeThreadID = activeThreadID
        self.repositoryID = repositoryID
        self.dynamicToolsReady = dynamicToolsReady
    }
}

public struct PairRequest: Codable, Equatable, Sendable {
    public let code: String
    public let deviceName: String
    public let publicKey: String
    public let apiVersion: Int

    public init(code: String, deviceName: String, publicKey: String, apiVersion: Int = StudyRocketAPI.version) {
        self.code = code
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.apiVersion = apiVersion
    }
}

public struct PairResponse: Codable, Equatable, Sendable {
    public let deviceID: String
    public let serverName: String
    public let apiVersion: Int

    public init(deviceID: String, serverName: String, apiVersion: Int = StudyRocketAPI.version) {
        self.deviceID = deviceID
        self.serverName = serverName
        self.apiVersion = apiVersion
    }
}

public struct RequestAuthentication: Codable, Equatable, Sendable {
    public let deviceID: String
    public let timestamp: Int64
    public let nonce: String
    public let signature: String

    public init(deviceID: String, timestamp: Int64, nonce: String, signature: String) {
        self.deviceID = deviceID
        self.timestamp = timestamp
        self.nonce = nonce
        self.signature = signature
    }
}

public struct SnapshotResponse: Codable, Equatable, Sendable {
    public let revision: String
    public let fetchedAt: Date
    public let home: HomeSnapshot
    public let week: WeeklyPlanSnapshot
    public let daily: DailySnapshot
    public let summaries: [SummaryCard]

    public init(revision: String, fetchedAt: Date = .now, home: HomeSnapshot, week: WeeklyPlanSnapshot, daily: DailySnapshot, summaries: [SummaryCard]) {
        self.revision = revision
        self.fetchedAt = fetchedAt
        self.home = home
        self.week = week
        self.daily = daily
        self.summaries = summaries
    }
}

public struct EventsResponse: Codable, Equatable, Sendable {
    public let revision: String
    public let snapshot: SnapshotResponse

    public init(revision: String, snapshot: SnapshotResponse) {
        self.revision = revision
        self.snapshot = snapshot
    }
}

/// A typed event sent over the Host's authenticated SSE connection. Keeping
/// snapshots optional lets chat deltas stay small while every meaningful write
/// can still refresh the phone from the same Markdown-derived snapshot.
public struct HostEventEnvelope: Codable, Equatable, Sendable {
    public let kind: String
    public let snapshot: SnapshotResponse?
    public let chat: ChatStreamEvent?

    public init(kind: String, snapshot: SnapshotResponse? = nil, chat: ChatStreamEvent? = nil) {
        self.kind = kind
        self.snapshot = snapshot
        self.chat = chat
    }
}

public struct ChatStreamEvent: Codable, Equatable, Sendable {
    public let kind: String
    public let turnID: String?
    public let itemID: String?
    public let text: String?
    public let phase: String?
    public let status: String?

    public init(kind: String, turnID: String? = nil, itemID: String? = nil, text: String? = nil, phase: String? = nil, status: String? = nil) {
        self.kind = kind
        self.turnID = turnID
        self.itemID = itemID
        self.text = text
        self.phase = phase
        self.status = status
    }
}

public struct HomeSnapshot: Codable, Equatable, Sendable {
    public let dateLabel: String
    public let periods: [PeriodSnapshot]
    public let firstOpenTask: String?
    public let visibleDeliveries: [DeliverySnapshot]
    public let completedDeliveries: Int
    public let totalDeliveries: Int

    public init(dateLabel: String, periods: [PeriodSnapshot], firstOpenTask: String?, visibleDeliveries: [DeliverySnapshot], completedDeliveries: Int, totalDeliveries: Int) {
        self.dateLabel = dateLabel
        self.periods = periods
        self.firstOpenTask = firstOpenTask
        self.visibleDeliveries = visibleDeliveries
        self.completedDeliveries = completedDeliveries
        self.totalDeliveries = totalDeliveries
    }
}

public struct PeriodSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let text: String

    public init(id: String, title: String, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }
}

public struct DeliverySnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let isCompleted: Bool
    public let dateLabel: String?

    public init(id: String, text: String, isCompleted: Bool, dateLabel: String? = nil) {
        self.id = id
        self.text = text
        self.isCompleted = isCompleted
        self.dateLabel = dateLabel
    }
}

public struct WeeklyPlanSnapshot: Codable, Equatable, Sendable {
    public let days: [DaySnapshot]
    public let bufferRules: [BufferRuleSnapshot]
    public let deliveries: [DeliverySnapshot]
    public let historicalRows: [ScheduledRowSnapshot]
    public let futureRows: [ScheduledRowSnapshot]

    public init(days: [DaySnapshot], bufferRules: [BufferRuleSnapshot], deliveries: [DeliverySnapshot], historicalRows: [ScheduledRowSnapshot] = [], futureRows: [ScheduledRowSnapshot] = []) {
        self.days = days
        self.bufferRules = bufferRules
        self.deliveries = deliveries
        self.historicalRows = historicalRows
        self.futureRows = futureRows
    }

    private enum CodingKeys: String, CodingKey {
        case days, bufferRules, deliveries, historicalRows, futureRows
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        days = try values.decode([DaySnapshot].self, forKey: .days)
        bufferRules = try values.decode([BufferRuleSnapshot].self, forKey: .bufferRules)
        deliveries = try values.decode([DeliverySnapshot].self, forKey: .deliveries)
        historicalRows = try values.decodeIfPresent([ScheduledRowSnapshot].self, forKey: .historicalRows) ?? []
        futureRows = try values.decodeIfPresent([ScheduledRowSnapshot].self, forKey: .futureRows) ?? []
    }
}

public struct ScheduledRowSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let dateLabel: String
    public let slots: [PeriodSnapshot]
    public let unassigned: String
    public let isCompleted: Bool

    public init(id: String, dateLabel: String, slots: [PeriodSnapshot], unassigned: String = "", isCompleted: Bool = false) {
        self.id = id
        self.dateLabel = dateLabel
        self.slots = slots
        self.unassigned = unassigned
        self.isCompleted = isCompleted
    }
}

public struct DaySnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let dateLabel: String
    public let slots: [PeriodSnapshot]
    public let unassigned: String

    public init(id: String, dateLabel: String, slots: [PeriodSnapshot], unassigned: String = "") {
        self.id = id
        self.dateLabel = dateLabel
        self.slots = slots
        self.unassigned = unassigned
    }
}

public struct BufferRuleSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let category: String
    public let text: String

    public init(id: String, category: String, text: String) {
        self.id = id
        self.category = category
        self.text = text
    }
}

public struct DailySnapshot: Codable, Equatable, Sendable {
    public let date: String
    public let deliverables: String
    public let studyTime: String
    public let sleep: String
    public let exercise: String
    public let firstTask: String

    public init(date: String, deliverables: String = "", studyTime: String = "", sleep: String = "", exercise: String = "", firstTask: String = "") {
        self.date = date
        self.deliverables = deliverables
        self.studyTime = studyTime
        self.sleep = sleep
        self.exercise = exercise
        self.firstTask = firstTask
    }
}

public struct SummaryCard: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let updatedAt: Date?
    /// Stable logical key used by the mobile client to request the complete
    /// read-only Markdown document.  It is optional so snapshots written by
    /// older Hosts continue to decode.
    public let documentKey: String?

    public init(id: String, title: String, detail: String, updatedAt: Date? = nil, documentKey: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.updatedAt = updatedAt
        self.documentKey = documentKey
    }

    private enum CodingKeys: String, CodingKey { case id, title, detail, updatedAt, documentKey }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        detail = try values.decode(String.self, forKey: .detail)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt)
        documentKey = try values.decodeIfPresent(String.self, forKey: .documentKey)
    }
}

/// A complete, read-only Markdown document exposed by the Host through a
/// fixed logical-key allowlist.  The phone may cache this value locally after
/// the user explicitly opens it; it is never a second source of truth.
public struct DocumentDetail: Codable, Equatable, Sendable, Identifiable {
    public let documentKey: String
    public let title: String
    public let markdown: String
    public let revision: String
    public let fetchedAt: Date

    public var id: String { documentKey }

    public init(documentKey: String, title: String, markdown: String, revision: String, fetchedAt: Date = .now) {
        self.documentKey = documentKey
        self.title = title
        self.markdown = markdown
        self.revision = revision
        self.fetchedAt = fetchedAt
    }
}

public enum StudyRocketMarkdownBlock: Equatable, Sendable {
    case prose(String)
    case table(markdown: String, columns: Int)
}

/// A deliberately small, platform-neutral block classifier.  It does not
/// render Markdown or change its contents; native clients use it only to put
/// wide tables in a horizontal scroller while leaving prose responsive.
public enum StudyRocketMarkdownParser {
    public static func blocks(from text: String) -> [StudyRocketMarkdownBlock] {
        let lines = text.components(separatedBy: .newlines)
        var result: [StudyRocketMarkdownBlock] = []
        var prose: [String] = []
        var index = 0

        func isTableLine(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("```") && trimmed.filter { $0 == "|" }.count >= 1
        }

        func isDivider(_ line: String) -> Bool {
            let cells = line.split(separator: "|", omittingEmptySubsequences: true)
            return !cells.isEmpty && cells.allSatisfy { cell in
                cell.trimmingCharacters(in: .whitespaces).allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
            }
        }

        func flushProse() {
            guard !prose.isEmpty else { return }
            let value = prose.joined(separator: "\n")
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.prose(value)) }
            prose.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            guard index + 1 < lines.count, isTableLine(lines[index]), isDivider(lines[index + 1]) else {
                prose.append(lines[index])
                index += 1
                continue
            }
            flushProse()
            let start = index
            index += 2
            while index < lines.count && isTableLine(lines[index]) { index += 1 }
            let table = lines[start..<index].joined(separator: "\n")
            let columns = lines[start].split(separator: "|", omittingEmptySubsequences: true).count
            result.append(.table(markdown: table, columns: max(columns, 2)))
        }
        flushProse()
        return result.isEmpty ? [.prose(text)] : result
    }
}

public struct ChatMessageDTO: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let role: String
    public let text: String
    public let date: Date
    public let turnID: String?
    public let phase: String?
    public let status: String?

    public init(id: String, role: String, text: String, date: Date, turnID: String? = nil, phase: String? = nil, status: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.turnID = turnID
        self.phase = phase
        self.status = status
    }
}

public struct ChatHistoryResponse: Codable, Equatable, Sendable {
    public let revision: String
    public let messages: [ChatMessageDTO]

    public init(revision: String, messages: [ChatMessageDTO]) {
        self.revision = revision
        self.messages = messages
    }
}

public struct SendChatRequest: Codable, Equatable, Sendable {
    public let text: String
    public let clientRequestID: String
    public let apiVersion: Int

    public init(text: String, clientRequestID: String = UUID().uuidString, apiVersion: Int = StudyRocketAPI.version) {
        self.text = text
        self.clientRequestID = clientRequestID
        self.apiVersion = apiVersion
    }
}

public struct InterruptRequest: Codable, Equatable, Sendable {
    public let turnID: String
    public let apiVersion: Int

    public init(turnID: String, apiVersion: Int = StudyRocketAPI.version) {
        self.turnID = turnID
        self.apiVersion = apiVersion
    }
}

public struct WriteMetadata: Codable, Equatable, Sendable {
    public let baseRevision: String
    public let idempotencyKey: String
    public let apiVersion: Int

    public init(baseRevision: String, idempotencyKey: String = UUID().uuidString, apiVersion: Int = StudyRocketAPI.version) {
        self.baseRevision = baseRevision
        self.idempotencyKey = idempotencyKey
        self.apiVersion = apiVersion
    }
}

public struct ProposalAuthorizationChallenge: Codable, Equatable, Sendable {
    public let challenge: String
    public let expiresAt: Date

    public init(challenge: String, expiresAt: Date) {
        self.challenge = challenge
        self.expiresAt = expiresAt
    }
}

public struct ProposalApplyRequest: Codable, Equatable, Sendable {
    public let proposalIDs: [String]
    public let authorization: String
    public let metadata: WriteMetadata

    public init(proposalIDs: [String], authorization: String, metadata: WriteMetadata) {
        self.proposalIDs = proposalIDs
        self.authorization = authorization
        self.metadata = metadata
    }
}

public struct ProposalDTO: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let turnID: String
    public let relativePath: String
    public let originalContent: String
    public let proposedContent: String
    public let reason: String
    public let baseHash: String
    public let kind: String

    public init(id: String, turnID: String, relativePath: String, originalContent: String, proposedContent: String, reason: String, baseHash: String, kind: String) {
        self.id = id
        self.turnID = turnID
        self.relativePath = relativePath
        self.originalContent = originalContent
        self.proposedContent = proposedContent
        self.reason = reason
        self.baseHash = baseHash
        self.kind = kind
    }
}

public struct ProposalListResponse: Codable, Equatable, Sendable {
    public let proposals: [ProposalDTO]

    public init(proposals: [ProposalDTO]) { self.proposals = proposals }
}

public struct ProposalApplyResponse: Codable, Equatable, Sendable {
    public let remaining: ProposalListResponse
    public let revision: String

    public init(remaining: ProposalListResponse, revision: String) {
        self.remaining = remaining
        self.revision = revision
    }
}

public struct PlanWriteRequest: Codable, Equatable, Sendable {
    public let plan: WeeklyPlanSnapshot
    public let metadata: WriteMetadata

    public init(plan: WeeklyPlanSnapshot, metadata: WriteMetadata) {
        self.plan = plan
        self.metadata = metadata
    }
}

public struct DailyWriteRequest: Codable, Equatable, Sendable {
    public let entry: DailySnapshot
    public let metadata: WriteMetadata

    public init(entry: DailySnapshot, metadata: WriteMetadata) {
        self.entry = entry
        self.metadata = metadata
    }
}

public struct DeliveryToggleRequest: Codable, Equatable, Sendable {
    public let text: String
    public let isCompleted: Bool
    public let metadata: WriteMetadata

    public init(text: String, isCompleted: Bool, metadata: WriteMetadata) {
        self.text = text
        self.isCompleted = isCompleted
        self.metadata = metadata
    }
}

public enum RequestSigning {
    public static func bodyHash(_ body: Data) -> String {
        SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }

    public static func canonicalData(method: String, path: String, timestamp: Int64, nonce: String, bodyHash: String) -> Data {
        Data([method.uppercased(), path, String(timestamp), nonce, bodyHash].joined(separator: "\n").utf8)
    }

    public static func authorizationData(challenge: String) -> Data {
        Data("studyrocket-face-id-v1\n\(challenge)".utf8)
    }

    public static func sign(privateKey: P256.Signing.PrivateKey, method: String, path: String, timestamp: Int64, nonce: String, bodyHash: String) -> String {
        let signature = try! privateKey.signature(for: canonicalData(method: method, path: path, timestamp: timestamp, nonce: nonce, bodyHash: bodyHash))
        return signature.rawRepresentation.base64EncodedString()
    }

    public static func signAuthorization(privateKey: P256.Signing.PrivateKey, challenge: String) -> String {
        let signature = try! privateKey.signature(for: authorizationData(challenge: challenge))
        return signature.rawRepresentation.base64EncodedString()
    }

#if os(iOS)
    public static func sign(privateKey: SecureEnclave.P256.Signing.PrivateKey, method: String, path: String, timestamp: Int64, nonce: String, bodyHash: String) -> String {
        let signature = try! privateKey.signature(for: canonicalData(method: method, path: path, timestamp: timestamp, nonce: nonce, bodyHash: bodyHash))
        return signature.rawRepresentation.base64EncodedString()
    }

    public static func signAuthorization(privateKey: SecureEnclave.P256.Signing.PrivateKey, challenge: String) -> String {
        let signature = try! privateKey.signature(for: authorizationData(challenge: challenge))
        return signature.rawRepresentation.base64EncodedString()
    }
#endif

    public static func verify(publicKeyData: Data, signatureBase64: String, method: String, path: String, timestamp: Int64, nonce: String, bodyHash: String) -> Bool {
        guard let publicKey = try? P256.Signing.PublicKey(rawRepresentation: publicKeyData),
              let signatureData = Data(base64Encoded: signatureBase64),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData) else { return false }
        return publicKey.isValidSignature(signature, for: canonicalData(method: method, path: path, timestamp: timestamp, nonce: nonce, bodyHash: bodyHash))
    }

    public static func verifyAuthorization(publicKeyData: Data, signatureBase64: String, challenge: String) -> Bool {
        guard let publicKey = try? P256.Signing.PublicKey(rawRepresentation: publicKeyData),
              let signatureData = Data(base64Encoded: signatureBase64),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData) else { return false }
        return publicKey.isValidSignature(signature, for: authorizationData(challenge: challenge))
    }
}

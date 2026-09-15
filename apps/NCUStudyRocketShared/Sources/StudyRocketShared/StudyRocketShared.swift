import Foundation
import CryptoKit
#if os(macOS)
import Darwin
#endif

public enum StudyRocketAPI {
    public static let version = 1
    /// Version of the persisted academic-task/dynamic-tool contract.
    /// Bump this when a resumed task cannot safely reuse its tool registry.
    public static let academicTaskProtocolVersion = 4
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
    /// The Host's authoritative chat readiness. `dynamicToolsReady` remains
    /// for older clients that only understand the original protocol gate.
    public let chatState: String?
    public let chatIssueCode: String?

    public init(apiVersion: Int = StudyRocketAPI.version, hostVersion: String, repositoryBound: Bool, codexReady: Bool, pairedDeviceCount: Int, activeThreadID: String?, repositoryID: String? = nil, dynamicToolsReady: Bool? = nil, chatState: String? = nil, chatIssueCode: String? = nil) {
        self.apiVersion = apiVersion
        self.hostVersion = hostVersion
        self.repositoryBound = repositoryBound
        self.codexReady = codexReady
        self.pairedDeviceCount = pairedDeviceCount
        self.activeThreadID = activeThreadID
        self.repositoryID = repositoryID
        self.dynamicToolsReady = dynamicToolsReady
        self.chatState = chatState
        self.chatIssueCode = chatIssueCode
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
    public let issueCode: String?
    public let completedAt: Date?

    public init(kind: String, turnID: String? = nil, itemID: String? = nil, text: String? = nil, phase: String? = nil, status: String? = nil, issueCode: String? = nil, completedAt: Date? = nil) {
        self.kind = kind
        self.turnID = turnID
        self.itemID = itemID
        self.text = text
        self.phase = phase
        self.status = status
        self.issueCode = issueCode
        self.completedAt = completedAt
    }
}

public struct HomeSnapshot: Codable, Equatable, Sendable {
    public let dateLabel: String
    public let periods: [PeriodSnapshot]
    public let firstOpenTask: String?
    public let visibleDeliveries: [DeliverySnapshot]
    public let completedDeliveries: Int
    public let totalDeliveries: Int
    public let timetable: TimetableSnapshot?

    public init(dateLabel: String, periods: [PeriodSnapshot], firstOpenTask: String?, visibleDeliveries: [DeliverySnapshot], completedDeliveries: Int, totalDeliveries: Int, timetable: TimetableSnapshot? = nil) {
        self.dateLabel = dateLabel
        self.periods = periods
        self.firstOpenTask = firstOpenTask
        self.visibleDeliveries = visibleDeliveries
        self.completedDeliveries = completedDeliveries
        self.totalDeliveries = totalDeliveries
        self.timetable = timetable
    }

    private enum CodingKeys: String, CodingKey {
        case dateLabel, periods, firstOpenTask, visibleDeliveries, completedDeliveries, totalDeliveries, timetable
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dateLabel = try values.decode(String.self, forKey: .dateLabel)
        periods = try values.decode([PeriodSnapshot].self, forKey: .periods)
        firstOpenTask = try values.decodeIfPresent(String.self, forKey: .firstOpenTask)
        visibleDeliveries = try values.decode([DeliverySnapshot].self, forKey: .visibleDeliveries)
        completedDeliveries = try values.decode(Int.self, forKey: .completedDeliveries)
        totalDeliveries = try values.decode(Int.self, forKey: .totalDeliveries)
        timetable = try values.decodeIfPresent(TimetableSnapshot.self, forKey: .timetable)
    }
}

public struct PeriodTaskSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let isCompleted: Bool

    public init(id: String, text: String, isCompleted: Bool = false) {
        self.id = id
        self.text = text
        self.isCompleted = isCompleted
    }
}

/// Splits the explicit task-list notation stored inside a weekly-plan table
/// cell. Plain punctuation remains part of a task so ordinary Chinese prose is
/// never accidentally converted into several independently completable items.
public enum PeriodTaskParser {
    public static func tasks(from text: String, isCompleted: Bool = false) -> [PeriodTaskSnapshot] {
        let lineSeparated = text.replacingOccurrences(
            of: #"<br\s*/?>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        let taskTexts = lineSeparated
            .components(separatedBy: .newlines)
            .map(cleanedTaskText)
            .filter { !$0.isEmpty }

        var occurrences: [String: Int] = [:]
        return taskTexts.map { taskText in
            let identityText = normalizedIdentityText(taskText)
            let occurrence = (occurrences[identityText] ?? 0) + 1
            occurrences[identityText] = occurrence
            return PeriodTaskSnapshot(
                id: PeriodCompletion.taskKey(for: identityText, occurrence: occurrence),
                text: taskText,
                isCompleted: isCompleted
            )
        }
    }

    public static func displayText(from text: String) -> String {
        tasks(from: text).map(\.text).joined(separator: "\n")
    }

    private static func cleanedTaskText(_ value: String) -> String {
        let withoutCheckbox = value.replacingOccurrences(
            of: #"^\s*(?:[-*]\s+)?\[[ xX]\]\s*"#,
            with: "",
            options: .regularExpression
        )
        return withoutCheckbox
            .replacingOccurrences(
                of: #"^\s*[-*]\s+"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedIdentityText(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct PeriodSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let text: String
    public let tasks: [PeriodTaskSnapshot]
    public let isCompleted: Bool

    public init(
        id: String,
        title: String,
        text: String,
        isCompleted: Bool = false,
        tasks: [PeriodTaskSnapshot]? = nil
    ) {
        self.id = id
        self.title = title
        self.text = text
        let resolvedTasks = tasks ?? PeriodTaskParser.tasks(from: text, isCompleted: isCompleted)
        self.tasks = resolvedTasks
        self.isCompleted = !resolvedTasks.isEmpty && resolvedTasks.allSatisfy(\.isCompleted)
    }

    private enum CodingKeys: String, CodingKey { case id, title, text, tasks, isCompleted }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        text = try values.decode(String.self, forKey: .text)
        let legacyCompletion = try values.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        tasks = try values.decodeIfPresent([PeriodTaskSnapshot].self, forKey: .tasks)
            ?? PeriodTaskParser.tasks(from: text, isCompleted: legacyCompletion)
        isCompleted = !tasks.isEmpty && tasks.allSatisfy(\.isCompleted)
    }
}

public enum PeriodCompletion {
    public static func textHash(for text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func taskKey(for text: String, occurrence: Int) -> String {
        "task:\(textHash(for: text)):\(max(occurrence, 1))"
    }

    public static func isLegacyTextHash(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil
    }

    public static func isTaskKey(_ value: String) -> Bool {
        value.range(of: #"^task:[0-9a-fA-F]{64}:[1-9][0-9]*$"#, options: .regularExpression) != nil
    }

    public static func isValidRecordKey(_ value: String) -> Bool {
        isLegacyTextHash(value) || isTaskKey(value)
    }
}

public enum DeliveryPeriodMatcher {
    private static let statusWords = ["完成", "开始", "继续", "当天", "本轮", "进度"]

    public static func sourceKey(for deliveryText: String) -> String {
        let value = deliveryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return "delivery:\(digest)"
    }

    public static func matches(deliveryText: String, periodText: String) -> Bool {
        let deliveryChapter = chapter(in: deliveryText)
        let delivery = normalized(deliveryText)
        guard !delivery.isEmpty else { return false }

        return periodText.components(separatedBy: CharacterSet(charactersIn: "；;\n"))
            .contains { segment in
                if let deliveryChapter, chapter(in: segment) != deliveryChapter { return false }
                let period = normalized(segment)
                guard !period.isEmpty else { return false }
                let shorterCount = min(delivery.count, period.count)
                if shorterCount >= 6, delivery.contains(period) || period.contains(delivery) { return true }
                return diceCoefficient(delivery, period) >= 0.72
            }
    }

    private static func normalized(_ text: String) -> String {
        var value = text.precomposedStringWithCompatibilityMapping
        value = value.replacingOccurrences(
            of: #"^\s*(?:(?:\d{4})\s*[-年]\s*)?\d{1,2}\s*月\s*\d{1,2}\s*日?(?:\s*[·•]\s*周[一二三四五六日天])?\s*[：:]?\s*"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: #"《[^》]*》"#, with: "", options: .regularExpression)
        for word in statusWords { value = value.replacingOccurrences(of: word, with: "") }
        return String(value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func chapter(in text: String) -> String? {
        guard let range = text.range(of: #"第\s*[0-9一二三四五六七八九十百]+\s*章"#, options: .regularExpression) else { return nil }
        return String(text[range]).replacingOccurrences(of: " ", with: "")
    }

    private static func diceCoefficient(_ lhs: String, _ rhs: String) -> Double {
        let left = bigrams(lhs)
        let right = bigrams(rhs)
        guard !left.isEmpty, !right.isEmpty else { return lhs == rhs ? 1 : 0 }
        var remaining = right
        var overlap = 0
        for value in left {
            guard let index = remaining.firstIndex(of: value) else { continue }
            overlap += 1
            remaining.remove(at: index)
        }
        return Double(2 * overlap) / Double(left.count + right.count)
    }

    private static func bigrams(_ value: String) -> [String] {
        let characters = Array(value)
        guard characters.count > 1 else { return [] }
        return zip(characters, characters.dropFirst()).map { String([$0, $1]) }
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

/// Keeps scheduled tasks inside the three completable periods. The
/// `unassigned` column is reserved for items whose period cannot be inferred;
/// otherwise those items would be visible only as read-only explanatory text.
public enum WeeklyPlanTaskNormalizer {
    public static func normalized(
        periods: [PeriodSnapshot],
        unassigned: String
    ) -> (periods: [PeriodSnapshot], unassigned: String) {
        var taskTexts = periods.map { PeriodTaskParser.tasks(from: $0.text).map(\.text) }
        var unresolved: [String] = []

        for task in PeriodTaskParser.tasks(from: unassigned) {
            guard let periodID = periodID(for: task.text),
                  let index = periods.firstIndex(where: { $0.id == periodID }) else {
                unresolved.append(task.text)
                continue
            }
            taskTexts[index].append(task.text)
        }

        let resolvedPeriods = periods.enumerated().map { index, period in
            var completionByID: [String: Bool] = [:]
            for task in period.tasks {
                completionByID[task.id] = (completionByID[task.id] ?? false) || task.isCompleted
            }
            let text = taskTexts[index].joined(separator: "\n")
            let tasks = PeriodTaskParser.tasks(from: text).map { task in
                PeriodTaskSnapshot(
                    id: task.id,
                    text: task.text,
                    isCompleted: completionByID[task.id] ?? false
                )
            }
            return PeriodSnapshot(
                id: period.id,
                title: period.title,
                text: text,
                tasks: tasks
            )
        }

        return (resolvedPeriods, unresolved.joined(separator: "\n"))
    }

    public static func normalized(_ plan: WeeklyPlanSnapshot) -> WeeklyPlanSnapshot {
        WeeklyPlanSnapshot(
            days: plan.days.map { day in
                let layout = normalized(periods: day.slots, unassigned: day.unassigned)
                return DaySnapshot(
                    id: day.id,
                    dateLabel: day.dateLabel,
                    slots: layout.periods,
                    unassigned: layout.unassigned
                )
            },
            bufferRules: plan.bufferRules,
            deliveries: plan.deliveries,
            historicalRows: plan.historicalRows.map { row in
                let layout = normalized(periods: row.slots, unassigned: row.unassigned)
                return ScheduledRowSnapshot(
                    id: row.id,
                    dateLabel: row.dateLabel,
                    slots: layout.periods,
                    unassigned: layout.unassigned,
                    isCompleted: row.isCompleted
                )
            },
            futureRows: plan.futureRows.map { row in
                let layout = normalized(periods: row.slots, unassigned: row.unassigned)
                return ScheduledRowSnapshot(
                    id: row.id,
                    dateLabel: row.dateLabel,
                    slots: layout.periods,
                    unassigned: layout.unassigned,
                    isCompleted: row.isCompleted
                )
            }
        )
    }

    /// Normalizes the structured weekly table before a proposal is shown, so
    /// the approved diff and the eventual file write remain identical.
    public static func normalizedMarkdown(_ source: String) -> String {
        var lines = source.components(separatedBy: .newlines)
        let starts = lines.indices.filter { isMarker(lines[$0], "studyrocket:weekly:start") }
        let ends = lines.indices.filter { isMarker(lines[$0], "studyrocket:weekly:end") }
        guard starts.count == 1, ends.count == 1,
              let start = starts.first, let end = ends.first, start < end else { return source }

        for index in (start + 1)..<end {
            guard var cells = splitTableRow(lines[index]), cells.count >= 6 else { continue }
            let first = cells[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !first.contains("日期"),
                  !first.allSatisfy({ $0 == "-" || $0 == ":" || $0 == " " }) else { continue }

            let periodIDs = ["morning", "noon", "evening"]
            let periodTitles = ["上午", "中午", "晚上"]
            let periods = periodIDs.enumerated().map { offset, id in
                PeriodSnapshot(
                    id: id,
                    title: periodTitles[offset],
                    text: decodeCell(cells[offset + 1])
                )
            }
            let layout = normalized(periods: periods, unassigned: decodeCell(cells[4]))
            for offset in 0..<3 { cells[offset + 1] = encodeCell(layout.periods[offset].text) }
            cells[4] = encodeCell(layout.unassigned)
            lines[index] = renderTableRow(cells)
        }
        return lines.joined(separator: "\n")
    }

    private static let leadingTime = try! NSRegularExpression(
        pattern: #"^\s*(?:(清晨|早上|上午|中午|下午|傍晚|晚上|晚间)\s*)?([0-2]?\d)\s*(?:[:：]\s*([0-5]?\d)|点(?:\s*([0-5]?\d)\s*分?)?)"#
    )

    private static func periodID(for text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = leadingTime.firstMatch(in: text, range: range),
              let hourText = capture(match, group: 2, in: text),
              var hour = Int(hourText), (0...23).contains(hour) else { return nil }

        switch capture(match, group: 1, in: text) {
        case "下午", "傍晚", "晚上", "晚间":
            if hour < 12 { hour += 12 }
        case "中午":
            if (1..<11).contains(hour) { hour += 12 }
        case "清晨", "早上", "上午":
            if hour == 12 { hour = 0 }
        default:
            break
        }

        switch hour {
        case 0..<12: return "morning"
        case 12..<18: return "noon"
        default: return "evening"
        }
    }

    private static func capture(_ match: NSTextCheckingResult, group: Int, in text: String) -> String? {
        let range = match.range(at: group)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private static func isMarker(_ line: String, _ marker: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == "<!-- \(marker) -->"
    }

    private static func splitTableRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "|", trimmed.last == "|" else { return nil }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed.dropFirst().dropLast() {
            if character == "|", !escaped {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            if character == "\\" {
                escaped.toggle()
            } else {
                escaped = false
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func decodeCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\|", with: "|")
            .replacingOccurrences(
                of: #"<br\s*/?>"#,
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
    }

    private static func encodeCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func renderTableRow(_ cells: [String]) -> String {
        "| " + cells.joined(separator: " | ") + " |"
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
        var fence: Character?

        func tableCells(_ line: String) -> [String] {
            var cells: [String] = []
            var current = ""
            var escaped = false
            for character in line {
                if character == "|", !escaped {
                    cells.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(character)
                }
                if character == "\\" { escaped.toggle() } else { escaped = false }
            }
            cells.append(current.trimmingCharacters(in: .whitespaces))
            if cells.first?.isEmpty == true { cells.removeFirst() }
            if cells.last?.isEmpty == true { cells.removeLast() }
            return cells
        }

        func isTableLine(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let count = tableCells(line).count
            return !trimmed.hasPrefix("```") && !trimmed.hasPrefix("~~~")
                && (count >= 2 || (count == 1 && trimmed.hasPrefix("|") && trimmed.hasSuffix("|")))
        }

        func isDivider(_ line: String) -> Bool {
            let cells = tableCells(line)
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
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if let marker = trimmed.first, (trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")) {
                fence = fence == nil ? marker : (fence == marker ? nil : fence)
                prose.append(lines[index])
                index += 1
                continue
            }
            if fence != nil {
                prose.append(lines[index])
                index += 1
                continue
            }
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
            let columns = tableCells(lines[start]).count
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
    /// Terminal turns are separate so an upstream failure with no assistant
    /// item still stops a restored mobile spinner.
    public let terminalTurns: [ChatTurnTerminalDTO]?

    public init(revision: String, messages: [ChatMessageDTO], terminalTurns: [ChatTurnTerminalDTO]? = nil) {
        self.revision = revision
        self.messages = messages
        self.terminalTurns = terminalTurns
    }
}

public struct ChatTurnTerminalDTO: Codable, Equatable, Sendable, Identifiable {
    public let turnID: String
    public let status: String
    public let issueCode: String?
    public let message: String?
    public let completedAt: Date?

    public var id: String { turnID }

    public init(turnID: String, status: String, issueCode: String? = nil, message: String? = nil, completedAt: Date? = nil) {
        self.turnID = turnID
        self.status = status
        self.issueCode = issueCode
        self.message = message
        self.completedAt = completedAt
    }
}

public enum StudyRocketChatState: String, Codable, Equatable, Sendable {
    case starting
    case protocolReadyAuthUnknown
    case ready
    case authFailed
    case unavailable

    public var canGenerate: Bool {
        self == .protocolReadyAuthUnknown || self == .ready
    }
}

/// Only the two thread-setting fields that may safely cross the app-server
/// boundary. Do not persist, log, or expose the complete `config/read` result.
public struct StudyRocketModelSelection: Equatable, Sendable {
    public let model: String
    public let modelProvider: String

    public init(model: String, modelProvider: String) {
        self.model = model
        self.modelProvider = modelProvider
    }

    public static func configReadResult(_ value: [String: Any]) -> StudyRocketModelSelection? {
        selection(in: (value["config"] as? [String: Any]) ?? value, providerKey: "model_provider")
    }

    public static func threadResult(_ value: [String: Any]) -> StudyRocketModelSelection? {
        selection(in: (value["thread"] as? [String: Any]) ?? value, providerKey: "modelProvider")
    }

    private static func selection(in value: [String: Any], providerKey: String) -> StudyRocketModelSelection? {
        guard let model = value["model"] as? String,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let provider = value[providerKey] as? String,
              !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return StudyRocketModelSelection(model: model, modelProvider: provider)
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

public struct PeriodCompletionToggleRequest: Codable, Equatable, Sendable {
    public let dayID: String
    public let periodID: String
    /// Present for current clients. The ID is derived from the task text and
    /// its occurrence inside a period, which makes duplicate task text safe.
    public let taskID: String?
    /// Retained only to decode and safely reject or replay legacy whole-period
    /// requests that may still be stored on an older phone.
    public let textHash: String?
    public let isCompleted: Bool
    public let metadata: WriteMetadata

    public init(dayID: String, periodID: String, taskID: String, isCompleted: Bool, metadata: WriteMetadata) {
        self.dayID = dayID
        self.periodID = periodID
        self.taskID = taskID
        self.textHash = nil
        self.isCompleted = isCompleted
        self.metadata = metadata
    }

    public init(dayID: String, periodID: String, textHash: String, isCompleted: Bool, metadata: WriteMetadata) {
        self.dayID = dayID
        self.periodID = periodID
        self.taskID = nil
        self.textHash = textHash
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

    public static func sign(privateKey: P256.Signing.PrivateKey, method: String, path: String, timestamp: Int64, nonce: String, bodyHash: String) throws -> String {
        let signature = try privateKey.signature(for: canonicalData(method: method, path: path, timestamp: timestamp, nonce: nonce, bodyHash: bodyHash))
        return signature.rawRepresentation.base64EncodedString()
    }

    public static func signAuthorization(privateKey: P256.Signing.PrivateKey, challenge: String) throws -> String {
        let signature = try privateKey.signature(for: authorizationData(challenge: challenge))
        return signature.rawRepresentation.base64EncodedString()
    }

#if os(iOS)
    public static func sign(privateKey: SecureEnclave.P256.Signing.PrivateKey, method: String, path: String, timestamp: Int64, nonce: String, bodyHash: String) throws -> String {
        let signature = try privateKey.signature(for: canonicalData(method: method, path: path, timestamp: timestamp, nonce: nonce, bodyHash: bodyHash))
        return signature.rawRepresentation.base64EncodedString()
    }

    public static func signAuthorization(privateKey: SecureEnclave.P256.Signing.PrivateKey, challenge: String) throws -> String {
        let signature = try privateKey.signature(for: authorizationData(challenge: challenge))
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

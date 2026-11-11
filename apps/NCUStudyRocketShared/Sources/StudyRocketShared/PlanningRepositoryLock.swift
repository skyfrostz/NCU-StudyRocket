import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Synchronous, reentrant coordination for Desktop/Host Markdown transactions.
/// Revision/hash checks must happen after acquiring the lock; no lock spans an await.
public final class PlanningRepositoryLock {
    private static let processLock = NSRecursiveLock()
    private let descriptor: Int32?
    private let key: String
    private var released = false

    private init(descriptor: Int32?, key: String) { self.descriptor = descriptor; self.key = key }

    public static func acquire(root: URL) throws -> PlanningRepositoryLock {
        processLock.lock()
        let key = "studyrocket-planning-" + PeriodCompletion.textHash(for: root.standardizedFileURL.resolvingSymlinksInPath().path)
        if Thread.current.threadDictionary[key] != nil { return PlanningRepositoryLock(descriptor: nil, key: key) }
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("NCU StudyRocket/Planning Locks", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let descriptor = open(directory.appendingPathComponent(key).path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw TaskLinkageError.changed }
            guard flock(descriptor, LOCK_EX) == 0 else { close(descriptor); throw TaskLinkageError.changed }
            Thread.current.threadDictionary[key] = true
            return PlanningRepositoryLock(descriptor: descriptor, key: key)
        } catch { processLock.unlock(); throw error }
    }

    public func unlock() {
        guard !released else { return }; released = true
        if let descriptor {
            flock(descriptor, LOCK_UN); close(descriptor)
            Thread.current.threadDictionary.removeObject(forKey: key)
        }
        Self.processLock.unlock()
    }
    deinit { unlock() }
}

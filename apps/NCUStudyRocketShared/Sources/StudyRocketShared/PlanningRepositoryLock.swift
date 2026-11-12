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
            #if os(Linux)
            // Cloud's service can write only its bound data directory. Lock the
            // repository inode itself instead of creating a file in the user's
            // Application Support directory outside that sandbox. Canonical
            // aliases share the same lock, and process exit releases the fd.
            let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            let descriptor = open(canonicalRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            #else
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("NCU StudyRocket/Planning Locks", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let descriptor = open(directory.appendingPathComponent(key).path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            #endif
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

import Foundation
import StudyRocketShared
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

func handlePlanningRepositoryLockChild() throws {
    let args = CommandLine.arguments
    guard args.dropFirst().first == "--planning-lock-child" else { return }
    precondition(args.count == 5)
    let lock = try PlanningRepositoryLock.acquire(root: URL(fileURLWithPath: args[2]))
    try Data("acquired".utf8).write(to: URL(fileURLWithPath: args[3]))
    if args[4] == "hold" {
        while true { Thread.sleep(forTimeInterval: 0.02) }
    }
    lock.unlock()
    exit(0)
}

func runPlanningRepositoryLockChecks() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("planning-lock-check-" + UUID().uuidString)
    let root = base.appendingPathComponent("中文学业仓库")
    let alias = base.appendingPathComponent("同仓库别名")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: alias, withDestinationURL: root)
    let original = Data("原始事实\r\nUnicode：学业é\n".utf8)
    try original.write(to: root.appendingPathComponent("原文.md"))
    var children: [Process] = []
    defer {
        for child in children where child.isRunning {
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
        }
        try? fm.removeItem(at: base)
    }
    func child(_ path: URL, marker: URL, hold: Bool = false) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--planning-lock-child", path.path, marker.path, hold ? "hold" : "once"]
        try process.run()
        children.append(process)
        return process
    }
    func awaitMarker(_ marker: URL, process: Process) {
        let deadline = Date().addingTimeInterval(3)
        while !fm.fileExists(atPath: marker.path) && process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        precondition(fm.fileExists(atPath: marker.path), "Child did not acquire the repository lock")
    }
    func awaitExit(_ process: Process) {
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        precondition(!process.isRunning, "Child did not release and exit")
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
    }

    // Releasing an inner alias acquisition must leave the outer lock held.
    let outer = try PlanningRepositoryLock.acquire(root: root)
    let inner = try PlanningRepositoryLock.acquire(root: alias)
    inner.unlock()
    let firstMarker = base.appendingPathComponent("contender-ready")
    let contender = try child(alias, marker: firstMarker)
    Thread.sleep(forTimeInterval: 0.15)
    precondition(contender.isRunning && !fm.fileExists(atPath: firstMarker.path), "Alias bypassed the outer repository lock")
    outer.unlock()
    outer.unlock() // Explicit unlock followed by deinit is intentionally harmless.
    awaitMarker(firstMarker, process: contender)
    awaitExit(contender)
    print("Planning lock checks passed: canonical aliases, nested acquisition and cross-process exclusion")

    let heldMarker = base.appendingPathComponent("holder-ready")
    let holder = try child(root, marker: heldMarker, hold: true)
    awaitMarker(heldMarker, process: holder)
    let afterExitMarker = base.appendingPathComponent("after-exit-ready")
    let afterExit = try child(alias, marker: afterExitMarker)
    Thread.sleep(forTimeInterval: 0.15)
    precondition(afterExit.isRunning && !fm.fileExists(atPath: afterExitMarker.path))
    precondition(kill(holder.processIdentifier, SIGKILL) == 0)
    holder.waitUntilExit()
    awaitMarker(afterExitMarker, process: afterExit)
    awaitExit(afterExit)
    print("Planning lock checks passed: abrupt process exit releases the same repository lock")

    #if os(Linux)
    let descriptorCount = try fm.contentsOfDirectory(atPath: "/proc/self/fd").count
    for _ in 0..<20 {
        do {
            _ = try PlanningRepositoryLock.acquire(root: root.appendingPathComponent("原文.md"))
            preconditionFailure("A file was accepted as a repository directory")
        } catch is TaskLinkageError { }
        let recovered = try PlanningRepositoryLock.acquire(root: root)
        recovered.unlock()
    }
    let finalDescriptorCount = try fm.contentsOfDirectory(atPath: "/proc/self/fd").count
    precondition(finalDescriptorCount <= descriptorCount + 1)
    let oldLockName = "studyrocket-planning-" + PeriodCompletion.textHash(for: root.standardizedFileURL.resolvingSymlinksInPath().path)
    let oldLockFile = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NCU StudyRocket/Planning Locks").appendingPathComponent(oldLockName)
    precondition(!fm.fileExists(atPath: oldLockFile.path), "Linux locking created a file outside the bound repository")
    print("Planning lock checks passed: failed acquisition releases process state and descriptors")
    #endif
    let remaining = try fm.contentsOfDirectory(atPath: root.path)
    let preserved = try Data(contentsOf: root.appendingPathComponent("原文.md"))
    precondition(remaining == ["原文.md"] && preserved == original, "Locking changed repository bytes or created metadata files")
    print("Planning lock checks passed: Unicode repository bytes preserved without extra files")
}

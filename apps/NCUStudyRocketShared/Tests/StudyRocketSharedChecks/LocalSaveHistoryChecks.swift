#if os(macOS)
import Foundation
import StudyRocketShared

func checkLocalSaveHistory() throws {
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("studyrocket-history-check-\(UUID())")
    let root = fixture.appendingPathComponent("repo")
    let state = fixture.appendingPathComponent("state")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("工作台"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false"] + arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let result = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: result, code: Int(process.terminationStatus)) }
        return result.trimmingCharacters(in: .newlines)
    }

    func write(_ path: String, _ value: String) throws {
        try Data(value.utf8).write(to: root.appendingPathComponent(path))
    }

    let plan = "工作台/计划.md"
    let fact = "工作台/新记录.md"
    let ignored = "工作台/忽略.md"
    try git("init", "-q")
    try git("config", "user.name", "StudyRocket Fixture")
    try git("config", "user.email", "fixture@example.invalid")
    try write("PROFILE.md", "原档案\n")
    try write(plan, "原计划\n")
    try write("app.swift", "original code\n")
    try write(".gitignore", "\(ignored)\n")
    try git("add", "--", "PROFILE.md", plan, "app.swift", ".gitignore")
    try git("commit", "-qm", "fixture")
    let head = try git("rev-parse", "HEAD")

    // Keep unrelated staging and a manual edit on the same file outside the app history.
    try write("app.swift", "staged code\n")
    try git("add", "--", "app.swift")
    try write("PROFILE.md", "手工编辑\n")
    let index = root.appendingPathComponent(".git/index")
    let originalIndex = try Data(contentsOf: index)
    let history = LocalSaveHistory(stateDirectory: state)
    let reference = LocalSaveHistory.reference

    try write(plan, "第一次保存\n")
    history.record([.init(relative: plan, before: Data("原计划\n".utf8), after: Data("第一次保存\n".utf8))], in: root)
    try write(plan, "第二次保存\n")
    try write(fact, "新记录\n")
    try write(ignored, "忽略内容\n")
    try write("PROFILE.md", "手工编辑\n应用保存\n")
    history.record([
        .init(relative: plan, before: Data("第一次保存\n".utf8), after: Data("第二次保存\n".utf8)),
        .init(relative: fact, before: nil, after: Data("新记录\n".utf8)),
        .init(relative: ignored, before: nil, after: Data("忽略内容\n".utf8)),
        .init(relative: "PROFILE.md", before: Data("手工编辑\n".utf8), after: Data("手工编辑\n应用保存\n".utf8)),
        .init(relative: "app.swift", before: Data("original code\n".utf8), after: Data("staged code\n".utf8))
    ], in: root)
    history.flush()
    let parents = try git("rev-list", "--count", "\(head)..\(reference)")
    let paths = try git("diff", "--name-only", "--no-renames", "-z", head, reference)
    let savedPlan = try git("show", "\(reference):\(plan)")
    let savedFact = try git("show", "\(reference):\(fact)")
    let currentHead = try git("rev-parse", "HEAD")
    let currentIndex = try Data(contentsOf: index)
    precondition(parents == "1")
    precondition(Set(paths.split(separator: "\0").map(String.init)) == [plan, fact])
    precondition(savedPlan == "第二次保存" && savedFact == "新记录")
    precondition(currentHead == head && currentIndex == originalIndex)
    let status = history.status(for: root)
    precondition(status.contains("PROFILE.md（保存前的内容与本地版本不一致）"))
    precondition(status.contains("\(ignored)（仓库设置为忽略此文件）"))

    // A subsequent save continues the local ref. Later external writes stay in the working tree.
    try write(plan, "第三次保存\n")
    history.record([.init(relative: plan, before: Data("第二次保存\n".utf8), after: Data("第三次保存\n".utf8))], in: root)
    try write(plan, "之后的手工编辑\n")
    history.flush()
    let nextPlan = try git("show", "\(reference):\(plan)")
    let workingPlan = try String(contentsOf: root.appendingPathComponent(plan), encoding: .utf8)
    precondition(nextPlan == "第三次保存" && workingPlan == "之后的手工编辑\n")

    // A staged edit to the exact target leaves the private ref and real index untouched.
    try git("add", "--", plan)
    try write(plan, "新保存\n")
    let refBeforeSkip = try git("rev-parse", reference)
    let stagedIndex = try Data(contentsOf: index)
    history.record([.init(relative: plan, before: Data("之后的手工编辑\n".utf8), after: Data("新保存\n".utf8))], in: root)
    history.flush()
    let refAfterSkip = try git("rev-parse", reference)
    let indexAfterSkip = try Data(contentsOf: index)
    precondition(refBeforeSkip == refAfterSkip && stagedIndex == indexAfterSkip)
    precondition(history.status(for: root).contains("已有暂存改动"))
    print("LocalSaveHistoryChecks: batching, path safety, staging isolation, exact saved bytes and local-only ref passed")
}
#endif

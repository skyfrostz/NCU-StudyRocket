import AppKit
import SwiftUI
import StudyRocketShared

@main struct LocalSeedChecks {
 @MainActor static func main() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-seed-qa-\(UUID())")
  try FileManager.default.createDirectory(at: root.appendingPathComponent("工作台"), withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let now = Date(), today = PlanningDate.key(now)
  let morning = "复习合成章节"
  let source = """
  # 临时周计划
  <!-- studyrocket:weekly:start -->
  | 日期 | 上午 | 中午 | 晚上 | 待安排 | 完成 |
  | --- | --- | --- | --- | --- | --- |
  | \(today) | \(morning) | 发送合成邮件 |  |  | [ ] |
  <!-- studyrocket:weekly:end -->
  <!-- studyrocket:period-completion:start -->
  | 日期 | 时段 | 文本哈希 | 完成 |
  | --- | --- | --- | --- |
  | \(today) | morning | \(PeriodCompletion.textHash(for: morning)) | [x] |
  <!-- studyrocket:period-completion:end -->
  ## 交付物清单
  - [x] 已完成合成周总结
  ## 缓冲
  - 原缓冲
  外部说明原样保留。
  """
  let file = root.appendingPathComponent("工作台/下周计划.md")
  try Data(source.utf8).write(to: file)
  let week = AcademicSnapshotBuilder(root: root).build(now: now).week
  let seed = TaskLinkage(activationDate: today).reconciled(with: week, now: now)
  precondition(seed.tasks.count == 2 && seed.tasks.filter(\.isCompleted).count == 1)
  precondition(seed.deliveries.count == 1 && seed.deliveries[0].completedAt != nil)
  let open = seed.tasks.firstIndex(where: { !$0.isCompleted })!
  let done = seed.tasks.firstIndex(where: \.isCompleted)!
  var cases: [(String, TaskLinkage)] = []
  var bad = seed; bad.tasks[open].completedAt = today; bad.tasks[open].completionSource = "independent"; cases.append(("fabricated completion", bad))
  bad = seed; bad.tasks[done].completedAt = nil; bad.tasks[done].completionSource = nil; cases.append(("erased legacy completion", bad))
  bad = seed; bad.tasks[done].completionSource = "fabricated"; cases.append(("changed completion source", bad))
  bad = seed; let removed = bad.tasks.remove(at: open).id; bad.assignments.removeAll { $0.taskID == removed }; cases.append(("omitted existing task", bad))
  bad = seed; bad.tasks[open].originDate = "2026-01-01"; cases.append(("changed origin", bad))
  bad = seed; bad.assignments[0].date = "2027-01-01"; cases.append(("changed assignment identity", bad))
  bad = seed; bad.activationDate = "2026-01-01"; cases.append(("changed activation", bad))
  bad = seed; bad.deliveries[0].completedAt = nil; cases.append(("erased delivery completion", bad))
  let desktop = StudyChatStore(configuration: nil); desktop.root = root
  let host = HostProposalStore(root: root, backupRoot: root.appendingPathComponent("backups"))
  for (name, graph) in cases {
   let candidate = try TaskLinkageMarkdown.write(graph, in: source)
   let args: [String: Any] = ["path": "工作台/下周计划.md", "content": candidate, "reason": "fixture"]
   precondition(desktop.registerProposal(tool: "propose_changes", arguments: args, turnID: name)["success"] as? Bool == false, "Desktop accepted \(name)")
   precondition(host.register(arguments: args, tool: "propose_changes", turnID: name)["success"] as? Bool == false, "Host accepted \(name)")
   precondition(desktop.transcript.proposals.isEmpty && host.list().proposals.isEmpty)
   precondition(try! Data(contentsOf: file) == Data(source.utf8))
   print("PASS Desktop+Host: \(name) rejected; no pending proposal or write")
  }
  var valid = seed
  for index in valid.tasks.indices { valid.tasks[index].category = .study }
  let candidate = try TaskLinkageMarkdown.write(valid, in: source)
  let args: [String: Any] = ["path": "工作台/下周计划.md", "content": candidate, "reason": "fixture"]
  let changedSource = source.replacingOccurrences(of: "发送合成邮件", with: "发送已更新合成邮件")
  try Data(changedSource.utf8).write(to: file, options: .atomic)
  precondition(desktop.registerProposal(tool: "propose_changes", arguments: args, turnID: "stale")["success"] as? Bool == false)
  precondition(host.register(arguments: args, tool: "propose_changes", turnID: "stale")["success"] as? Bool == false)
  precondition(desktop.transcript.proposals.isEmpty && host.list().proposals.isEmpty)
  precondition(try! Data(contentsOf: file) == Data(changedSource.utf8))
  print("PASS Desktop+Host: stale seed rejected against current file; external edit preserved")
  try Data(source.utf8).write(to: file, options: .atomic)
  precondition(desktop.registerProposal(tool: "propose_changes", arguments: args, turnID: "valid")["success"] as? Bool == true)
  precondition(host.register(arguments: args, tool: "propose_changes", turnID: "valid")["success"] as? Bool == true)
  for content in [desktop.transcript.proposals[0].proposedContent, host.list().proposals[0].proposedContent] {
   let accepted = try TaskLinkageMarkdown.read(content)!
   try PlanningProposalValidation.preserveHistory(from: seed, in: accepted)
   precondition(accepted.tasks.allSatisfy { $0.category == .study })
  }
  precondition(try! Data(contentsOf: file) == Data(source.utf8))
  print("PASS Desktop+Host: legitimate initial activation retains legacy task/delivery completion and explicit categories; pending only")
  print("20/20 local registration assertions PASS")
 }
}

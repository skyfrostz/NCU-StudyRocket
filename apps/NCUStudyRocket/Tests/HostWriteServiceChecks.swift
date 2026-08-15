import Foundation
import StudyRocketShared

@main
struct HostWriteServiceChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("studyrocket-host-write-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("工作台", isDirectory: true),
            withIntermediateDirectories: true
        )

        let label = shortDateLabel(Date())
        let planFile = root.appendingPathComponent("工作台/下周计划.md")
        let source = """
        # 临时计划

        <!-- studyrocket:weekly:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        |------|------|------|------|----------|------|
        | \(label) | 原上午 | 原中午 | 原晚上 |  | [ ] |
        <!-- studyrocket:weekly:end -->

        ## 交付物清单
        - [ ] 原交付物

        ## 缓冲
        - 原缓冲

        ## 保留说明
        此段不属于移动端管理范围。
        """
        try Data(source.utf8).write(to: planFile)

        let builder = HostSnapshotBuilder(root: root)
        let initial = builder.build()
        guard var day = initial.week.days.first else { fatalError("missing current day") }
        day = DaySnapshot(
            id: day.id,
            dateLabel: day.dateLabel,
            slots: [
                PeriodSnapshot(id: "morning", title: "上午", text: "移动端上午计划"),
                PeriodSnapshot(id: "noon", title: "中午", text: "移动端中午计划"),
                PeriodSnapshot(id: "evening", title: "晚上", text: "移动端晚上计划")
            ]
        )
        let updatedDays = [day] + initial.week.days.dropFirst()
        let delivery = DeliverySnapshot(
            id: "delivery-1",
            text: "\(label)：已完成的移动端交付物\n附加验收条件",
            isCompleted: true,
            dateLabel: label
        )
        let buffer = BufferRuleSnapshot(
            id: "buffer-1",
            category: "collision",
            text: "发生撞车时保核心任务\n停止额外扩展"
        )
        let request = PlanWriteRequest(
            plan: WeeklyPlanSnapshot(
                days: updatedDays,
                bufferRules: [buffer],
                deliveries: [delivery],
                historicalRows: initial.week.historicalRows,
                futureRows: initial.week.futureRows
            ),
            metadata: WriteMetadata(baseRevision: initial.revision, idempotencyKey: "host-write-check")
        )

        _ = try HostWriteService(root: root).applyWeek(request)
        let written = try String(contentsOf: planFile, encoding: .utf8)
        try require(written.contains("移动端上午计划"), "schedule was not persisted")
        try require(written.contains("<!-- studyrocket:deliveries:start -->"), "delivery boundary missing")
        try require(written.contains("- [x] \(label)：已完成的移动端交付物\n  附加验收条件"), "multiline delivery or completion state was lost")
        try require(written.contains("<!-- studyrocket:buffer:start -->"), "buffer boundary missing")
        try require(written.contains("### 撞车降级\n- 发生撞车时保核心任务\n  停止额外扩展"), "multiline buffer rule was not persisted")
        try require(written.contains("此段不属于移动端管理范围。"), "unmanaged text changed")
        print("HostWriteServiceChecks: plan, deliveries and buffer rules persisted")
    }

    private static func shortDateLabel(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "HostWriteServiceChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}

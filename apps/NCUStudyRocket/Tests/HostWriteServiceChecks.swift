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

        let service = HostWriteService(root: root)
        let applied = try service.applyWeek(request)
        let written = try String(contentsOf: planFile, encoding: .utf8)
        try require(written.contains("移动端上午计划"), "schedule was not persisted")
        try require(written.contains("<!-- studyrocket:deliveries:start -->"), "delivery boundary missing")
        try require(written.contains("- [x] \(label)：已完成的移动端交付物\n  附加验收条件"), "multiline delivery or completion state was lost")
        try require(written.contains("<!-- studyrocket:buffer:start -->"), "buffer boundary missing")
        try require(written.contains("### 撞车降级\n- 发生撞车时保核心任务\n  停止额外扩展"), "multiline buffer rule was not persisted")
        try require(written.contains("此段不属于移动端管理范围。"), "unmanaged text changed")
        try require(written.contains("<!-- studyrocket:weekly:end -->\n<!-- studyrocket:period-completion:start -->"), "period completion block is not immediately after weekly:end")

        guard let appliedDay = applied.week.days.first,
              let appliedMorning = appliedDay.slots.first(where: { $0.id == "morning" }),
              let appliedMorningTask = appliedMorning.tasks.first else {
            fatalError("missing current morning period")
        }
        let toggleRequest = PeriodCompletionToggleRequest(
            dayID: appliedDay.id,
            periodID: appliedMorning.id,
            taskID: appliedMorningTask.id,
            isCompleted: true,
            metadata: WriteMetadata(baseRevision: applied.revision, idempotencyKey: "period-toggle-on")
        )
        let completed = try service.togglePeriod(toggleRequest)
        try require(completed.home.periods.first(where: { $0.id == "morning" })?.isCompleted == true, "completed period was not reflected in snapshot")
        try require(completed.home.firstOpenTask == "移动端中午计划", "first open task did not skip completed morning period")
        let completedSource = try String(contentsOf: planFile, encoding: .utf8)
        let completionBody = try managedCompletionBody(completedSource)
        try require(completionBody.contains("| \(appliedDay.id) | morning | \(appliedMorningTask.id) | [x] |"), "completed task row was not persisted")
        try require(completionBody.components(separatedBy: .newlines).filter { $0.hasPrefix("| \(appliedDay.id) |") }.count == 1, "completion block contains duplicate rows")
        try require(!completionBody.contains("[ ]"), "incomplete rows must not be persisted")

        let replayed = try service.togglePeriod(toggleRequest)
        try require(replayed == completed, "idempotent period toggle did not replay its original response")
        try require(try String(contentsOf: planFile, encoding: .utf8) == completedSource, "idempotent period toggle rewrote Markdown")

        let externallyEdited = completedSource.replacingOccurrences(of: "移动端上午计划", with: "外部改写上午")
        try Data(externallyEdited.utf8).write(to: planFile, options: .atomic)
        let stale = builder.build()
        try require(stale.home.periods.first(where: { $0.id == "morning" })?.isCompleted == false, "stale text hash incorrectly completed changed content")
        try require(stale.home.firstOpenTask == "外部改写上午", "stale completion incorrectly hid the first open task")

        guard let staleDay = stale.week.days.first else { fatalError("missing stale day") }
        var rewrittenSlots = staleDay.slots
        rewrittenSlots[0] = PeriodSnapshot(id: "morning", title: "上午", text: "重写后上午")
        let rewrittenDay = DaySnapshot(id: staleDay.id, dateLabel: staleDay.dateLabel, slots: rewrittenSlots, unassigned: staleDay.unassigned)
        let pruneRequest = PlanWriteRequest(
            plan: WeeklyPlanSnapshot(
                days: [rewrittenDay] + stale.week.days.dropFirst(),
                bufferRules: stale.week.bufferRules,
                deliveries: stale.week.deliveries,
                historicalRows: stale.week.historicalRows,
                futureRows: stale.week.futureRows
            ),
            metadata: WriteMetadata(baseRevision: stale.revision, idempotencyKey: "period-prune")
        )
        let pruned = try service.applyWeek(pruneRequest)
        let prunedSource = try String(contentsOf: planFile, encoding: .utf8)
        try require(!prunedSource.contains(appliedMorningTask.id), "applyWeek did not prune stale task completion")
        try require(pruned.home.periods.first(where: { $0.id == "morning" })?.isCompleted == false, "rewritten period inherited stale completion")

        guard let rewrittenMorning = pruned.home.periods.first(where: { $0.id == "morning" }) else { fatalError("missing rewritten morning") }
        guard let rewrittenTask = rewrittenMorning.tasks.first else { fatalError("missing rewritten task") }
        let checked = try service.togglePeriod(PeriodCompletionToggleRequest(
            dayID: staleDay.id,
            periodID: "morning",
            taskID: rewrittenTask.id,
            isCompleted: true,
            metadata: WriteMetadata(baseRevision: pruned.revision, idempotencyKey: "period-recheck")
        ))
        let unchecked = try service.togglePeriod(PeriodCompletionToggleRequest(
            dayID: staleDay.id,
            periodID: "morning",
            taskID: rewrittenTask.id,
            isCompleted: false,
            metadata: WriteMetadata(baseRevision: checked.revision, idempotencyKey: "period-toggle-off")
        ))
        try require(unchecked.home.periods.first(where: { $0.id == "morning" })?.isCompleted == false, "period toggle off was not reflected in snapshot")
        try require(!(try managedCompletionBody(String(contentsOf: planFile, encoding: .utf8))).contains("| \(staleDay.id) | morning |"), "unchecked period row remained persisted")
        try require((try String(contentsOf: planFile, encoding: .utf8)).contains("此段不属于移动端管理范围。"), "period writes changed unmanaged Markdown")

        try testInvalidDailyDateCannotEscapeWorkspace()
        try testDeliveryToggleStaysInsideManagedSection()
        try testDeliveryPeriodLinkingAndSources()
        try testIndependentPeriodTasksAndLegacyCompatibility()
        try testTimedUnassignedTasksBecomeCompletablePeriods()
        try testWeeklyProposalIsNormalizedBeforeApproval()
        try testHistoricalAndFutureCompletionRecordsSurviveSave()
        try testCurrentWindowRowsPromoteAcrossSections()
        try testMalformedMarkersAndMarkerInjectionAreRejected()
        try testSnapshotRejectsExternalSymlinks()
        try testTimetableSnapshotAndRevision()
        print("HostWriteServiceChecks: writes, boundaries, path safety and completion lifecycle passed")
    }

    private static func testInvalidDailyDateCannotEscapeWorkspace() throws {
        let root = try makeWorkspace(source: validSource())
        defer { try? FileManager.default.removeItem(at: root) }
        let planFile = root.appendingPathComponent("工作台/下周计划.md")
        let original = try Data(contentsOf: planFile)
        let snapshot = HostSnapshotBuilder(root: root).build()
        let request = DailyWriteRequest(
            entry: DailySnapshot(date: "../下周计划", deliverables: "不应写入"),
            metadata: WriteMetadata(baseRevision: snapshot.revision, idempotencyKey: "invalid-date")
        )
        try requireHostError("invalid_date") { _ = try HostWriteService(root: root).applyDaily(request) }
        try require(try Data(contentsOf: planFile) == original, "invalid daily date changed the weekly plan")
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("下周计划.md").path), "invalid daily date escaped the managed directory")
    }

    private static func testDeliveryToggleStaysInsideManagedSection() throws {
        let source = validSource(deliveryBody: """
        <!-- studyrocket:deliveries:start -->
        - [ ] 同名任务
          验收条件
        <!-- studyrocket:deliveries:end -->
        """) + """

        ## 其他清单
        - [ ] 同名任务
          验收条件
        """
        let root = try makeWorkspace(source: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = HostSnapshotBuilder(root: root)
        let snapshot = builder.build()
        _ = try HostWriteService(root: root).toggleDelivery(DeliveryToggleRequest(
            text: "同名任务\n验收条件",
            isCompleted: true,
            metadata: WriteMetadata(baseRevision: snapshot.revision, idempotencyKey: "managed-delivery-toggle")
        ))
        let written = try String(contentsOf: root.appendingPathComponent("工作台/下周计划.md"), encoding: .utf8)
        try require(written.contains("<!-- studyrocket:deliveries:start -->\n- [x] 同名任务\n  验收条件"), "managed multiline delivery was not toggled")
        try require(written.contains("## 其他清单\n- [ ] 同名任务\n  验收条件"), "an equal checkbox outside the delivery section was changed")
    }

    private static func testDeliveryPeriodLinkingAndSources() throws {
        let label = shortDateLabel(Date())
        let matchingA = "\(label)：完成第 3 章网课并跟学例题"
        let matchingB = "\(label)：完成第 3 章当天网课进度并跟学例题"
        let chapterMismatch = "\(label)：完成第 4 章网课并跟学例题"
        let noDate = "完成第 3 章网课并跟学例题"
        let source = """
        # 临时计划

        <!-- studyrocket:weekly:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        |------|------|------|------|----------|------|
        | \(label) | 第 3 章：继续网课并跟学例题 | 第 3 章：继续网课并跟学例题 | 第 5 章：整理错题 |  | [ ] |
        <!-- studyrocket:weekly:end -->

        ## 交付物清单
        <!-- studyrocket:deliveries:start -->
        - [ ] \(matchingA)
        - [ ] \(matchingB)
        - [ ] \(chapterMismatch)
        - [ ] \(noDate)
        <!-- studyrocket:deliveries:end -->

        ## 缓冲
        - 原缓冲
        """
        let root = try makeWorkspace(source: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = HostWriteService(root: root)
        var snapshot = HostSnapshotBuilder(root: root).build()
        guard let day = snapshot.week.days.first,
              let morning = day.slots.first(where: { $0.id == "morning" }),
              let morningTask = morning.tasks.first else { fatalError("missing linked period") }

        snapshot = try service.togglePeriod(PeriodCompletionToggleRequest(
            dayID: day.id,
            periodID: morning.id,
            taskID: morningTask.id,
            isCompleted: true,
            metadata: WriteMetadata(baseRevision: snapshot.revision, idempotencyKey: "source-manual")
        ))
        snapshot = try service.toggleDelivery(DeliveryToggleRequest(
            text: matchingA,
            isCompleted: true,
            metadata: WriteMetadata(baseRevision: snapshot.revision, idempotencyKey: "source-a-on")
        ))
        snapshot = try service.toggleDelivery(DeliveryToggleRequest(
            text: matchingB,
            isCompleted: true,
            metadata: WriteMetadata(baseRevision: snapshot.revision, idempotencyKey: "source-b-on")
        ))

        let sourceA = DeliveryPeriodMatcher.sourceKey(for: matchingA)
        let sourceB = DeliveryPeriodMatcher.sourceKey(for: matchingB)
        var completion = try managedCompletionBody(String(contentsOf: root.appendingPathComponent("工作台/下周计划.md"), encoding: .utf8))
        try require(completion.contains("| \(day.id) | morning | \(morningTask.id) | [x] |  |"), "manual source was not retained beside delivery sources")
        try require(completion.components(separatedBy: sourceA).count - 1 == 2, "first delivery did not link all reliable same-day periods")
        try require(completion.components(separatedBy: sourceB).count - 1 == 2, "second delivery did not link all reliable same-day periods")

        snapshot = try service.toggleDelivery(DeliveryToggleRequest(
            text: matchingA,
            isCompleted: false,
            metadata: WriteMetadata(baseRevision: snapshot.revision, idempotencyKey: "source-a-off")
        ))
        completion = try managedCompletionBody(String(contentsOf: root.appendingPathComponent("工作台/下周计划.md"), encoding: .utf8))
        try require(!completion.contains(sourceA) && completion.contains(sourceB), "delivery cancellation removed another completion source")
        try require(snapshot.home.periods.first(where: { $0.id == "morning" })?.isCompleted == true, "remaining manual or delivery source did not keep the period complete")

        snapshot = try service.toggleDelivery(DeliveryToggleRequest(
            text: matchingB,
            isCompleted: false,
            metadata: WriteMetadata(baseRevision: snapshot.revision, idempotencyKey: "source-b-off")
        ))
        try require(snapshot.home.periods.first(where: { $0.id == "morning" })?.isCompleted == true, "manual completion was removed with the delivery source")
        snapshot = try service.togglePeriod(PeriodCompletionToggleRequest(
            dayID: day.id,
            periodID: morning.id,
            taskID: morningTask.id,
            isCompleted: false,
            metadata: WriteMetadata(baseRevision: snapshot.revision, idempotencyKey: "source-manual-off")
        ))
        try require(snapshot.home.periods.first(where: { $0.id == "morning" })?.isCompleted == false, "explicit period cancellation did not clear all sources")

        snapshot = try service.toggleDelivery(DeliveryToggleRequest(
            text: chapterMismatch,
            isCompleted: true,
            metadata: WriteMetadata(baseRevision: snapshot.revision, idempotencyKey: "source-chapter-mismatch")
        ))
        snapshot = try service.toggleDelivery(DeliveryToggleRequest(
            text: noDate,
            isCompleted: true,
            metadata: WriteMetadata(baseRevision: snapshot.revision, idempotencyKey: "source-no-date")
        ))
        completion = try managedCompletionBody(String(contentsOf: root.appendingPathComponent("工作台/下周计划.md"), encoding: .utf8))
        try require(!completion.contains(DeliveryPeriodMatcher.sourceKey(for: chapterMismatch)), "chapter mismatch linked an unrelated period")
        try require(!completion.contains(DeliveryPeriodMatcher.sourceKey(for: noDate)), "undated delivery linked a period")

        snapshot = try service.toggleDelivery(DeliveryToggleRequest(
            text: matchingA,
            isCompleted: true,
            metadata: WriteMetadata(baseRevision: snapshot.revision, idempotencyKey: "source-a-reenable")
        ))
        let renamedText = "\(label)：完成第 3 章网课并跟学例题，整理一页总结"
        let renamedDeliveries = snapshot.week.deliveries.map { delivery in
            delivery.text == matchingA
                ? DeliverySnapshot(id: delivery.id, text: renamedText, isCompleted: delivery.isCompleted, dateLabel: delivery.dateLabel)
                : delivery
        }
        let renamedPlan = WeeklyPlanSnapshot(
            days: snapshot.week.days,
            bufferRules: snapshot.week.bufferRules,
            deliveries: renamedDeliveries,
            historicalRows: snapshot.week.historicalRows,
            futureRows: snapshot.week.futureRows
        )
        _ = try service.applyWeek(PlanWriteRequest(
            plan: renamedPlan,
            metadata: WriteMetadata(baseRevision: snapshot.revision, idempotencyKey: "source-rename")
        ))
        completion = try managedCompletionBody(String(contentsOf: root.appendingPathComponent("工作台/下周计划.md"), encoding: .utf8))
        try require(!completion.contains(sourceA), "renamed delivery left an orphaned source key")
        try require(completion.contains(DeliveryPeriodMatcher.sourceKey(for: renamedText)), "renamed delivery source key was not migrated")
    }

    private static func testHistoricalAndFutureCompletionRecordsSurviveSave() throws {
        let calendar = Calendar(identifier: .gregorian)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        let future = calendar.date(byAdding: .day, value: 8, to: Date())!
        let yesterdayID = isoDate(yesterday)
        let futureID = isoDate(future)
        let yesterdayText = "历史时段任务"
        let futureText = "未来时段任务"
        let source = """
        # 临时计划

        <!-- studyrocket:weekly:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        |------|------|------|------|----------|------|
        | \(shortDateLabel(Date())) | 当前任务 |  |  |  | [ ] |
        <!-- studyrocket:weekly:history:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        |------|------|------|------|----------|------|
        | \(shortDateLabel(yesterday)) | \(yesterdayText) |  |  |  | [ ] |
        <!-- studyrocket:weekly:history:end -->
        <!-- studyrocket:weekly:future:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        |------|------|------|------|----------|------|
        | \(shortDateLabel(future)) | \(futureText) |  |  |  | [ ] |
        <!-- studyrocket:weekly:future:end -->
        <!-- studyrocket:weekly:end -->
        <!-- studyrocket:period-completion:start -->
        | 日期 | 时段 | 正文 SHA-256 | 完成 |
        |------|------|-------------|------|
        | \(yesterdayID) | morning | \(PeriodCompletion.textHash(for: yesterdayText)) | [x] |
        | \(futureID) | morning | \(PeriodCompletion.textHash(for: futureText)) | [x] |
        <!-- studyrocket:period-completion:end -->

        ## 交付物清单
        - [ ] 原交付物

        ## 缓冲
        - 原缓冲
        """
        let root = try makeWorkspace(source: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = HostSnapshotBuilder(root: root).build()
        try require(snapshot.week.historicalRows.contains(where: { $0.dateLabel == shortDateLabel(yesterday) }), "historical fixture row was not parsed")
        try require(snapshot.week.futureRows.contains(where: { $0.dateLabel == shortDateLabel(future) }), "future fixture row was not parsed")
        _ = try HostWriteService(root: root).applyWeek(PlanWriteRequest(
            plan: snapshot.week,
            metadata: WriteMetadata(baseRevision: snapshot.revision, idempotencyKey: "history-future-save")
        ))
        let completion = try managedCompletionBody(String(contentsOf: root.appendingPathComponent("工作台/下周计划.md"), encoding: .utf8))
        try require(completion.contains("| \(yesterdayID) | morning | \(PeriodCompletion.textHash(for: yesterdayText)) | [x] |"), "historical completion was pruned on save")
        try require(completion.contains("| \(futureID) | morning | \(PeriodCompletion.textHash(for: futureText)) | [x] |"), "future completion was pruned on save")
    }

    private static func testCurrentWindowRowsPromoteAcrossSections() throws {
        let now = checkDate("2026-09-13")
        let yesterday = checkDate("2026-09-12")
        let tomorrow = checkDate("2026-09-14")
        let farFuture = checkDate("2026-09-20")
        let promotedMorning = "未来区覆盖上午"
        let promotedNoon = "未来区今日中午任务"
        let tomorrowMorning = "未来区明日任务"
        let source = """
        # 临时计划

        <!-- studyrocket:weekly:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        |------|------|------|------|----------|------|
        | \(shortDateLabel(now)) | 主表旧上午 | 主表旧中午 |  |  | [ ] |
        <!-- studyrocket:weekly:history:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        |------|------|------|------|----------|------|
        | \(shortDateLabel(yesterday)) | 历史任务 |  |  |  | [ ] |
        <!-- studyrocket:weekly:history:end -->
        <!-- studyrocket:weekly:future:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        |------|------|------|------|----------|------|
        | \(shortDateLabel(now)) | \(promotedMorning) | \(promotedNoon) |  | 今日待分配 | [ ] |
        | \(shortDateLabel(tomorrow)) | \(tomorrowMorning) |  |  |  | [ ] |
        | \(shortDateLabel(farFuture)) | 真正远期任务 |  |  |  | [ ] |
        <!-- studyrocket:weekly:future:end -->
        <!-- studyrocket:weekly:end -->
        <!-- studyrocket:period-completion:start -->
        | 日期 | 时段 | 正文 SHA-256 | 完成 |
        |------|------|-------------|------|
        | \(isoDate(now)) | morning | \(PeriodCompletion.textHash(for: promotedMorning)) | [x] |
        <!-- studyrocket:period-completion:end -->

        ## 交付物清单
        - [ ] 学习交付物

        ## 缓冲
        - 原缓冲
        """
        let root = try makeWorkspace(source: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let planFile = root.appendingPathComponent("工作台/下周计划.md")
        let original = try Data(contentsOf: planFile)
        let builder = HostSnapshotBuilder(root: root)

        let snapshot = builder.build(now: now)
        let todayID = isoDate(now)
        let tomorrowID = isoDate(tomorrow)
        let today = try requireDay(snapshot.week.days, id: todayID)
        try require(today.slots.first(where: { $0.id == "morning" })?.text == promotedMorning, "future current-day row did not override the main table row")
        try require(today.slots.first(where: { $0.id == "morning" })?.isCompleted == true, "promoted row lost its period completion")
        try require(today.slots.first(where: { $0.id == "noon" })?.text == promotedNoon, "promoted current-day noon task was missing")
        try require(today.unassigned == "今日待分配", "promoted row lost unassigned text")
        try require(snapshot.home.periods == today.slots, "home periods did not use the canonical current-day row")
        try require(snapshot.home.firstOpenTask == promotedNoon, "home first task did not use the canonical current-day row")
        try require(snapshot.week.days.contains(where: { $0.id == tomorrowID && $0.slots.first(where: { $0.id == "morning" })?.text == tomorrowMorning }), "future next-day row was not promoted into the rolling window")
        try require(!snapshot.week.futureRows.contains(where: { $0.dateLabel == shortDateLabel(now) || $0.dateLabel == shortDateLabel(tomorrow) }), "promoted rows remained duplicated in future rows")
        try require(snapshot.week.historicalRows.contains(where: { $0.dateLabel == shortDateLabel(yesterday) }), "historical row was not retained")
        try require(snapshot.week.futureRows.contains(where: { $0.dateLabel == shortDateLabel(farFuture) }), "true future row was not retained")
        try require(snapshot.home.visibleDeliveries == snapshot.week.deliveries, "home deliveries diverged from the weekly snapshot")
        try require(snapshot.home.completedDeliveries == snapshot.week.deliveries.filter(\.isCompleted).count, "home delivery count diverged from the weekly snapshot")
        try require(snapshot.home.totalDeliveries == snapshot.week.deliveries.count, "home delivery total diverged from the weekly snapshot")
        try require(snapshot.week.deliveries.count == 1 && snapshot.week.deliveries.first?.text == "学习交付物", "schedule rows were incorrectly exposed as study deliveries")

        let nextSnapshot = builder.build(now: tomorrow)
        let nextDay = try requireDay(nextSnapshot.week.days, id: tomorrowID)
        try require(nextDay.slots.first(where: { $0.id == "morning" })?.text == tomorrowMorning, "rolling window did not advance to the next promoted day")
        try require(nextSnapshot.week.historicalRows.contains(where: { $0.slots.first(where: { $0.id == "morning" })?.text == promotedMorning }), "prior current-day row was not archived after the window advanced")
        try require(try Data(contentsOf: planFile) == original, "snapshot parsing rewrote the plan Markdown")
    }

    private static func testMalformedMarkersAndMarkerInjectionAreRejected() throws {
        let malformedBodies = [
            "<!-- studyrocket:deliveries:start -->\n- [ ] 原交付物",
            "<!-- studyrocket:deliveries:start -->\n<!-- studyrocket:deliveries:start -->\n- [ ] 原交付物\n<!-- studyrocket:deliveries:end -->",
            "<!-- studyrocket:deliveries:end -->\n- [ ] 原交付物\n<!-- studyrocket:deliveries:start -->"
        ]
        for (index, body) in malformedBodies.enumerated() {
            let root = try makeWorkspace(source: validSource(deliveryBody: body))
            defer { try? FileManager.default.removeItem(at: root) }
            let planFile = root.appendingPathComponent("工作台/下周计划.md")
            let original = try Data(contentsOf: planFile)
            let snapshot = HostSnapshotBuilder(root: root).build()
            let request = PlanWriteRequest(
                plan: snapshot.week,
                metadata: WriteMetadata(baseRevision: snapshot.revision, idempotencyKey: "malformed-marker-\(index)")
            )
            try requireHostError("managed_block_invalid") { _ = try HostWriteService(root: root).applyWeek(request) }
            try require(try Data(contentsOf: planFile) == original, "malformed managed markers caused a partial write")
        }

        let root = try makeWorkspace(source: validSource())
        defer { try? FileManager.default.removeItem(at: root) }
        let planFile = root.appendingPathComponent("工作台/下周计划.md")
        let original = try Data(contentsOf: planFile)
        let snapshot = HostSnapshotBuilder(root: root).build()
        let injected = DeliverySnapshot(id: "injected", text: "正文\n<!-- studyrocket:weekly:end -->", isCompleted: false)
        let plan = WeeklyPlanSnapshot(
            days: snapshot.week.days,
            bufferRules: snapshot.week.bufferRules,
            deliveries: [injected],
            historicalRows: snapshot.week.historicalRows,
            futureRows: snapshot.week.futureRows
        )
        try requireHostError("reserved_marker") {
            _ = try HostWriteService(root: root).applyWeek(PlanWriteRequest(
                plan: plan,
                metadata: WriteMetadata(baseRevision: snapshot.revision, idempotencyKey: "marker-injection")
            ))
        }
        try require(try Data(contentsOf: planFile) == original, "reserved marker injection caused a partial write")
    }

    private static func testIndependentPeriodTasksAndLegacyCompatibility() throws {
        let label = shortDateLabel(Date())
        let source = """
        # 临时计划

        <!-- studyrocket:weekly:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        |------|------|------|------|----------|------|
        | \(label) |  |  | 20:00 邮件系统英方培训<br>问李训灏：专业考勤系统选用问题 |  | [ ] |
        <!-- studyrocket:weekly:end -->

        ## 交付物清单
        - [ ] \(label)：邮件系统英方培训

        ## 缓冲
        - 原缓冲
        """
        let root = try makeWorkspace(source: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = HostSnapshotBuilder(root: root)
        let service = HostWriteService(root: root)
        var snapshot = builder.build()
        guard let day = snapshot.week.days.first,
              let evening = day.slots.first(where: { $0.id == "evening" }),
              evening.tasks.count == 2 else {
            throw NSError(domain: "HostWriteServiceChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "multi-task evening was not parsed"])
        }
        let first = evening.tasks[0]
        let second = evening.tasks[1]

        try requireHostError("period_upgrade_required") {
            _ = try service.togglePeriod(PeriodCompletionToggleRequest(
                dayID: day.id,
                periodID: evening.id,
                textHash: PeriodCompletion.textHash(for: evening.text),
                isCompleted: true,
                metadata: WriteMetadata(baseRevision: snapshot.revision, idempotencyKey: "legacy-multi-rejected")
            ))
        }

        snapshot = try service.togglePeriod(PeriodCompletionToggleRequest(
            dayID: day.id,
            periodID: evening.id,
            taskID: first.id,
            isCompleted: true,
            metadata: WriteMetadata(baseRevision: snapshot.revision, idempotencyKey: "task-one-on")
        ))
        let independentlyUpdated = try requireDay(snapshot.week.days, id: day.id)
            .slots.first(where: { $0.id == "evening" })!
        try require(independentlyUpdated.tasks.first(where: { $0.id == first.id })?.isCompleted == true, "first child task was not completed")
        try require(independentlyUpdated.tasks.first(where: { $0.id == second.id })?.isCompleted == false, "second child task was completed by the first task toggle")
        try require(independentlyUpdated.isCompleted == false, "period was marked complete before all child tasks finished")

        snapshot = try service.toggleDelivery(DeliveryToggleRequest(
            text: "\(label)：邮件系统英方培训",
            isCompleted: true,
            metadata: WriteMetadata(baseRevision: snapshot.revision, idempotencyKey: "delivery-first-child")
        ))
        let linked = try requireDay(snapshot.week.days, id: day.id).slots.first(where: { $0.id == "evening" })!
        try require(linked.tasks.first(where: { $0.id == first.id })?.isCompleted == true, "delivery did not retain the matching child completion")
        try require(linked.tasks.first(where: { $0.id == second.id })?.isCompleted == false, "delivery completion affected an unrelated child task")

        let legacyRoot = try makeWorkspace(source: source)
        defer { try? FileManager.default.removeItem(at: legacyRoot) }
        let legacyBuilder = HostSnapshotBuilder(root: legacyRoot)
        let legacyInitial = legacyBuilder.build()
        guard let legacyDay = legacyInitial.week.days.first,
              let legacyEvening = legacyDay.slots.first(where: { $0.id == "evening" }),
              legacyEvening.tasks.count == 2 else { fatalError("missing legacy multi-task evening") }
        let legacyHash = PeriodCompletion.textHash(for: legacyEvening.text)
        let legacyPlanFile = legacyRoot.appendingPathComponent("工作台/下周计划.md")
        let legacySource = try String(contentsOf: legacyPlanFile, encoding: .utf8)
            .replacingOccurrences(
                of: "<!-- studyrocket:weekly:end -->",
                with: "<!-- studyrocket:weekly:end -->\n<!-- studyrocket:period-completion:start -->\n| 日期 | 时段 | 任务标识 | 完成 | 来源 |\n|------|------|----------|------|------|\n| \(legacyDay.id) | evening | \(legacyHash) | [x] |  |\n<!-- studyrocket:period-completion:end -->"
            )
        try Data(legacySource.utf8).write(to: legacyPlanFile, options: .atomic)
        let legacySnapshot = legacyBuilder.build()
        let legacyVisible = try requireDay(legacySnapshot.week.days, id: legacyDay.id).slots.first(where: { $0.id == "evening" })!
        try require(legacyVisible.tasks.allSatisfy(\.isCompleted), "legacy whole-period completion did not complete every child")
        let migrated = try HostWriteService(root: legacyRoot).togglePeriod(PeriodCompletionToggleRequest(
            dayID: legacyDay.id,
            periodID: legacyEvening.id,
            taskID: legacyEvening.tasks[0].id,
            isCompleted: false,
            metadata: WriteMetadata(baseRevision: legacySnapshot.revision, idempotencyKey: "legacy-expand-first-off")
        ))
        let migratedEvening = try requireDay(migrated.week.days, id: legacyDay.id).slots.first(where: { $0.id == "evening" })!
        try require(migratedEvening.tasks[0].isCompleted == false && migratedEvening.tasks[1].isCompleted == true, "task toggle did not expand the legacy completion into independent records")
    }

    private static func testTimedUnassignedTasksBecomeCompletablePeriods() throws {
        let label = shortDateLabel(Date())
        let source = """
        # 临时计划

        <!-- studyrocket:weekly:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        |------|------|------|------|----------|------|
        | \(label) | 08:30 见面会 | 12:00 大扫除 |  | 14:00 领取 Bar Code<br>16:00 领取银行卡<br>等待确认地点 | [ ] |
        <!-- studyrocket:weekly:end -->

        ## 交付物清单
        - [ ] 原交付物

        ## 缓冲
        - 原缓冲
        """
        let root = try makeWorkspace(source: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = HostSnapshotBuilder(root: root)
        let service = HostWriteService(root: root)
        let initial = builder.build()
        guard let currentDay = initial.week.days.first,
              let currentNoon = currentDay.slots.first(where: { $0.id == "noon" }) else {
            fatalError("missing normalized current day")
        }
        try require(
            currentNoon.tasks.map(\.text) == ["12:00 大扫除", "14:00 领取 Bar Code", "16:00 领取银行卡"],
            "snapshot did not promote timed unassigned tasks into noon"
        )
        try require(currentDay.unassigned == "等待确认地点", "snapshot removed unresolved unassigned text")

        let rawDay = DaySnapshot(
            id: currentDay.id,
            dateLabel: currentDay.dateLabel,
            slots: [
                PeriodSnapshot(id: "morning", title: "上午", text: "08:30 见面会"),
                PeriodSnapshot(id: "noon", title: "中午", text: "12:00 大扫除"),
                PeriodSnapshot(id: "evening", title: "晚上", text: "")
            ],
            unassigned: "- [ ] 14:00 领取 Bar Code\n- [ ] 16:00 领取银行卡\n等待确认地点"
        )
        let writtenSnapshot = try service.applyWeek(PlanWriteRequest(
            plan: WeeklyPlanSnapshot(
                days: [rawDay] + initial.week.days.dropFirst(),
                bufferRules: initial.week.bufferRules,
                deliveries: initial.week.deliveries,
                historicalRows: initial.week.historicalRows,
                futureRows: initial.week.futureRows
            ),
            metadata: WriteMetadata(baseRevision: initial.revision, idempotencyKey: "timed-unassigned-normalization")
        ))
        let written = try String(contentsOf: root.appendingPathComponent("工作台/下周计划.md"), encoding: .utf8)
        try require(written.contains("12:00 大扫除<br>14:00 领取 Bar Code<br>16:00 领取银行卡"), "write path did not persist promoted tasks")
        try require(written.contains("| 等待确认地点 | [ ] |"), "write path lost unresolved text")
        try require(!written.contains("- [ ] 14:00"), "write path retained an in-cell Markdown checkbox")

        guard let writtenDay = writtenSnapshot.week.days.first,
              let writtenNoon = writtenDay.slots.first(where: { $0.id == "noon" }),
              writtenNoon.tasks.count == 3 else { fatalError("missing written noon tasks") }
        let barcode = writtenNoon.tasks[1]
        let bankCard = writtenNoon.tasks[2]
        let toggled = try service.togglePeriod(PeriodCompletionToggleRequest(
            dayID: writtenDay.id,
            periodID: writtenNoon.id,
            taskID: barcode.id,
            isCompleted: true,
            metadata: WriteMetadata(baseRevision: writtenSnapshot.revision, idempotencyKey: "promoted-task-toggle")
        ))
        let toggledNoon = try requireDay(toggled.week.days, id: writtenDay.id)
            .slots.first(where: { $0.id == "noon" })!
        try require(toggledNoon.tasks.first(where: { $0.id == barcode.id })?.isCompleted == true, "promoted task could not be completed independently")
        try require(toggledNoon.tasks.first(where: { $0.id == bankCard.id })?.isCompleted == false, "one promoted task toggle changed its sibling")
    }

    private static func testWeeklyProposalIsNormalizedBeforeApproval() throws {
        let source = validSource()
        let root = try makeWorkspace(source: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let label = shortDateLabel(Date())
        let candidate = source.replacingOccurrences(
            of: "| \(label) | 原上午 | 原中午 | 原晚上 |  | [ ] |",
            with: "| \(label) | - [ ] 08:30 见面会 | - [ ] 12:00 大扫除 |  | - [ ] 14:00 领取 Bar Code<br>- [ ] 16:00 领取银行卡 | [ ] |"
        )
        let store = HostProposalStore(root: root)
        let registration = store.register(
            arguments: ["path": "工作台/下周计划.md", "content": candidate, "reason": "测试时段归位"],
            tool: "propose_changes",
            turnID: "proposal-normalization"
        )
        try require(registration["success"] as? Bool == true, "weekly proposal registration failed")
        guard let proposal = store.list().proposals.first else { fatalError("missing normalized proposal") }
        let expectedRow = "| \(label) | 08:30 见面会 | 12:00 大扫除<br>14:00 领取 Bar Code<br>16:00 领取银行卡 |  |  | [ ] |"
        try require(proposal.proposedContent.contains(expectedRow), "proposal diff was not normalized before approval")
        try require(try String(contentsOf: root.appendingPathComponent("工作台/下周计划.md"), encoding: .utf8) == source, "proposal registration changed the real file")

        _ = try store.apply(ProposalApplyRequest(
            proposalIDs: [proposal.id],
            authorization: "test-authorization",
            metadata: WriteMetadata(baseRevision: "temporary", idempotencyKey: "proposal-normalization-apply")
        ))
        let written = try String(contentsOf: root.appendingPathComponent("工作台/下周计划.md"), encoding: .utf8)
        try require(written == proposal.proposedContent, "approved proposal write differed from the displayed diff")
    }

    private static func testSnapshotRejectsExternalSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("studyrocket-host-symlink-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("studyrocket-host-outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("工作台/航线"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsidePlan = outside.appendingPathComponent("plan.md")
        let outsideCourse = outside.appendingPathComponent("course.md")
        try Data(validSource(deliveryBody: "- [ ] 外部秘密").utf8).write(to: outsidePlan)
        try Data("# 不应泄露的课程内容".utf8).write(to: outsideCourse)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("工作台/下周计划.md"), withDestinationURL: outsidePlan)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("工作台/航线/课程.md"), withDestinationURL: outsideCourse)
        let builder = HostSnapshotBuilder(root: root)
        try require(builder.build().week.deliveries.isEmpty, "snapshot followed an external weekly-plan symlink")
        try require(builder.document(documentKey: "course") == nil, "document endpoint followed an external symlink")
    }

    private static func testTimetableSnapshotAndRevision() throws {
        let root = try makeWorkspace(source: validSource())
        defer { try? FileManager.default.removeItem(at: root) }
        let timetableDirectory = root.appendingPathComponent("工作台/学期", isDirectory: true)
        try FileManager.default.createDirectory(at: timetableDirectory, withIntermediateDirectories: true)
        let timetableFile = timetableDirectory.appendingPathComponent("2026秋季个人课表.md")
        let source = """
        # 261 一班课表

        <!-- studyrocket:timetable:start -->
        | 字段 | 内容 |
        | --- | --- |
        | 班级 | 261 一班 |
        | 学期 | 2026-2027 秋季学期 |
        | 起始日期 | 2026-09-14 |
        | 结束日期 | 2027-01-03 |
        | 日期 | 周次 | 类型 | 开始 | 结束 | 节次 | 名称 | 地点 | 教师 | 备注 |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        | 2026-12-28 | 16 | 课程 | 08:00 | 09:30 | 1-2 | 课表课程 A | 2-101 | 老师 A |  |
        <!-- studyrocket:timetable:end -->
        """
        try Data(source.utf8).write(to: timetableFile)

        let reference = checkDate("2026-12-28")
        let builder = HostSnapshotBuilder(root: root)
        try require(HostSnapshotBuilder.documentMap["timetable"]?.title == "课表", "timetable document title is not allowlisted")
        try require(HostSnapshotBuilder.documentMap["timetable"]?.path == StudyRocketTimetableParser.sourceFile, "timetable document path does not use the shared source file")
        let first = builder.build(now: reference)
        guard let firstTimetable = first.home.timetable else { throw NSError(domain: "HostWriteServiceChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "timetable was not attached to HomeSnapshot"]) }
        try require(firstTimetable.status == .available && firstTimetable.teachingWeek == 16, "Host did not parse the current timetable week")
        try require(firstTimetable == StudyRocketTimetableParser.snapshot(from: source, now: reference), "Host and Shared produced different timetable snapshots")
        guard let timetableDocument = builder.document(documentKey: "timetable") else { throw NSError(domain: "HostWriteServiceChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "timetable document was not readable through the Host allowlist"]) }
        try require(timetableDocument.title == "课表" && timetableDocument.markdown == source.trimmingCharacters(in: .whitespacesAndNewlines), "timetable document mapping returned the wrong content")

        let changedSource = source.replacingOccurrences(of: "课表课程 A", with: "课表课程 B")
        try Data(changedSource.utf8).write(to: timetableFile, options: .atomic)
        let second = builder.build(now: reference)
        try require(first.revision != second.revision, "timetable edits did not change the Host revision")
        try require(second.home.timetable?.days.first?.entries.first?.title == "课表课程 B", "timetable edit was not reflected in the snapshot")

        try FileManager.default.removeItem(at: timetableFile)
        let missing = builder.build(now: reference)
        try require(missing.home.timetable?.status == .notImported, "missing timetable was not distinguished from an invalid source")
    }

    private static func makeWorkspace(source: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("studyrocket-host-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("工作台"), withIntermediateDirectories: true)
        try Data(source.utf8).write(to: root.appendingPathComponent("工作台/下周计划.md"))
        return root
    }

    private static func validSource(deliveryBody: String = "- [ ] 原交付物") -> String {
        """
        # 临时计划

        <!-- studyrocket:weekly:start -->
        | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
        |------|------|------|------|----------|------|
        | \(shortDateLabel(Date())) | 原上午 | 原中午 | 原晚上 |  | [ ] |
        <!-- studyrocket:weekly:end -->

        ## 交付物清单
        \(deliveryBody)

        ## 缓冲
        - 原缓冲
        """
    }

    private static func requireHostError(_ code: String, operation: () throws -> Void) throws {
        do {
            try operation()
        } catch let error as HostWriteError {
            try require(error.code == code, "expected HostWriteError \(code), got \(error.code)")
            return
        }
        throw NSError(domain: "HostWriteServiceChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "expected HostWriteError \(code)"])
    }

    private static func shortDateLabel(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
    }

    private static func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func checkDate(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value)!
    }

    private static func managedCompletionBody(_ source: String) throws -> String {
        guard let start = source.range(of: "<!-- studyrocket:period-completion:start -->"),
              let end = source.range(of: "<!-- studyrocket:period-completion:end -->", range: start.upperBound..<source.endIndex) else {
            throw NSError(domain: "HostWriteServiceChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "period completion block missing"])
        }
        return String(source[start.upperBound..<end.lowerBound])
    }

    private static func requireDay(_ days: [DaySnapshot], id: String) throws -> DaySnapshot {
        guard let day = days.first(where: { $0.id == id }) else {
            throw NSError(domain: "HostWriteServiceChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing day \(id)"])
        }
        return day
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "HostWriteServiceChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}

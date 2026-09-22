import Foundation
import CryptoKit
import StudyRocketShared

let privateKey = P256.Signing.PrivateKey()
let timestamp = Int64(Date().timeIntervalSince1970)
let body = Data("studyrocket-check".utf8)
let bodyHash = RequestSigning.bodyHash(body)
let signature = try RequestSigning.sign(privateKey: privateKey, method: "POST", path: "/v1/check", timestamp: timestamp, nonce: "test-nonce", bodyHash: bodyHash)
precondition(RequestSigning.verify(publicKeyData: privateKey.publicKey.rawRepresentation, signatureBase64: signature, method: "POST", path: "/v1/check", timestamp: timestamp, nonce: "test-nonce", bodyHash: bodyHash))
let challenge = UUID().uuidString
let authorizationSignature = try RequestSigning.signAuthorization(privateKey: privateKey, challenge: challenge)
precondition(RequestSigning.verifyAuthorization(publicKeyData: privateKey.publicKey.rawRepresentation, signatureBase64: authorizationSignature, challenge: challenge))
precondition(!RequestSigning.verifyAuthorization(publicKeyData: privateKey.publicKey.rawRepresentation, signatureBase64: authorizationSignature, challenge: UUID().uuidString))
precondition(StudyRocketSelfCheckConfiguration.isolatedPort(from: ["--studyrocket-self-check"]) == 43818)
precondition(StudyRocketSelfCheckConfiguration.isolatedPort(from: ["--studyrocket-self-check", "--self-check-port", "44000"]) == 44000)
precondition(StudyRocketSelfCheckConfiguration.isolatedPort(from: ["--studyrocket-self-check", "--self-check-port", "43817"]) == nil)
precondition(StudyRocketSelfCheckConfiguration.isolatedPort(from: ["--studyrocket-self-check", "--self-check-port", "1023"]) == nil)
precondition(StudyRocketSelfCheckConfiguration.isolatedPort(from: ["--studyrocket-self-check", "--self-check-port", "43818", "--self-check-port", "44000"]) == nil)

let request = SendChatRequest(text: "测试")
let encoded = try JSONEncoder().encode(request)
let decoded = try JSONDecoder().decode(SendChatRequest.self, from: encoded)
precondition(decoded.text == request.text && decoded.apiVersion == StudyRocketAPI.version)
precondition(WriteMetadata(baseRevision: "r").apiVersion == StudyRocketAPI.version)
let pairRequest = PairRequest(code: "123456", deviceName: "test", publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString())
let decodedPairRequest = try JSONDecoder().decode(PairRequest.self, from: JSONEncoder().encode(pairRequest))
precondition(decodedPairRequest.apiVersion == StudyRocketAPI.version)
let interruptRequest = InterruptRequest(turnID: "turn")
let decodedInterruptRequest = try JSONDecoder().decode(InterruptRequest.self, from: JSONEncoder().encode(interruptRequest))
precondition(decodedInterruptRequest.apiVersion == StudyRocketAPI.version)
let legacyPlan = try JSONDecoder().decode(WeeklyPlanSnapshot.self, from: Data(#"{"days":[],"bufferRules":[],"deliveries":[]}"#.utf8))
precondition(legacyPlan.historicalRows.isEmpty && legacyPlan.futureRows.isEmpty)

func checkDate(_ value: String) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    return formatter.date(from: value)!
}

let timetableSource = """
# 课表检查

<!-- studyrocket:timetable:start -->
| 字段 | 内容 |
| --- | --- |
| 班级 | 261 一班 |
| 学期 | 2026-2027 秋季学期 |
| 起始日期 | 2026-09-14 |
| 结束日期 | 2027-01-03 |

| 日期 | 周次 | 类型 | 开始 | 结束 | 节次 | 名称 | 地点 | 教师 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-12-28 | 16 | break | 10:00 | 10:10 | 3 | 课间休息 |  |  |  |
| 2026-12-29 | 16 | break |  |  |  |  |  |  |  |
| 2026-12-28 | 16 | 答疑 | 08:30 | 09:30 | 1 | 学术答疑 | 2-105 |  |  |
| 2026-12-28 | 16 | 课程 | 15:50 | 18:10 | 8-10 | 高等数学（上） | 2-310 | 孙媛媛 | 合并节次 |
| 2027-01-01 | 16 | 活动 | 13:00 | 14:00 | 6 | 学院活动 | 学术报告厅 |  |  |
| 2027-01-01 | 16 | 假期 |  |  |  | 元旦假期 |  |  |  |
| 2027-01-02 | 16 | officeHour | 10:00 | 11:00 | 3 | 教师办公时间 | 2-201 |  |  |
<!-- studyrocket:timetable:end -->
"""

let availableTimetable = StudyRocketTimetableParser.snapshot(from: timetableSource, now: checkDate("2027-01-01"))
precondition(availableTimetable.status == .available)
precondition(availableTimetable.classLabel == "261 一班")
precondition(availableTimetable.teachingWeek == 16)
precondition(availableTimetable.weekStartDate == "2026-12-28")
let crossYearDay = availableTimetable.days.first { $0.id == "2027-01-01" }
precondition(crossYearDay?.weekdayLabel == "周五")
precondition(crossYearDay?.entries.map(\.kind) == [.event, .holiday])
let boundaryDay = availableTimetable.days.first { $0.id == "2026-12-28" }
precondition(boundaryDay?.entries.count == 2)
precondition(boundaryDay?.entries.first?.kind == .support)
precondition(boundaryDay?.entries.last?.startTime == "15:50")
precondition(boundaryDay?.entries.last?.endTime == "18:10")
precondition(boundaryDay?.entries.last?.periodLabel == "8-10")
precondition(boundaryDay?.entries.last?.instructor == "孙媛媛")
precondition(availableTimetable.days.first { $0.id == "2027-01-02" }?.entries.first?.kind == .officeHour)
precondition(StudyRocketTimetableParser.snapshot(from: timetableSource, now: checkDate("2026-09-13")).status == .beforeTerm)
let finalWeek = StudyRocketTimetableParser.snapshot(from: timetableSource, now: checkDate("2027-01-03"))
precondition(finalWeek.status == .available && finalWeek.teachingWeek == 16)
precondition(StudyRocketTimetableParser.snapshot(from: timetableSource, now: checkDate("2027-01-04")).status == .afterTerm)
precondition(StudyRocketTimetableParser.snapshot(from: nil, now: checkDate("2027-01-01")).status == .notImported)
precondition(StudyRocketTimetableParser.snapshot(from: "", now: checkDate("2027-01-01")).status == .invalid)
precondition(StudyRocketTimetableParser.snapshot(from: "<!-- studyrocket:timetable:start -->", now: checkDate("2027-01-01")).status == .invalid)
let duplicateHeader = timetableSource.replacingOccurrences(
    of: "| 日期 | 周次 | 类型 | 开始 | 结束 | 节次 | 名称 | 地点 | 教师 | 备注 |",
    with: "| 日期 | 日期 | 类型 | 开始 | 结束 | 节次 | 名称 | 地点 | 教师 | 备注 |"
)
precondition(StudyRocketTimetableParser.snapshot(from: duplicateHeader, now: checkDate("2027-01-01")).status == .invalid)

let bilingualTimetableSource = """
<!-- studyrocket:timetable:start -->
| 字段 | 内容 |
| --- | --- |
| 班级 | 261 一班 |
| 学期 | 2026-2027 秋季学期 |
| 起始日期 | 2026-09-14 |
| 结束日期 | 2026-09-20 |

| 日期 | 周次 | 类型 | 开始 | 结束 | 节次 | 名称 | 地点 | 教师 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-09-14 | 1 | 答疑 | 08:00 | 09:00 | 1 | Academic and Skills Support -1A |  |  |  |
| 2026-09-14 | 1 | 答疑 | 09:15 | 10:15 | 3 | Academic skills BOTH JEIs |  |  |  |
| 2026-09-14 | 1 | 答疑 | 10:30 | 11:30 | 4 | Academic skills (Practicing skills) |  |  |  |
| 2026-09-15 | 1 | 答疑 | 08:00 | 09:00 | 1 | Learning Under the Pavillion (Both JEIs) |  |  |  |
| 2026-09-15 | 1 | officeHour | 09:15 | 10:15 | 3 | Office Hour |  |  |  |
| 2026-09-15 | 1 | 课程 | 10:30 | 11:30 | 4 | Medical Cell Biology / 基础医学遗传学和细胞生物学 |  |  |  |
| 2026-09-16 | 1 | 假期 |  |  |  | Mid-Autumn Festival |  |  |  |
<!-- studyrocket:timetable:end -->
"""
let bilingualEntries = try StudyRocketTimetableParser.document(from: bilingualTimetableSource).entries.map(\.entry)
precondition(bilingualEntries.first { $0.startTime == "08:00" }?.kind == .course)
precondition(bilingualEntries.first { $0.startTime == "08:00" }?.title == "Academic and Skills Support - 1A / 学术与技能支持（1A）")
precondition(bilingualEntries.first { $0.startTime == "09:15" }?.title == "Academic Skills (Both JEIs) / 学术技能（JEI 合班）")
precondition(bilingualEntries.first { $0.startTime == "10:30" }?.title == "Academic Skills (Practising Skills) / 学术技能（技能练习）")
precondition(bilingualEntries.first { $0.title.hasPrefix("Learning Under") }?.title == "Learning Under the Pavilion (Both JEIs) / 亭下学习（JEI 合班）")
precondition(bilingualEntries.first { $0.title.hasPrefix("Office Hour") }?.kind == .course)
precondition(bilingualEntries.first { $0.title.hasPrefix("Medical Cell Biology") }?.title == "Medical Cell Biology / 医学细胞生物学")
precondition(bilingualEntries.first { $0.title == "Mid-Autumn Festival" }?.kind == .holiday)
precondition(!(boundaryDay?.entries.contains { $0.title == "课间休息" } ?? false))

let catalogExpectations: [(TimetableEntryKind, String, String)] = [
    (.support, "Academic and Skills Support -1B", "Academic and Skills Support - 1B / 学术与技能支持（1B）"),
    (.support, "Academic skills", "Academic Skills / 学术技能"),
    (.support, "Learning Under the Pavillion", "Learning Under the Pavilion / 亭下学习"),
    (.course, "Basic Medical Genetics and Cell Biology", "Basic Medical Genetics and Cell Biology / 基础医学遗传学和细胞生物学"),
    (.course, "Practice for Basic Medical Genetics and Cell Biology", "Practice for Basic Medical Genetics and Cell Biology / 基础医学遗传学和细胞生物学实验"),
    (.course, "Medical Cell Biology / 基础医学遗传学和细胞生物学", "Medical Cell Biology / 医学细胞生物学")
]
for (kind, rawTitle, canonicalTitle) in catalogExpectations {
    let presentation = StudyRocketTimetableCourseCatalog.presentation(kind: kind, title: rawTitle)
    precondition(presentation.kind == .course)
    precondition(presentation.title == canonicalTitle)
}
for holiday in ["Mid-Autumn Festival", "National Day", "New Year's Day"] {
    let presentation = StudyRocketTimetableCourseCatalog.presentation(kind: .holiday, title: holiday)
    precondition(presentation.kind == .holiday)
    precondition(presentation.title == holiday)
}
let bilingualDisplayTitle = StudyRocketTimetableCourseCatalog.displayTitle(
    for: "Academic and Skills Support - 1A / 学术与技能支持（1A）"
)
precondition(bilingualDisplayTitle.primary == "Academic and Skills Support - 1A")
precondition(bilingualDisplayTitle.secondary == "学术与技能支持（1A）")
let ChineseDisplayTitle = StudyRocketTimetableCourseCatalog.displayTitle(for: "高等数学（上）")
precondition(ChineseDisplayTitle.primary == "高等数学（上）" && ChineseDisplayTitle.secondary == nil)
let holidayDisplayTitle = StudyRocketTimetableCourseCatalog.displayTitle(for: "Mid-Autumn Festival")
precondition(holidayDisplayTitle.primary == "Mid-Autumn Festival" && holidayDisplayTitle.secondary == nil)

let legacySupportRecord = TimetableRecord(
    date: "2026-09-15",
    teachingWeek: 1,
    entry: TimetableEntrySnapshot(
        id: "legacy-support",
        kind: .support,
        title: "Academic and Skills Support -1B",
        startTime: "09:15",
        endTime: "10:15",
        periodLabel: "3"
    )
)
let canonicalCourseRecord = TimetableRecord(
    date: "2026-09-15",
    teachingWeek: 1,
    entry: TimetableEntrySnapshot(
        id: "imported-course",
        kind: .course,
        title: "Academic and Skills Support - 1B / 学术与技能支持（1B）",
        startTime: "09:15",
        endTime: "10:15",
        periodLabel: "3",
        location: "2-105"
    )
)
let mergedTimetable = StudyRocketTimetableDocumentMerge.merge(
    existing: TimetableDocument(
        classLabel: "261 一班",
        termLabel: "2026-2027 秋季学期",
        firstImportedDate: "2026-09-14",
        lastImportedDate: "2026-09-20",
        entries: [legacySupportRecord]
    ),
    imported: TimetableDocument(
        classLabel: "261 一班",
        termLabel: "2026-2027 秋季学期",
        firstImportedDate: "2026-09-14",
        lastImportedDate: "2026-09-20",
        entries: [canonicalCourseRecord]
    )
)
precondition(mergedTimetable.addedCount == 0 && mergedTimetable.updatedCount == 1)
precondition(mergedTimetable.document.entries.count == 1)
precondition(mergedTimetable.document.entries[0].entry.id == "legacy-support")
precondition(mergedTimetable.document.entries[0].entry.kind == .course)
precondition(mergedTimetable.document.entries[0].entry.title == "Academic and Skills Support - 1B / 学术与技能支持（1B）")
precondition(mergedTimetable.document.entries[0].entry.location == "2-105")

let legacyHome = try JSONDecoder().decode(HomeSnapshot.self, from: Data(#"{"dateLabel":"1月1日","periods":[],"firstOpenTask":null,"visibleDeliveries":[],"completedDeliveries":0,"totalDeliveries":0}"#.utf8))
precondition(legacyHome.timetable == nil)
let currentHome = HomeSnapshot(
    dateLabel: "1月1日",
    periods: [],
    firstOpenTask: nil,
    visibleDeliveries: [],
    completedDeliveries: 0,
    totalDeliveries: 0,
    timetable: availableTimetable
)
let decodedCurrentHome = try JSONDecoder().decode(HomeSnapshot.self, from: JSONEncoder().encode(currentHome))
precondition(decodedCurrentHome.timetable == availableTimetable)

precondition(DeliveryPeriodMatcher.matches(
    deliveryText: "8 月 17 日：完成第 3 章当天网课进度并跟学例题",
    periodText: "第 3 章：继续网课并跟学例题；晚上去健身房运动"
))
precondition(DeliveryPeriodMatcher.matches(
    deliveryText: "8 月 20 日：开始第 4 章网课并跟学例题",
    periodText: "第 4 章《不定积分》：开始网课并跟学例题"
))
precondition(!DeliveryPeriodMatcher.matches(
    deliveryText: "8 月 20 日：开始第 4 章网课并跟学例题",
    periodText: "第 3 章：继续网课并跟学例题"
))
precondition(!DeliveryPeriodMatcher.matches(
    deliveryText: "整理概率论笔记",
    periodText: "晚上去健身房运动"
))
precondition(
    DeliveryPeriodMatcher.sourceKey(for: " 完成高数网课 \n")
        == DeliveryPeriodMatcher.sourceKey(for: "完成高数网课")
)
let legacyPeriod = try JSONDecoder().decode(PeriodSnapshot.self, from: Data(#"{"id":"morning","title":"上午","text":"复习"}"#.utf8))
precondition(!legacyPeriod.isCompleted)
let completedPeriod = PeriodSnapshot(id: "morning", title: "上午", text: "复习", isCompleted: true)
let decodedCompletedPeriod = try JSONDecoder().decode(PeriodSnapshot.self, from: JSONEncoder().encode(completedPeriod))
precondition(decodedCompletedPeriod.isCompleted)
let splitTasks = PeriodTaskParser.tasks(from: "20:00 邮件系统英方培训\n- 问李训灏：专业考勤系统选用问题")
precondition(splitTasks.map(\.text) == ["20:00 邮件系统英方培训", "问李训灏：专业考勤系统选用问题"])
precondition(splitTasks.map(\.id).count == Set(splitTasks.map(\.id)).count)
let markdownTaskList = PeriodTaskParser.tasks(from: "- [ ] 08:30 中英师生见面会\n- [x] 13:30 领取 Bar Code")
precondition(markdownTaskList.map(\.text) == ["08:30 中英师生见面会", "13:30 领取 Bar Code"])
precondition(
    PeriodTaskParser.displayText(from: "- [ ] 08:30 中英师生见面会<br>- [x] 13:30 领取 Bar Code")
        == "08:30 中英师生见面会\n13:30 领取 Bar Code"
)
let normalizedSchedule = WeeklyPlanTaskNormalizer.normalized(
    periods: [
        PeriodSnapshot(id: "morning", title: "上午", text: "- [ ] 08:30 中英师生见面会"),
        PeriodSnapshot(id: "noon", title: "中午", text: "- [ ] 12:00-13:30 寝室大扫除"),
        PeriodSnapshot(id: "evening", title: "晚上", text: "")
    ],
    unassigned: "- [ ] 14:00 领取 Bar Code<br>- [ ] 下午4点领取银行卡<br>等待确认地点"
)
precondition(normalizedSchedule.periods[0].tasks.map(\.text) == ["08:30 中英师生见面会"])
precondition(normalizedSchedule.periods[1].tasks.map(\.text) == ["12:00-13:30 寝室大扫除"])
precondition(normalizedSchedule.periods[2].tasks.isEmpty)
precondition(normalizedSchedule.unassigned == "14:00 领取 Bar Code\n下午4点领取银行卡\n等待确认地点")
let normalizedProposal = WeeklyPlanTaskNormalizer.normalizedMarkdown(
    """
    # 计划
    <!-- studyrocket:weekly:start -->
    | 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |
    |------|------|------|------|----------|------|
    | 9 月 15 日 | - [ ] 08:30 见面会 | - [ ] 12:00 大扫除 |  | - [ ] 14:00 领取 Bar Code<br>- [ ] 16:00 领取银行卡<br>地点待确认 | [ ] |
    <!-- studyrocket:weekly:end -->
    """
)
precondition(normalizedProposal.contains("| 9 月 15 日 | 08:30 见面会 | 12:00 大扫除 |  | 14:00 领取 Bar Code<br>16:00 领取银行卡<br>地点待确认 | [ ] |"))
precondition(!normalizedProposal.contains("- [ ] 14:00"))
let duplicateTasks = PeriodTaskParser.tasks(from: "复习英语<br>复习英语")
precondition(duplicateTasks.count == 2 && duplicateTasks[0].id != duplicateTasks[1].id)
let partialPeriod = PeriodSnapshot(
    id: "evening",
    title: "晚上",
    text: "20:00 邮件系统英方培训\n问李训灏：专业考勤系统选用问题",
    tasks: [
        PeriodTaskSnapshot(id: splitTasks[0].id, text: splitTasks[0].text, isCompleted: true),
        PeriodTaskSnapshot(id: splitTasks[1].id, text: splitTasks[1].text, isCompleted: false)
    ]
)
precondition(!partialPeriod.isCompleted && partialPeriod.tasks[0].isCompleted && !partialPeriod.tasks[1].isCompleted)
let decodedPartialPeriod = try JSONDecoder().decode(PeriodSnapshot.self, from: JSONEncoder().encode(partialPeriod))
precondition(decodedPartialPeriod == partialPeriod)
precondition(PeriodCompletion.textHash(for: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
let periodToggle = PeriodCompletionToggleRequest(
    dayID: "2026-08-16",
    periodID: "morning",
    textHash: PeriodCompletion.textHash(for: "复习"),
    isCompleted: true,
    metadata: WriteMetadata(baseRevision: "revision", idempotencyKey: "period-toggle")
)
let decodedPeriodToggle = try JSONDecoder().decode(PeriodCompletionToggleRequest.self, from: JSONEncoder().encode(periodToggle))
precondition(decodedPeriodToggle == periodToggle)
let taskToggle = PeriodCompletionToggleRequest(
    dayID: "2026-08-16",
    periodID: "evening",
    taskID: splitTasks[1].id,
    isCompleted: true,
    metadata: WriteMetadata(baseRevision: "revision", idempotencyKey: "task-toggle")
)
let decodedTaskToggle = try JSONDecoder().decode(PeriodCompletionToggleRequest.self, from: JSONEncoder().encode(taskToggle))
precondition(decodedTaskToggle == taskToggle && decodedTaskToggle.textHash == nil)
let scheduled = ScheduledRowSnapshot(id: "old", dateLabel: "8月14日", slots: [PeriodSnapshot(id: "morning", title: "上午", text: "复习")], isCompleted: false)
let planWithHistory = WeeklyPlanSnapshot(days: [], bufferRules: [], deliveries: [], historicalRows: [scheduled], futureRows: [])
let decodedPlan = try JSONDecoder().decode(WeeklyPlanSnapshot.self, from: JSONEncoder().encode(planWithHistory))
precondition(decodedPlan.historicalRows == [scheduled])
let streamEvent = HostEventEnvelope(
    kind: "chat",
    chat: ChatStreamEvent(kind: "item_completed", turnID: "turn", itemID: "item", text: "最终回答", phase: "final_answer")
)
let decodedStreamEvent = try JSONDecoder().decode(HostEventEnvelope.self, from: JSONEncoder().encode(streamEvent))
precondition(decodedStreamEvent.chat?.text == "最终回答" && decodedStreamEvent.chat?.phase == "final_answer")
let failedStreamEvent = HostEventEnvelope(
    kind: "chat",
    chat: ChatStreamEvent(kind: "status", turnID: "turn", text: "动态工具协议失败", status: "failed")
)
let decodedFailedStreamEvent = try JSONDecoder().decode(HostEventEnvelope.self, from: JSONEncoder().encode(failedStreamEvent))
precondition(decodedFailedStreamEvent.chat?.status == "failed" && decodedFailedStreamEvent.chat?.text == "动态工具协议失败")
let terminal = ChatTurnTerminalDTO(turnID: "failed-turn", status: "failed", issueCode: "provider_auth_failed", message: "认证已失效", completedAt: .now)
let terminalHistory = ChatHistoryResponse(revision: "1", messages: [], terminalTurns: [terminal])
let decodedTerminalHistory = try JSONDecoder().decode(ChatHistoryResponse.self, from: JSONEncoder().encode(terminalHistory))
precondition(decodedTerminalHistory.terminalTurns == [terminal])
let legacyHistory = try JSONDecoder().decode(ChatHistoryResponse.self, from: Data(#"{"revision":"0","messages":[]}"#.utf8))
precondition(legacyHistory.terminalTurns == nil)
let legacyHealth = try JSONDecoder().decode(HealthResponse.self, from: Data(#"{"apiVersion":1,"hostVersion":"0","repositoryBound":true,"codexReady":true,"pairedDeviceCount":0,"activeThreadID":null,"repositoryID":null,"dynamicToolsReady":true}"#.utf8))
precondition(legacyHealth.chatState == nil && legacyHealth.chatIssueCode == nil)
let health = HealthResponse(hostVersion: "0", repositoryBound: true, codexReady: true, pairedDeviceCount: 1, activeThreadID: "thread", dynamicToolsReady: false, chatState: StudyRocketChatState.authFailed.rawValue, chatIssueCode: "provider_auth_failed")
let decodedHealth = try JSONDecoder().decode(HealthResponse.self, from: JSONEncoder().encode(health))
precondition(decodedHealth.chatIssueCode == "provider_auth_failed")
let selection = StudyRocketModelSelection.configReadResult(["config": ["model": "gpt-test", "model_provider": "current-provider"]])
precondition(selection == StudyRocketModelSelection(model: "gpt-test", modelProvider: "current-provider"))
precondition(StudyRocketModelSelection.threadResult(["thread": ["model": "gpt-test", "modelProvider": "current-provider"]]) == selection)
precondition(StudyRocketModelSelection.configReadResult(["config": ["model": "gpt-test"]]) == nil)
let heartbeat = HostEventEnvelope(kind: "heartbeat")
let decodedHeartbeat = try JSONDecoder().decode(HostEventEnvelope.self, from: JSONEncoder().encode(heartbeat))
precondition(decodedHeartbeat.kind == "heartbeat" && decodedHeartbeat.snapshot == nil && decodedHeartbeat.chat == nil)
let document = DocumentDetail(documentKey: "course", title: "课程", markdown: "# 课程", revision: "abc")
let decodedDocument = try JSONDecoder().decode(DocumentDetail.self, from: JSONEncoder().encode(document))
precondition(decodedDocument == document)
let legacySummary = try JSONDecoder().decode(SummaryCard.self, from: Data(#"{"id":"legacy","title":"课程","detail":"摘要"}"#.utf8))
precondition(legacySummary.documentKey == nil)
let markdownBlocks = StudyRocketMarkdownParser.blocks(from: "说明\n\n| 课程 | 时间 |\n| --- | --- |\n| 数据科学 | 上午 |\n\n结尾")
precondition(markdownBlocks.count == 3)
if case .table(_, let columns) = markdownBlocks[1] { precondition(columns == 2) } else { preconditionFailure("table block not detected") }
let escapedTable = StudyRocketMarkdownParser.blocks(from: "| 内容 | 状态 |\n| --- | --- |\n| A \\| B | 完成 |")
if case .table(_, let columns) = escapedTable.first { precondition(columns == 2) } else { preconditionFailure("escaped-pipe table not detected") }
let fencedTable = StudyRocketMarkdownParser.blocks(from: "```markdown\n| A | B |\n|---|---|\n```")
precondition(fencedTable.count == 1 && { if case .prose = fencedTable[0] { return true }; return false }())

let leaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("studyrocket-lease-\(UUID().uuidString).json")
let leaseStore = CodexLeaseStore(url: leaseURL)
let lease = try leaseStore.acquire(owner: "shared-check")
do {
    _ = try leaseStore.acquire(owner: "second-check")
    preconditionFailure("a second Codex lease must be rejected")
} catch CodexLeaseError.busy {
    // Expected.
}
lease.release()
precondition(!FileManager.default.fileExists(atPath: leaseURL.path))
let descriptorRoot = FileManager.default.temporaryDirectory.appendingPathComponent("studyrocket-descriptors-" + UUID().uuidString, isDirectory: true)
let descriptorStore = StudyRocketTaskDescriptorStore(directory: descriptorRoot)
let firstRoot = descriptorRoot.appendingPathComponent("repo-a", isDirectory: true)
let secondRoot = descriptorRoot.appendingPathComponent("repo-b", isDirectory: true)
let descriptor = StudyRocketTaskDescriptor(threadID: "thread-a")
precondition(descriptor.protocolVersion == StudyRocketAPI.academicTaskProtocolVersion)
try descriptorStore.save(descriptor, for: firstRoot)
precondition(descriptorStore.load(for: firstRoot) == descriptor)
precondition(descriptorStore.load(for: secondRoot) == nil)
try descriptorStore.save(StudyRocketTaskDescriptor(threadID: "thread-b", protocolVersion: 4), for: secondRoot)
precondition(descriptorStore.load(for: secondRoot)?.protocolVersion == 4)
var migratedTaskCount = 0
let restoreAcademicTask: () throws -> String = {
    if let stored = descriptorStore.load(for: secondRoot),
       stored.protocolVersion == StudyRocketAPI.academicTaskProtocolVersion {
        return stored.threadID
    }
    migratedTaskCount += 1
    let newThreadID = "thread-v5-\(migratedTaskCount)"
    try descriptorStore.save(StudyRocketTaskDescriptor(threadID: newThreadID), for: secondRoot)
    return newThreadID
}
let firstMigratedThreadID = try restoreAcademicTask()
let secondRestoredThreadID = try restoreAcademicTask()
precondition(migratedTaskCount == 1)
precondition(firstMigratedThreadID == secondRestoredThreadID)
precondition(descriptorStore.load(for: secondRoot) == StudyRocketTaskDescriptor(threadID: firstMigratedThreadID))
descriptorStore.remove(for: firstRoot)
precondition(descriptorStore.load(for: firstRoot) == nil)
try? FileManager.default.removeItem(at: descriptorRoot)
print("StudyRocketSharedChecks: signing, DTO, lease and task descriptor checks passed")

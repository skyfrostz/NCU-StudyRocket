import Foundation
import StudyRocketShared
import SQLiteNIO

extension CloudStore {
    /// A source-bound, read-only seed for the assistant. This never activates
    /// linkage or writes the weekly plan; the normal proposal path still owns it.
    func taskLinkagePreview() throws -> (hash: String, json: String) {
        try ensureReady()
        let file = try file("工作台/下周计划.md")
        let week = snapshot().week
        let graph = (week.linkage ?? TaskLinkage(activationDate: PlanningDate.key(.now))).reconciled(with: week)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (file.hash, String(decoding: try encoder.encode(graph), as: UTF8.self))
    }
    func proposals() throws -> ProposalListResponse {
        try ensureReady()
        return ProposalListResponse(proposals:try db.run("SELECT body FROM proposals ORDER BY rowid").map { try decode(ProposalDTO.self,Data($0.column("body")!.string!.utf8)) })
    }
    func registerProposal(path: String, content: String, baseHash: String, reason: String, turn: String, readHashes: [String:String]) throws -> ProposalDTO {
        guard activeRun == turn, !interrupted.contains(turn) else {throw CancellationError()}
        guard readHashes[path] == baseHash, content.utf8.count <= Self.maximumFileBytes, reason.count <= 2000 else { throw CloudError(409,"read_required","草案必须以本回合读取过的文件哈希为基线。") }
        _ = try Self.safeURL(path,root:root,write:true)
        let original = (try? file(path)) ?? CloudFileContent(path:path,hash:"absent",content:"")
        guard original.hash == baseHash else { throw CloudError(409,"conflict","读取后文件已变化，请重新读取再生成草案。") }
        if path == "工作台/下周计划.md", try TaskLinkageMarkdown.read(original.content) == nil,
           let graph = try TaskLinkageMarkdown.read(content) {
            let seed = TaskLinkage(activationDate: PlanningDate.key(.now)).reconciled(with: snapshot().week)
            guard graph.activationDate == seed.activationDate else { throw TaskLinkageError.changed }
            try PlanningProposalValidation.preserveHistory(from: seed, in: graph)
        }
        var next = try PlanningProposalValidation.prepare(path:path,original:original.content,proposed:content)
        var paired: ProposalDTO?
        if path == "工作台/下周计划.md", let timetable = try? file(StudyRocketTimetableParser.sourceFile) {
            guard readHashes[StudyRocketTimetableParser.sourceFile] == timetable.hash else { throw CloudError(409,"read_required","修改计划前也必须读取当前课表，以保留并分流活动。") }
            let routed = try PlanningChangeRouter.route(week:content,original:original.content,timetable:timetable.content)
            next = routed.week
            if let changed = routed.timetable { paired = ProposalDTO(id:UUID().uuidString,turnID:turn,relativePath:timetable.path,originalContent:timetable.content,proposedContent:changed,reason:"同组活动分流",baseHash:timetable.hash,kind:"markdown") }
        }
        let proposal = ProposalDTO(id:UUID().uuidString,turnID:turn,relativePath:path,originalContent:original.content,proposedContent:next,reason:reason,baseHash:baseHash,kind:"markdown")
        try db.transaction {
            let all = try proposals().proposals
            for old in all where old.turnID == turn && (old.relativePath == path || old.relativePath == paired?.relativePath) { try db.run("DELETE FROM proposals WHERE id=?",[.text(old.id)]) }
            for p in [proposal,paired].compactMap({$0}) { try db.run("INSERT INTO proposals(id,body) VALUES(?,?)",[.text(p.id),.text(try jsonString(p))]) }
        }
        _ = try appendEvent(HostEventEnvelope(kind:"proposals.updated"))
        return proposal
    }
    func applyProposals(_ request: ProposalApplyRequest, raw: Data, device: String) throws -> Data {
        // Authorization challenge is attempt-specific; intent hash binds only selected IDs and base version.
        let intent = try json(["ids":request.proposalIDs.sorted().joined(separator:","),"revision":request.metadata.baseRevision,"version":String(request.metadata.apiVersion)])
        let requestHash = digest(Data("/v1/proposals/apply".utf8) + intent)
        if let replay = try replay(id:request.metadata.idempotencyKey,requestHash:requestHash) { return replay }
        guard request.metadata.apiVersion == 1, request.metadata.baseRevision == snapshot().revision else { throw CloudError(409,"conflict","云端已变化，请重新检查草案。") }
        let all = try proposals().proposals
        let ids = Set(request.proposalIDs), selected = all.filter { ids.contains($0.id) }
        guard !ids.isEmpty, ids.count == selected.count, ids.count == request.proposalIDs.count, Set(selected.map(\.relativePath)).count == selected.count else { throw CloudError(422,"invalid_proposals","草案不存在、重复或修改相同文件。") }
        let planning = Set(["工作台/下周计划.md",StudyRocketTimetableParser.sourceFile])
        let turns = Set(selected.filter { planning.contains($0.relativePath) }.map(\.turnID))
        guard all.filter({ turns.contains($0.turnID) && planning.contains($0.relativePath) }).allSatisfy({ids.contains($0.id)}) else { throw CloudError(422,"planning_pair_required","任务和活动草案需要成组确认。") }
        let skillPaths=Set(selected.filter {$0.kind == "skill"}.map(\.relativePath))
        let (newSnapshot,changes) = try stage(skillPaths:skillPaths) { staging in
            for proposal in selected {
                let current = try? file(proposal.relativePath)
                guard (current?.hash ?? "absent") == proposal.baseHash else { throw CloudError(409,"conflict","草案文件基线已变化。") }
                try PlanningProposalValidation.validateManagedBoundaries(path: proposal.relativePath, original: current?.content ?? "", proposed: proposal.proposedContent)
                if proposal.kind == "skill" {try Self.validateSkillContent(path:proposal.relativePath,original:proposal.originalContent,proposed:proposal.proposedContent)}
                let target = try Self.safeURL(proposal.relativePath,root:staging,write:proposal.kind != "skill")
                try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                try Data(proposal.proposedContent.utf8).write(to:target,options:.atomic)
            }
            return AcademicSnapshotBuilder(root:staging,repositoryID:repositoryID).build()
        }
        try consumeAuthorization(request.authorization,device:device)
        let response = ProposalApplyResponse(remaining:ProposalListResponse(proposals:all.filter{!ids.contains($0.id)}),revision:newSnapshot.revision)
        return try commit(id:request.metadata.idempotencyKey,requestHash:requestHash,files:changes,response:json(response),revision:newSnapshot.revision,consumed:Array(ids))
    }
    func importHistory(_ request: CloudHistoryImportRequest, raw: Data) throws -> Data {
        let requestHash = digest(Data("history-import".utf8) + (try canonical(raw)))
        if let replay = try replay(id:request.idempotencyKey,requestHash:requestHash) { return replay }
        guard request.messages.count <= 200 else { throw CloudError(413,"batch_too_large","每批最多导入 200 条文字消息。") }
        let response = try json(["imported":request.messages.count])
        try db.transaction {
            for item in request.messages {
                guard ["user","assistant"].contains(item.role), item.text.utf8.count <= Self.maximumFileBytes, !item.id.isEmpty, item.id.count <= 200, item.sourceThreadID.count <= 200,
                      item.source == "codex-import" else { throw CloudError(422,"invalid_history","历史仅允许明确来源的用户和助理可见文字。") }
                try addMessage(item)
            }
            try db.run("INSERT INTO operations(id,request_hash,state,response,created) VALUES(?,?,'succeeded',?,?)",[.text(request.idempotencyKey),.text(requestHash),.text(String(decoding:response,as:UTF8.self)),.float(Date().timeIntervalSince1970)])
        }
        return response
    }
    func addMessage(_ message: CloudArchivedMessage) throws {
        let body = try jsonString(message)
        if let old = try db.run("SELECT body FROM messages WHERE id=?",[.text(message.id)]).first?.column("body")?.string {
            guard old == body else { throw CloudError(422,"message_id_reused","消息编号已用于不同内容。") }; return
        }
        try db.run("INSERT INTO messages(id,thread,role,text,date,source,body) VALUES(?,?,?,?,?,?,?)",[.text(message.id),.text(message.sourceThreadID),.text(message.role),.text(message.text),.float(message.date.timeIntervalSince1970),.text(message.source),.text(body)])
    }
    func history(after: Int, limit: Int, query: String = "") throws -> CloudHistoryPage {
        let limit = min(max(limit,1),200), query = String(query.prefix(500))
        let filter = query.isEmpty ? "" : " AND instr(text,?)>0"
        var binds: [SQLiteData] = [.integer(max(after,0))]
        if !query.isEmpty { binds.append(.text(query)) }
        binds.append(.integer(limit + 1))
        let rows = try db.run("SELECT seq,body FROM messages WHERE seq>?" + filter + " ORDER BY seq LIMIT ?",binds)
        let selected = Array(rows.prefix(limit))
        let count = try db.run("SELECT count(*) AS n FROM messages WHERE 1=1" + filter,query.isEmpty ? [] : [.text(query)]).first!.column("n")!.integer!
        return CloudHistoryPage(messages:try selected.map { let m=try decode(CloudArchivedMessage.self,Data($0.column("body")!.string!.utf8));return CloudArchivedMessage(id:m.id,sourceThreadID:m.sourceThreadID,role:m.role,text:m.text,date:m.date,source:m.source,attachments:hydratedAttachments(m.attachments)) },nextCursor:rows.count > limit ? selected.last?.column("seq")?.integer : nil,total:count)
    }
    func chatHistory() throws -> ChatHistoryResponse {
        let rows = try db.run("SELECT body FROM messages WHERE thread=? ORDER BY seq DESC LIMIT 200",[.text(threadID)])
        let states = try db.run("SELECT id,state FROM turns ORDER BY rowid DESC LIMIT 200").reduce(into:[String:String]()) { result,row in result[row.column("id")!.string!]=row.column("state")!.string! }
        let messages = try rows.reversed().map { row -> ChatMessageDTO in
            let m = try decode(CloudArchivedMessage.self,Data(row.column("body")!.string!.utf8))
            let turnID=m.id.components(separatedBy:"/").first
            return ChatMessageDTO(id:m.id,role:m.role,text:m.text,date:m.date,turnID:turnID,status:turnID.flatMap {states[$0]} ?? "completed",attachments:hydratedAttachments(m.attachments))
        }
        let turns = try db.run("SELECT body FROM turns WHERE state!='inProgress' ORDER BY rowid DESC LIMIT 40").map { try decode(ChatTurnTerminalDTO.self,Data($0.column("body")!.string!.utf8)) }
        let revision = try db.run("SELECT max(seq) AS n FROM messages").first?.column("n")?.integer ?? 0
        return ChatHistoryResponse(revision:String(revision),messages:messages,terminalTurns:turns)
    }
    func beginRun(_ request: SendChatRequest, raw: Data, admissionError: CloudError? = nil) throws -> String? {
        let hash = digest(Data("chat-send".utf8) + (try canonical(raw)))
        if let _ = try replay(id:request.clientRequestID,requestHash:hash) { return nil }
        if let admissionError {throw admissionError}
        guard activeRun == nil else { throw CloudError(409,"chat_busy","上一回合仍在执行，请等待或停止。") }
        guard request.apiVersion == 1, (!request.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !(request.attachmentIDs ?? []).isEmpty), request.text.utf8.count <= 32_000 else { throw CloudError(422,"invalid_chat","消息为空或超过长度上限。") }
        let id = request.clientRequestID
        let lock=try CloudFileLock(state:state);defer{withExtendedLifetime(lock){}}
        let attachments=try admitAttachments(request.attachmentIDs ?? [])
        try db.transaction {
            try db.run("INSERT INTO operations(id,request_hash,state,response,created) VALUES(?,?,'running','{}',?)",[.text(id),.text(hash),.float(Date().timeIntervalSince1970)])
            try db.run("INSERT INTO turns(id,state,body) VALUES(?,'inProgress',?)",[.text(id),.text(try jsonString(ChatTurnTerminalDTO(turnID:id,status:"inProgress")))])
            try addMessage(CloudArchivedMessage(id:id + "/user",sourceThreadID:threadID,role:"user",text:request.text,date:.now,source:"cloud",attachments:attachments.isEmpty ? nil:attachments))
        }
        activeRun = id
        _ = try appendEvent(HostEventEnvelope(kind:"chat",chat:ChatStreamEvent(kind:"status",turnID:id,status:"inProgress")))
        return id
    }
    func isInterrupted(_ id: String) -> Bool { activeRun != id || interrupted.contains(id) }
    func interruptRun(_ request: InterruptRequest) throws -> ChatInterruptResponse {
        guard request.apiVersion == 1,UUID(uuidString:request.turnID) != nil,let operationID=request.operationID,UUID(uuidString:operationID) != nil else {throw CloudError(422,"target_required","停止必须指定具体回合和固定操作编号。")}
        let hash=digest(try json(request))
        _ = try replay(id:operationID,requestHash:hash)
        guard let row=try db.run("SELECT state,body FROM turns WHERE id=?",[.text(request.turnID)]).first else {throw CloudError(404,"turn_not_found","目标回合不存在，请先查询原请求结果。")}
        if row.column("state")?.string == "inProgress" {
            guard activeRun == request.turnID else {throw CloudError(409,"turn_not_active","目标回合不是当前活动回合。")}
            interrupted.insert(request.turnID)

        }
        let terminal=try decode(ChatTurnTerminalDTO.self,Data(try db.run("SELECT body FROM turns WHERE id=?",[.text(request.turnID)]).first!.column("body")!.string!.utf8))
        let result=ChatInterruptResponse(targetTurnID:request.turnID,operationID:operationID,status:terminal.status == "inProgress" ? "cancelling":terminal.status,terminal:terminal.status == "inProgress" ? nil:terminal)
        try db.run("INSERT INTO operations(id,request_hash,state,response,created) VALUES(?,?,'succeeded',?,?) ON CONFLICT(id) DO UPDATE SET response=excluded.response",[.text(operationID),.text(hash),.text(try jsonString(result)),.float(Date().timeIntervalSince1970)])
        return result
    }
    func completeRun(_ id: String, status: String, text: String, issue: String? = nil) throws {
        guard activeRun == id,try db.run("SELECT state FROM turns WHERE id=?",[.text(id)]).first?.column("state")?.string == "inProgress" else {return}
        let status = interrupted.contains(id) ? "interrupted" : status
        let persistedPartial = try db.run("SELECT text FROM partials WHERE id=?",[.text(id)]).first?.column("text")?.string ?? ""
        let text = status != "completed" && !persistedPartial.isEmpty ? persistedPartial + "\n\n（本回合未完成，已保留收到的文字。）" : text
        let terminal = ChatTurnTerminalDTO(turnID:id,status:status,issueCode:issue,message:status == "completed" ? nil : text,completedAt:.now)
        try db.transaction {
            if status == "completed" || !text.isEmpty { try addMessage(CloudArchivedMessage(id:id + "/assistant",sourceThreadID:threadID,role:"assistant",text:text,date:.now,source:"cloud")) }
            try db.run("DELETE FROM partials WHERE id=?",[.text(id)])
            try db.run("UPDATE turns SET state=?,body=? WHERE id=?",[.text(status),.text(try jsonString(terminal)),.text(id)])
            try db.run("UPDATE operations SET state='succeeded',response=? WHERE id=?",[.text(try jsonString(terminal)),.text(id)])
        }
        if activeRun == id {activeRun = nil}; interrupted.remove(id)
        if !text.isEmpty { _ = try appendEvent(HostEventEnvelope(kind:"chat",chat:ChatStreamEvent(kind:"item_completed",turnID:id,itemID:id + "/assistant",text:text,phase:"final_answer",status:status))) }
        _ = try appendEvent(HostEventEnvelope(kind:"chat",chat:ChatStreamEvent(kind:"status",turnID:id,text:terminal.message,status:status,issueCode:issue,completedAt:terminal.completedAt)))
    }
}

extension CloudStore {
    func sessionContext(hash: String) throws -> String? {try db.value("background-context:" + hash)}
    func setSessionContext(hash: String, summary: String) throws {
        try db.transaction {
            try db.run("DELETE FROM kv WHERE key LIKE 'background-context:%'")
            try db.set("background-context:" + hash,summary)
        }
    }
}

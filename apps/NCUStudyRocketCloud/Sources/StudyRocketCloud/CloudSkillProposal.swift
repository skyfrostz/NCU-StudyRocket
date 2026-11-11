import Foundation
import StudyRocketShared
import SQLiteNIO

extension CloudStore {
    nonisolated static func skillPath(_ path: String) -> Bool {
        let parts=path.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
        return parts.count == 4 && parts[0] == ".agents" && parts[1] == "skills" && skills.contains(parts[2]) && parts[3] == "SKILL.md"
    }
    nonisolated static func validateSkillContent(path: String, original: String, proposed: String) throws {
        guard skillPath(path),proposed.utf8.count <= maximumFileBytes else {throw CloudError(403,"skill_path_denied","仅允许八个既有学业 SKILL.md 的专用草案。")}
        func frontmatter(_ content: String) -> String? {
            let lines=content.components(separatedBy:"\n")
            guard lines.first == "---",let closing=lines.dropFirst().firstIndex(of:"---") else {return nil}
            let header=lines[...closing].joined(separator:"\n")
            return header.contains("name:") && header.contains("description:") ? header:nil
        }
        guard let old=frontmatter(original),let new=frontmatter(proposed),old == new,proposed.components(separatedBy:"\n").count <= 300 else {throw CloudError(422,"invalid_skill","Skill 必须保留原 YAML frontmatter，且不超过 300 行。")}
        let oldLines=Set(original.components(separatedBy:"\n"))
        let added=proposed.components(separatedBy:"\n").filter {!oldLines.contains($0) && !$0.trimmingCharacters(in:.whitespaces).isEmpty}
        guard added.allSatisfy({line in
            !line.contains("```") && !line.contains("~~~") && !line.contains("#!/") && !line.contains("<script") && !line.contains("$(") && !line.contains("身份证") && !line.contains("密码") && !line.contains("手机号") && line.range(of:#"\b20\d{2}-\d{2}-\d{2}\b"#,options:.regularExpression) == nil
        }) else {throw CloudError(422,"invalid_skill","Skill 差异只能是通用流程，不得包含脚本、个人事实日期或敏感记录。")}
    }
    nonisolated static func journalURL(_ file: JournalFile, root: URL) throws -> URL {
        if file.skill == true {
            guard let before=file.before,let original=String(data:before,encoding:.utf8),let proposed=String(data:file.after,encoding:.utf8) else {throw CloudError(403,"skill_path_denied","Skill updates must modify existing UTF-8 files")}
            try validateSkillContent(path:file.path,original:original,proposed:proposed)
            return try safeURL(file.path,root:root)
        }
        return try safeURL(file.path,root:root,write:true)
    }
    func registerSkillProposal(path: String, content: String, baseHash: String, reason: String, evidence: [[String:Any]], turn: String, readHashes: [String:String]) throws -> ProposalDTO {
        guard readHashes[path] == baseHash,!reason.isEmpty,reason.count <= 1500,(3...8).contains(evidence.count) else {throw CloudError(422,"skill_evidence_required","Skill 更新须有至少三次可证规律、改进理由，并先完整读取目标。")}
        let original=try file(path)
        guard original.hash == baseHash else {throw CloudError(409,"conflict","Skill 读取后已变化，请重新读取。")}
        try Self.validateSkillContent(path:path,original:original.content,proposed:content)
        var dates=Set<String>(),citations:[String]=[]
        for item in evidence {
            guard let source=item["path"] as? String,let quote=item["quote"] as? String,let date=item["date"] as? String,Self.allowed(source,write:true),quote.count >= 8,quote.count <= 1000,date.range(of:#"^20\d{2}-\d{2}-\d{2}$"#,options:.regularExpression) != nil,quote.contains(date) else {throw CloudError(422,"skill_evidence_required","每条依据须引用学业记录中的日期与原文。")}
            let file=try self.file(source)
            guard readHashes[source] == file.hash,file.content.contains(quote) else {throw CloudError(409,"skill_evidence_required","依据须来自本回合完整读取且未变化的文件原文。")}
            dates.insert(date);citations.append("- \(date)｜\(source)：\(quote)")
        }
        guard dates.count >= 3 else {throw CloudError(422,"skill_evidence_required","同类规律至少需要三个不同日期的可证记录。")}
        let reason=reason + "\n\n流程改进依据（只随草案展示，不写入 Skill）：\n" + citations.joined(separator:"\n")
        let proposal=ProposalDTO(id:UUID().uuidString,turnID:turn,relativePath:path,originalContent:original.content,proposedContent:content,reason:reason,baseHash:baseHash,kind:"skill")
        try db.transaction {
            for old in try proposals().proposals where old.turnID == turn && old.relativePath == path {try db.run("DELETE FROM proposals WHERE id=?",[.text(old.id)])}
            try db.run("INSERT INTO proposals(id,body) VALUES(?,?)",[.text(proposal.id),.text(try jsonString(proposal))])
        }
        _ = try appendEvent(HostEventEnvelope(kind:"proposals.updated"))
        return proposal
    }
}

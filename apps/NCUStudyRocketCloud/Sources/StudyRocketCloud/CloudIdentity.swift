import Foundation
import Crypto
import StudyRocketShared
import SQLiteNIO

extension CloudStore {
    func authenticate(_ authentication: RequestAuthentication?, method: String, path: String, body: Data) throws -> String {
        guard let a = authentication, abs(Date().timeIntervalSince1970 - Double(a.timestamp)) <= 60,
              UUID(uuidString:a.deviceID) != nil, UUID(uuidString:a.nonce) != nil, a.signature.utf8.count <= 256,
              let key = try db.run("SELECT public_key FROM devices WHERE id=? AND revoked=0",[.text(a.deviceID)]).first?.column("public_key")?.string,
              let publicKey = Data(base64Encoded:key),
              RequestSigning.verify(publicKeyData:publicKey,signatureBase64:a.signature,method:method,path:path,timestamp:a.timestamp,nonce:a.nonce,bodyHash:digest(body)) else {
            throw CloudError(401,"unauthorized","设备未配对、已撤销或签名失效。")
        }
        try db.run("DELETE FROM nonces WHERE expires<?",[.float(Date().timeIntervalSince1970)])
        guard try db.run("SELECT id FROM nonces WHERE id=?",[.text(a.nonce)]).isEmpty else { throw CloudError(401,"replayed_signature","请求签名已使用。") }
        try db.run("INSERT INTO nonces(id,expires) VALUES(?,?)",[.text(a.nonce),.float(Date().timeIntervalSince1970 + 120)])
        return a.deviceID
    }
    func pair(_ request: PairRequest) throws -> PairResponse {
        let url = state.appendingPathComponent("pair-code.json")
        guard request.apiVersion == 1, let data = try? Data(contentsOf:url), let code = try? decode(PairCode.self,data), code.expiresAt > .now else { throw CloudError(401,"pairing_expired","配对码已失效，请由管理员重新生成。") }
        let codeIdentity = digest(data)
        guard try db.value("pairConsumed:" + codeIdentity) == nil else { throw CloudError(401,"pairing_expired","配对码已使用。") }
        let attemptKey = "pairAttempts:" + codeIdentity
        let attempts = Int(try db.value(attemptKey) ?? "0") ?? 0
        guard attempts < 5 else { throw CloudError(429,"pairing_locked","配对尝试过多，请生成新配对码。") }
        try db.set(attemptKey,String(attempts + 1))
        guard request.code.count == 6, digest(Data(request.code.utf8)) == digest(Data(code.code.utf8)) else { throw CloudError(401,"pairing_invalid","配对码不正确。") }
        guard (1...64).contains(request.deviceName.count), !request.deviceName.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              let bytes = Data(base64Encoded:request.publicKey), (try? P256.Signing.PublicKey(rawRepresentation:bytes)) != nil else { throw CloudError(422,"invalid_device","设备名称或公钥无效。") }
        let id = UUID().uuidString
        try db.transaction {
            try db.set("pairConsumed:" + codeIdentity,"true")
            try db.run("INSERT INTO devices(id,name,public_key) VALUES(?,?,?)",[.text(id),.text(request.deviceName),.text(request.publicKey)])
        }
        try? FileManager.default.removeItem(at:url)
        return PairResponse(deviceID:id,serverName:"StudyRocket Cloud")
    }
    func challenge(device: String) throws -> ProposalAuthorizationChallenge {
        let challenge = UUID().uuidString, expires = Date().addingTimeInterval(90)
        try db.run("DELETE FROM challenges WHERE device=? OR expires<?",[.text(device),.float(Date().timeIntervalSince1970)])
        try db.run("INSERT INTO challenges(id,device,expires) VALUES(?,?,?)",[.text(challenge),.text(device),.float(expires.timeIntervalSince1970)])
        return ProposalAuthorizationChallenge(challenge:challenge,expiresAt:expires)
    }
    func consumeAuthorization(_ value: String, device: String) throws {
        let pieces = value.split(separator:"|",maxSplits:1).map(String.init)
        guard pieces.count == 2, value.count < 512,
              let record = try db.run("SELECT expires FROM challenges WHERE id=? AND device=?",[.text(pieces[0]),.text(device)]).first,
              (record.column("expires")?.double ?? 0) > Date().timeIntervalSince1970,
              let key = try db.run("SELECT public_key FROM devices WHERE id=? AND revoked=0",[.text(device)]).first?.column("public_key")?.string,
              let bytes = Data(base64Encoded:key), RequestSigning.verifyAuthorization(publicKeyData:bytes,signatureBase64:pieces[1],challenge:pieces[0]) else { throw CloudError(403,"confirmation_required","请重新确认草案。") }
        try db.run("DELETE FROM challenges WHERE id=?",[.text(pieces[0])])
    }
    func health(modelReady: Bool, authenticated: Bool) throws -> HealthResponse {
        try ensureReady()
        let count = try db.run("SELECT count(*) AS n FROM devices WHERE revoked=0").first!.column("n")!.integer!
        return HealthResponse(hostVersion:"cloud-1.0.0",repositoryBound:true,codexReady:modelReady,pairedDeviceCount:authenticated ? count : 0,activeThreadID:authenticated ? threadID : nil,repositoryID:authenticated ? repositoryID : nil,dynamicToolsReady:modelReady,chatState:modelReady ? "ready" : "unavailable",backend:"cloud",capabilities:["academic-files","durable-operations","shared-chat","history-import","sse-replay","proposal-confirmation"],legacyRepositoryID:authenticated ? try db.value("legacyRepositoryID") : nil)
    }
    func revoke(deviceID: String) throws { try db.run("UPDATE devices SET revoked=1 WHERE id=?",[.text(deviceID)]) }
}

import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import ServiceLifecycle
import StudyRocketShared

@main enum StudyRocketCloudMain {
    static func main() async throws {
        let args=Array(CommandLine.arguments.dropFirst())
        let command=args.first ?? "help"
        func option(_ name:String,_ fallback:String?=nil)->String? { guard let i=args.firstIndex(of:name),i+1 < args.count else{return fallback};return args[i+1] }
        guard let statePath=option("--state") else {
            print("StudyRocketCloud serve --repository PATH --state PATH [--host 127.0.0.1 --port 43818]\nStudyRocketCloud pair-code --state PATH\nStudyRocketCloud history-import --state PATH --file JSONL\nStudyRocketCloud revoke --state PATH --device UUID")
            return
        }
        let state=URL(fileURLWithPath:statePath,isDirectory:true)
        try FileManager.default.createDirectory(at:state,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if command == "pair-code" {
            let code=PairCode(code:String(format:"%06d",Int.random(in:0...999999)),expiresAt:Date().addingTimeInterval(300))
            try CloudStore.durableWrite(json(code),to:state.appendingPathComponent("pair-code.json"))
            print(try jsonString(code)); return
        }
        if command == "init" || command == "backup" {
            guard let path=option("--repository") else {throw CloudError(400,"missing_repository","--repository is required")}
            let root=URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath()
            if command == "init" {
                guard let path=option("--manifest") else {throw CloudError(400,"missing_manifest","--manifest is required")}
                try CloudAdministration.initialize(root:root,state:state,manifestURL:URL(fileURLWithPath:path))
            } else {
                guard let path=option("--output") else {throw CloudError(400,"missing_output","--output is required")}
                try CloudAdministration.backup(root:root,state:state,output:URL(fileURLWithPath:path))
            }
            print(command + " completed"); return
        }
        if command == "history-import" {
            guard let file=option("--file") else { throw CloudError(400,"missing_file","--file is required") }
            let db=try CloudDatabase(path:state.appendingPathComponent("cloud.sqlite"))
            let lines=try String(contentsOfFile:file,encoding:.utf8).split(separator:"\n")
            var imported=0
            for batchStart in stride(from:0,to:lines.count,by:200) {
                try db.transaction {
                    for line in lines[batchStart..<min(batchStart+200,lines.count)] {
                        let item=try decode(CloudArchivedMessage.self,Data(line.utf8))
                        guard ["user","assistant"].contains(item.role), item.source == "codex-import", item.text.utf8.count <= CloudStore.maximumFileBytes else { throw CloudError(422,"invalid_history","Only visible user/assistant history may be imported") }
                        let body=try jsonString(item)
                        if let previous=try db.run("SELECT body FROM messages WHERE id=?",[.text(item.id)]).first?.column("body")?.string {
                            guard previous == body else { throw CloudError(422,"message_id_reused","History ID contains different content") };continue
                        }
                        try db.run("INSERT INTO messages(id,thread,role,text,date,source,body) VALUES(?,?,?,?,?,?,?)",[.text(item.id),.text(item.sourceThreadID),.text(item.role),.text(item.text),.float(item.date.timeIntervalSince1970),.text(item.source),.text(body)])
                        imported += 1
                    }
                }
            }
            print("Imported \(imported) visible messages");return
        }
        if command == "revoke" {
            guard let id=option("--device"),UUID(uuidString:id) != nil else {throw CloudError(422,"invalid_device","--device UUID is required")}
            let db=try CloudDatabase(path:state.appendingPathComponent("cloud.sqlite"))
            try db.run("UPDATE devices SET revoked=1 WHERE id=?",[.text(id)]);print("Device revoked");return
        }
        guard command == "serve",let repository=option("--repository"),let port=Int(option("--port","43818")!), (1024...65535).contains(port) else { throw CloudError(400,"invalid_configuration","serve requires --repository, --state and valid --port") }
        let test=args.contains("--allow-test-failpoints")
        let failpoint=test ? ProcessInfo.processInfo.environment["STUDYROCKET_CLOUD_FAILPOINT"] : nil
        let fixture=test ? option("--test-model-fixture").map {URL(fileURLWithPath:$0)} : nil
        let testUpstream=option("--test-upstream-url")
        if let testUpstream {
            guard test,let url=URLComponents(string:testUpstream),url.scheme == "http",url.host == "127.0.0.1",url.user == nil,url.password == nil,url.fragment == nil else {throw CloudError(400,"invalid_test_upstream","Test upstream requires --allow-test-failpoints and literal http://127.0.0.1")}
        }
        func testMemory(_ name: String) throws -> Int? {
            guard let value=option(name) else {return nil}
            guard test,let number=Int(value),(0...1_000_000).contains(number) else {throw CloudError(400,"invalid_test_memory","Memory test values require --allow-test-failpoints and nonnegative MiB")}
            return number
        }
        let memory=try CloudMemoryAdmission(testAvailableMiB:testMemory("--test-memory-available-mib"),testCurrentMiB:testMemory("--test-memory-current-mib"))
        let store=try CloudStore(root:URL(fileURLWithPath:repository),state:state,failpoint:failpoint)
        let key=ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] ?? ""
        let agent=try CloudAgent(store:store,apiKey:key,fixture:fixture,testUpstream:testUpstream,memoryAdmission:memory)
        let router=Router()
        let handler=CloudHTTP(store:store,agent:agent)
        for path in ["v1/health","v1/snapshot","v1/week","v1/daily","v1/summaries","v1/proposals","v1/proposals/challenge","v1/chat/history","v1/events","v1/files/manifest","v1/backups/latest","v1/versions","v1/history","v1/operations/{id}","v1/documents/{key}"] {
            router.get(RouterPath(path)) { request,context in await handler.handle(request,context:context) }
        }
        for path in ["v1/pair","v1/week","v1/daily","v1/facts","v1/deliveries/toggle","v1/periods/toggle","v1/proposals/apply","v1/chat/send","v1/chat/interrupt","v1/files/read","v1/backups/read","v1/files/commit","v1/history/import","v1/versions/read"] {
            router.post(RouterPath(path)) { request,context in await handler.handle(request,context:context) }
        }
        router.put("v1/week") { request,context in await handler.handle(request,context:context) }
        let app=Application(router:router,configuration:.init(address:.hostname(option("--host","127.0.0.1")!,port:port)))
        try await app.runService()
    }
}

struct CloudHTTP: Sendable {
    let store: CloudStore
    let agent: CloudAgent
    func handle(_ request: Request, context: BasicRequestContext) async -> Response {
        do {
            let buffer=try await request.body.collect(upTo:2_097_152)
            let body=Data(buffer.readableBytesView),path=request.uri.path,method=request.method.rawValue
            func header(_ name:String)->String? { guard let field=HTTPField.Name(name) else{return nil};return request.headers[field] }
            let auth: RequestAuthentication?
            if let device=header("X-StudyRocket-Device"),let timestamp=header("X-StudyRocket-Timestamp").flatMap(Int64.init),let nonce=header("X-StudyRocket-Nonce"),let signature=header("X-StudyRocket-Signature") {
                auth=RequestAuthentication(deviceID:device,timestamp:timestamp,nonce:nonce,signature:signature)
            } else { auth=nil }
            if path == "/v1/pair",method == "POST" { return try response(await store.pair(decode(PairRequest.self,body))) }
            if path == "/v1/health" {
                var authenticated=false
                if auth != nil { _ = try await store.authenticate(auth,method:method,path:path,body:body);authenticated=true }
                return try response(await store.health(modelReady:agent.ready,authenticated:authenticated))
            }
            let device=try await store.authenticate(auth,method:method,path:path,body:body)
            try await store.ensureReady()
            if path == "/v1/events" {
                let after=Int(header("Last-Event-ID") ?? String(request.uri.queryParameters["after"] ?? "0")) ?? 0
                return stream(after:after,device:device)
            }
            switch (method,path) {
            case ("GET","/v1/snapshot"): return try response(await store.snapshot())
            case ("GET","/v1/week"): return try response(await store.snapshot().week)
            case ("GET","/v1/daily"): return try response(await store.snapshot().daily)
            case ("GET","/v1/summaries"): return try response(await store.snapshot().summaries)
            case ("GET","/v1/proposals"): return try response(await store.proposals())
            case ("GET","/v1/proposals/challenge"): return try response(await store.challenge(device:device))
            case ("POST","/v1/proposals/apply"): return dataResponse(try await store.applyProposals(decode(ProposalApplyRequest.self,body),raw:body,device:device))
            case ("GET","/v1/backups/latest"): return try response(await store.latestBackup())
            case ("POST","/v1/backups/read"): return try response(await store.readBackup(decode(CloudBackupReadRequest.self,body)))
            case ("GET","/v1/files/manifest"): return try response(await store.manifest())
            case ("POST","/v1/files/read"): return try response(await store.file(decode(CloudFileReadRequest.self,body).path))
            case ("POST","/v1/files/commit"): return dataResponse(try await store.commitFiles(decode(CloudFileCommitRequest.self,body),raw:body))
            case ("GET","/v1/chat/history"): return try response(await store.chatHistory())
            case ("POST","/v1/chat/send"):
                try await agent.send(decode(SendChatRequest.self,body),raw:body)
                return try response(await store.chatHistory(),status:202)
            case ("POST","/v1/chat/interrupt"):
                try await agent.interrupt();return try response(["ok":true])
            case ("GET","/v1/versions"):
                return try response(await store.versions(after:Int(request.uri.queryParameters["after"] ?? "0") ?? 0,limit:Int(request.uri.queryParameters["limit"] ?? "50") ?? 50))
            case ("POST","/v1/versions/read"): return try response(await store.versionFile(decode(CloudVersionReadRequest.self,body)))
            case ("GET","/v1/history"):
                let after=Int(request.uri.queryParameters["after"] ?? request.uri.queryParameters["cursor"] ?? "0") ?? 0
                let limit=Int(request.uri.queryParameters["limit"] ?? "100") ?? 100
                return try response(await store.history(after:after,limit:limit,query:String(request.uri.queryParameters["query"] ?? "")))
            case ("POST","/v1/history/import"): return dataResponse(try await store.importHistory(decode(CloudHistoryImportRequest.self,body),raw:body))
            case ("POST","/v1/week"),("PUT","/v1/week"),("POST","/v1/daily"),("POST","/v1/facts"),("POST","/v1/deliveries/toggle"),("POST","/v1/periods/toggle"):
                return dataResponse(try await store.writeDomain(path:path,body:body))
            default:
                if method == "GET",path.hasPrefix("/v1/operations/") { return try response(await store.operation(String(path.dropFirst("/v1/operations/".count)))) }
                if method == "GET",path.hasPrefix("/v1/documents/"),let document=await store.document(String(path.dropFirst("/v1/documents/".count))) { return try response(document) }
                throw CloudError(404,"not_found","没有此接口。")
            }
        } catch let error as CloudError { return errorResponse(error) }
        catch let error as AcademicWriteError { return errorResponse(CloudError(error.code == "conflict" ? 409:422,error.code,error.message)) }
        catch let error as PlanningProposalValidation.BoundaryError { return errorResponse(CloudError(422,"invalid_planning_boundaries",error.localizedDescription)) }
        catch is DecodingError { return errorResponse(CloudError(400,"invalid_request","请求 JSON 格式不正确。")) }
        catch { return errorResponse(CloudError(422,"request_failed","操作未完成，请检查内容或刷新后重试。")) }
    }
    func response<T:Encodable>(_ value:T,status:Int=200) throws -> Response { dataResponse(try json(value),status:status) }
    func dataResponse(_ data:Data,status:Int=200)->Response {
        Response(status:.init(code:status),headers:[.contentType:"application/json; charset=utf-8",.cacheControl:"no-store"],body:.init(byteBuffer:ByteBuffer(bytes:data)))
    }
    func errorResponse(_ error:CloudError)->Response {
        let payload=APIErrorBody(code:error.code,message:error.message,retryable:[409,429,503].contains(error.status))
        return dataResponse((try? json(payload)) ?? Data("{}".utf8),status:error.status)
    }
    func stream(after:Int,device:String)->Response {
        Response(status:.ok,headers:[.contentType:"text/event-stream",.cacheControl:"no-cache",HTTPField.Name("X-Accel-Buffering")!:"no"],body:ResponseBody { writer in
            // HTTP graceful shutdown waits for in-flight responses. An SSE body
            // must end itself; the response writer remains on its owning task.
            var cursor=max(after,0),idle=0
            while !Task.isCancelled && !Task.isShuttingDownGracefully {
                guard try await store.deviceActive(device) else { break }
                let events=try await store.events(after:cursor)
                for event in events {
                    guard !Task.isCancelled && !Task.isShuttingDownGracefully else { break }
                    try await writer.write(ByteBuffer(string:"id: \(event.id)\nevent: message\ndata: \(event.body)\n\n"));cursor=event.id
                }
                guard !Task.isCancelled && !Task.isShuttingDownGracefully else { break }
                if events.isEmpty { idle += 1 } else { idle=0 }
                if idle == 1 || idle >= 20 {
                    try await writer.write(ByteBuffer(string:"event: heartbeat\ndata: {\"kind\":\"heartbeat\"}\n\n"));idle=1
                }
                do {
                    // Wake the poll immediately on shutdown without transferring
                    // Hummingbird's non-Sendable, inout writer to a child task.
                    try await cancelWhenGracefulShutdown { try await Task.sleep(for:.seconds(1)) }
                } catch is CancellationError { break }
            }
            try await writer.finish(nil)
        })
    }
}
extension CloudStore {
    func deviceActive(_ id:String) throws -> Bool { !(try db.run("SELECT id FROM devices WHERE id=? AND revoked=0",[.text(id)])).isEmpty }
}

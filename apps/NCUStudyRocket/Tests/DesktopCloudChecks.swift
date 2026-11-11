import Foundation
import StudyRocketShared

private final class CloudFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handle: ((CloudFixtureProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handle?(self) }
    override func stopLoading() {}
    func reply<T: Encodable>(_ value: T, status: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(value)); client?.urlProtocolDidFinishLoading(self)
    }
}

@main struct DesktopCloudChecks {
    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }
    static func main() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-cloud-checks-" + UUID().uuidString)
        let root = fixture.appendingPathComponent("repository"), state = fixture.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("工作台"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let path = "工作台/云测试.md", target = root.appendingPathComponent(path)
        let initial = "# 初始\n", changed = "# 已授权保存\n"
        try Data(initial.utf8).write(to: target)
        let binding = DesktopCloudBinding(endpoint: URL(string: "https://fixture.invalid")!, repositoryID: "stable-fixture")
        try JSONEncoder().encode(binding).write(to: DesktopCloudBinding.marker(root))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CloudFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let workspace = DesktopCloudWorkspace(storageDirectory: state, apiFactory: { DesktopCloudAPI(endpoint: $0, session: session, authentication: { _, _ in }) })
        var serverText = initial, fail = false, conflict = false
        var operationIDs: [String] = []
        let backupPayload = Data(repeating: 65, count: 600_001)
        let backupHash = RequestSigning.bodyHash(backupPayload)
        var corruptBackup = true
        let backupManifest = CloudBackupManifest(id: "fixture-backup-1", createdAt: .now, files: [.init(path: "cloud.sqlite", sha256: backupHash, byteCount: backupPayload.count)])
        func manifest() -> CloudFileManifest { CloudFileManifest(repositoryID: binding.repositoryID, revision: "r1", files: [.init(path: path, hash: RequestSigning.bodyHash(Data(serverText.utf8)), byteCount: serverText.utf8.count)]) }
        CloudFixtureProtocol.handle = { proto in
            if fail { proto.client?.urlProtocol(proto, didFailWithError: URLError(.notConnectedToInternet)); return }
            switch proto.request.url!.path {
            case "/v1/files/manifest": proto.reply(manifest())
            case "/v1/files/read": proto.reply(CloudFileContent(path: path, hash: RequestSigning.bodyHash(Data(serverText.utf8)), content: serverText))
            case "/v1/backups/latest": proto.reply(backupManifest)
            case "/v1/backups/read":
                var bytes = proto.request.httpBody
                if bytes == nil, let stream = proto.request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var collected = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; collected.append(contentsOf: buffer.prefix(count)) }
                    bytes = collected
                }
                let request = try! JSONDecoder().decode(CloudBackupReadRequest.self, from: bytes!)
                let end = min(request.offset + request.limit, backupPayload.count)
                var payload = backupPayload.subdata(in: request.offset..<end)
                if corruptBackup, !payload.isEmpty { payload[0] = 66 }
                proto.reply(CloudBackupFile(backupID: backupManifest.id, path: request.path, sha256: backupHash, base64Data: payload.base64EncodedString(), offset: request.offset, nextOffset: end < backupPayload.count ? end : nil, totalBytes: backupPayload.count))
            case "/v1/files/commit":
                var bytes = proto.request.httpBody
                if bytes == nil, let stream = proto.request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var collected = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; collected.append(contentsOf: buffer.prefix(count)) }
                    bytes = collected
                }
                let commit = try! JSONDecoder().decode(CloudFileCommitRequest.self, from: bytes!)
                operationIDs.append(commit.metadata.idempotencyKey)
                if conflict { proto.reply(APIErrorBody(code: "revision_conflict", message: "版本冲突"), status: 409); return }
                expect(commit.files[0].baseHash == RequestSigning.bodyHash(Data(serverText.utf8)), "CAS must keep the original base hash")
                serverText = commit.files[0].content; proto.reply(manifest())
            default: fatalError("unexpected request")
            }
        }
        try await workspace.synchronize(root: root)
        fail = true
        do { try await workspace.commit(root: root, files: [.init(path: path, baseHash: RequestSigning.bodyHash(Data(initial.utf8)), content: changed)]); fatalError("offline write unexpectedly succeeded") }
        catch { }
        expect(try String(contentsOf: target, encoding: .utf8) == initial, "offline saves must not mutate authoritative mirror")
        let pending = try await workspace.drafts(root: root)
        expect(pending.count == 1 && pending[0].files[0].content == changed, "offline draft persists separately")
        fail = false
        try await workspace.submit(pending[0], root: root)
        expect(try String(contentsOf: target, encoding: .utf8) == changed, "acknowledged cloud write updates mirror")
        expect(operationIDs == [pending[0].id], "retry retains original operation ID")
        let empty = try await workspace.drafts(root: root)
        expect(empty.isEmpty, "successful operation is removed from pending queue")
        try Data("# 外部编辑\n".utf8).write(to: target)
        serverText = "# 云端并行编辑\n"
        try await workspace.synchronize(root: root)
        expect(try String(contentsOf: target, encoding: .utf8) == "# 外部编辑\n", "three-hash synchronization never overwrites dirty working files")
        let authoritativeCache = try await workspace.cachedContent(path: path, root: root)
        expect(authoritativeCache == serverText, "official UI cache remains cloud-authoritative while dirty local file is preserved")
        let external = try await workspace.drafts(root: root)
        expect(external.count == 1 && external[0].files[0].content == "# 外部编辑\n", "external changes are preserved for review")
        conflict = true
        do { try await workspace.submit(external[0], root: root); fatalError("conflict must fail") } catch { }
        expect(try String(contentsOf: target, encoding: .utf8) == "# 外部编辑\n", "CAS conflict preserves working text")
        let preserved = try await workspace.drafts(root: root)
        expect(preserved.count == 1 && preserved[0].id == external[0].id, "CAS conflict retains the operation")
        try await workspace.acceptCloud(path: path, root: root, expectedLocalHash: RequestSigning.bodyHash(Data("# 外部编辑\n".utf8)))
        expect(try String(contentsOf: target, encoding: .utf8) == serverText, "explicit conflict review may adopt cloud text")
        let afterReview = try await workspace.drafts(root: root)
        expect(afterReview.count == 1, "adopting cloud retains original local draft")
        let backupDirectory = fixture.appendingPathComponent("backups", isDirectory: true)
        let downloader = DesktopCloudBackup(directory: backupDirectory, apiFactory: { DesktopCloudAPI(endpoint: $0, session: session, authentication: { _, _ in }) })
        do { _ = try await downloader.synchronize(root: root); fatalError("Corrupt backup must not be published") } catch { }
        let backupScope = backupDirectory.appendingPathComponent(RequestSigning.bodyHash(Data(binding.repositoryID.utf8)))
        expect(!FileManager.default.fileExists(atPath: backupScope.appendingPathComponent(backupManifest.id).path), "Bad checksum never creates a completed backup directory")
        corruptBackup = false
        let backup = try await downloader.synchronize(root: root)!
        expect(try Data(contentsOf: backup.appendingPathComponent("cloud.sqlite")) == backupPayload, "Chunked backup download preserves exact bytes")
        expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("_download-receipt.json").path), "Only fully verified backup receives a completion receipt")
        try Data("corrupted".utf8).write(to: backup.appendingPathComponent("cloud.sqlite"))
        let restarted = DesktopCloudBackup(directory: backupDirectory, apiFactory: { DesktopCloudAPI(endpoint: $0, session: session, authentication: { _, _ in }) })
        let repaired = try await restarted.synchronize(root: root)!
        expect(try Data(contentsOf: repaired.appendingPathComponent("cloud.sqlite")) == backupPayload, "Restart verifies existing backup, redownloads corrupt content")
        expect(try FileManager.default.contentsOfDirectory(atPath: backupScope.path).contains(where: { $0.hasPrefix("unverified-") }), "Old corrupt copy is preserved for audit")
        print("Desktop cloud checks passed: chunked backup verification and repair; offline, acknowledgement, stable operation ID, three-hash conflict, CAS rejection, explicit review")
    }
}

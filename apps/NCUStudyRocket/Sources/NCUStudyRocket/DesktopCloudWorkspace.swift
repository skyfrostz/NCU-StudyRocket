import Foundation
import CryptoKit
import Security
import SwiftUI
import StudyRocketShared

struct DesktopCloudBinding: Codable, Equatable {
    var version = 1
    var mode = "cloud"
    let endpoint: URL
    let repositoryID: String
    static func marker(_ root: URL) -> URL { root.appendingPathComponent(".studyrocket-cloud.json") }
    static func isManaged(_ root: URL) -> Bool { FileManager.default.fileExists(atPath: marker(root).path) }
    static func cacheRoot(_ root: URL) throws -> URL {
        let binding = try read(root)
        let key = RequestSigning.bodyHash(Data((root.standardizedFileURL.path + "|" + binding.repositoryID).utf8))
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NCU StudyRocket/Cloud/" + key + "/mirror", isDirectory: true)
    }
    static func read(_ root: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: marker(root)))
        guard value.version == 1, value.mode == "cloud", !value.repositoryID.isEmpty,
              value.endpoint.scheme == "https", value.endpoint.host != nil,
              value.endpoint.user == nil, value.endpoint.password == nil,
              value.endpoint.query == nil, value.endpoint.fragment == nil,
              value.endpoint.path.isEmpty || value.endpoint.path == "/" else {
            throw DesktopCloudError.message("云绑定配置无效；为保护数据，已阻止本地写入。")
        }
        return value
    }
}

enum DesktopCloudError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): value } }
}

/// The same P-256 request contract as Mobile; no model credentials are stored here.
final class DesktopCloudIdentity: @unchecked Sendable {
    private static let lock = NSLock()
    private let service = "com.skyfrost.ncustudyrocket.cloud"
    func key() throws -> P256.Signing.PrivateKey {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "device-signing-key"]
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { _, n in n } as CFDictionary, &found)
        if status == errSecSuccess, let bytes = found as? Data { return try P256.Signing.PrivateKey(rawRepresentation: bytes) }
        guard status == errSecItemNotFound else { throw DesktopCloudError.message("无法读取设备安全密钥；现有身份已保留。") }
        let key = P256.Signing.PrivateKey()
        let result = SecItemAdd(query.merging([kSecValueData as String: key.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { _, n in n } as CFDictionary, nil)
        guard result == errSecSuccess else { throw DesktopCloudError.message("无法安全保存设备密钥。") }
        return key
    }
    static func deviceKey(_ endpoint: URL) -> String { "studyrocket.cloud.device." + RequestSigning.bodyHash(Data(endpoint.absoluteString.utf8)) }
    func authenticate(_ request: inout URLRequest, endpoint: URL) throws {
        guard let device = UserDefaults.standard.string(forKey: Self.deviceKey(endpoint)) else { throw DesktopCloudError.message("请先在设置中配对云服务。") }
        let timestamp = Int64(Date().timeIntervalSince1970), nonce = UUID().uuidString
        let signature = try RequestSigning.sign(privateKey: key(), method: request.httpMethod ?? "GET", path: request.url?.path ?? "/",
            timestamp: timestamp, nonce: nonce, bodyHash: RequestSigning.bodyHash(request.httpBody ?? Data()))
        request.setValue(device, forHTTPHeaderField: "X-StudyRocket-Device")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-StudyRocket-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-StudyRocket-Nonce")
        request.setValue(signature, forHTTPHeaderField: "X-StudyRocket-Signature")
    }
}

actor DesktopCloudAPI {
    let endpoint: URL
    private let identity = DesktopCloudIdentity()
    private let session: URLSession
    private let authentication: @Sendable (inout URLRequest, URL) throws -> Void
    init(endpoint: URL, session: URLSession = .shared,
         authentication: @escaping @Sendable (inout URLRequest, URL) throws -> Void = { request, endpoint in try DesktopCloudIdentity().authenticate(&request, endpoint: endpoint) }) {
        self.endpoint = endpoint; self.session = session; self.authentication = authentication
    }
    func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        try await request(path, body: nil, as: T.self)
    }
    func post<B: Encodable, T: Decodable>(_ path: String, body: B, as: T.Type) async throws -> T {
        try await request(path, body: JSONEncoder().encode(body), as: T.self)
    }
    private func request<T: Decodable>(_ path: String, body: Data?, as: T.Type) async throws -> T {
        var request = URLRequest(url: URL(string: path, relativeTo: endpoint)!.absoluteURL)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body; request.timeoutInterval = 30
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if path != "/v1/pair" { try authentication(&request, endpoint) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode(APIErrorBody.self, from: data)
            throw DesktopCloudError.message(error?.message ?? "云服务暂时不可用；本机草稿已保留。")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func pair(code: String) async throws -> PairResponse {
        let response: PairResponse = try await post("/v1/pair", body: PairRequest(code: code, deviceName: "StudyRocket Mac", publicKey: identity.key().publicKey.rawRepresentation.base64EncodedString()), as: PairResponse.self)
        guard response.apiVersion == StudyRocketAPI.version else { throw DesktopCloudError.message("云服务协议版本不兼容。") }
        UserDefaults.standard.set(response.deviceID, forKey: DesktopCloudIdentity.deviceKey(endpoint))
        return response
    }
    func authorizeProposals() async throws -> String {
        let challenge: ProposalAuthorizationChallenge = try await get("/v1/proposals/challenge", as: ProposalAuthorizationChallenge.self)
        return challenge.challenge + "|" + (try RequestSigning.signAuthorization(privateKey: identity.key(), challenge: challenge.challenge))
    }
}

struct DesktopCloudDraft: Codable, Identifiable {
    let id: String
    let createdAt: Date
    let repositoryID: String
    let endpoint: URL
    let revision: String
    let files: [CloudFileChange]
    var fact: QuickFact? = nil
    var message: String
}

/// Network writes and local mirrors are separate. A failed request never writes
/// academic files; every submitted operation is first saved outside the repository.
actor DesktopCloudWorkspace {
    static let shared = DesktopCloudWorkspace()
    private let storageDirectory: URL
    private let apiFactory: @Sendable (URL) -> DesktopCloudAPI
    init(storageDirectory: URL? = nil, apiFactory: @escaping @Sendable (URL) -> DesktopCloudAPI = { DesktopCloudAPI(endpoint: $0) }) {
        self.storageDirectory = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NCU StudyRocket/Cloud", isDirectory: true)
        self.apiFactory = apiFactory
    }
    private var busyRoots = Set<String>()
    private struct Baseline: Codable { var hashes: [String: String] = [:]; var revision = "" }
    private func directory(_ root: URL, binding: DesktopCloudBinding) -> URL {
        let key = RequestSigning.bodyHash(Data((root.standardizedFileURL.path + "|" + binding.repositoryID).utf8))
        return storageDirectory.appendingPathComponent(key, isDirectory: true)
    }
    private func cacheURL(_ path: String, root: URL, binding: DesktopCloudBinding) -> URL {
        directory(root, binding: binding).appendingPathComponent("mirror", isDirectory: true).appendingPathComponent(path)
    }
    private func writeCache(_ content: Data, path: String, root: URL, binding: DesktopCloudBinding) throws {
        let url = cacheURL(path, root: root, binding: binding)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, options: .atomic)
    }
    func cachedContent(path: String, root: URL) throws -> String {
        let binding = try DesktopCloudBinding.read(root)
        return try String(contentsOf: cacheURL(path, root: root, binding: binding), encoding: .utf8)
    }
    private func baseline(_ root: URL, binding: DesktopCloudBinding) -> Baseline {
        (try? JSONDecoder().decode(Baseline.self, from: Data(contentsOf: directory(root, binding: binding).appendingPathComponent("baseline.json")))) ?? Baseline()
    }
    private func draftDirectory(_ binding: DesktopCloudBinding) -> URL {
        storageDirectory.appendingPathComponent("drafts-" + RequestSigning.bodyHash(Data(binding.repositoryID.utf8)), isDirectory: true)
    }
    private func persist(_ draft: DesktopCloudDraft, root: URL, binding: DesktopCloudBinding) throws {
        let dir = draftDirectory(binding)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(draft), url = dir.appendingPathComponent(draft.id + ".json")
        try data.write(to: url, options: .atomic)
        guard try Data(contentsOf: url) == data else { throw CocoaError(.fileWriteUnknown) }
        Task { @MainActor in NotificationCenter.default.post(name: .studyRocketCloudStateChanged, object: nil) }
    }
    private func remove(_ id: String, root: URL, binding: DesktopCloudBinding) throws {
        try FileManager.default.removeItem(at: draftDirectory(binding).appendingPathComponent(id + ".json"))
    }
    func drafts(root: URL, includeOtherRepositories: Bool = false) throws -> [DesktopCloudDraft] {
        let binding = try DesktopCloudBinding.read(root)
        let directories: [URL]
        if includeOtherRepositories {
            directories = ((try? FileManager.default.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("drafts-") }
        } else { directories = [draftDirectory(binding)] }
        return directories.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .compactMap { try? JSONDecoder().decode(DesktopCloudDraft.self, from: Data(contentsOf: $0)) }.sorted { $0.createdAt < $1.createdAt }
    }
    private func target(_ path: String, root: URL) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), path.hasSuffix(".md"),
              url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw MarkdownError.outsideWorkspace }
        return url
    }
    private func requireSame(_ root: URL, _ binding: DesktopCloudBinding) throws {
        guard try DesktopCloudBinding.read(root) == binding else { throw DesktopCloudError.message("云仓库已切换，本次旧连接结果未写入本机。") }
    }
    func commit(root: URL, files: [CloudFileChange]) async throws {
        let binding = try DesktopCloudBinding.read(root), base = baseline(root, binding: binding)
        for file in files { _ = try target(file.path, root: root) }
        if let existing = try drafts(root: root).first(where: { $0.files == files && $0.fact == nil && !$0.id.hasPrefix("external-") }) {
            try await submit(existing, root: root)
            return
        }
        let draft = DesktopCloudDraft(id: UUID().uuidString, createdAt: .now, repositoryID: binding.repositoryID,
            endpoint: binding.endpoint, revision: base.revision, files: files, message: "已存本机草稿，等待云服务回执")
        try persist(draft, root: root, binding: binding)
        for file in files {
            let current = try? Data(contentsOf: cacheURL(file.path, root: root, binding: binding))
            if let hash = file.baseHash, RequestSigning.bodyHash(current ?? Data()) != hash {
                var conflict = draft; conflict.message = "本机文件已在编辑期间变化；保存内容已独立保留，请核对差异。"
                try persist(conflict, root: root, binding: binding)
                throw DesktopCloudError.message(conflict.message)
            }
        }
        try await submit(draft, root: root)
    }
    func appendFact(_ fact: QuickFact, root: URL) async throws {
        let binding = try DesktopCloudBinding.read(root), base = baseline(root, binding: binding)
        let draft = DesktopCloudDraft(id: fact.id.uuidString, createdAt: .now, repositoryID: binding.repositoryID,
            endpoint: binding.endpoint, revision: base.revision, files: [], fact: fact, message: "记录已存本机草稿，等待云服务回执")
        try persist(draft, root: root, binding: binding)
        try await submit(draft, root: root)
    }
    func submit(_ draft: DesktopCloudDraft, root: URL) async throws {
        let binding = try DesktopCloudBinding.read(root)
        guard draft.repositoryID == binding.repositoryID else { throw DesktopCloudError.message("草稿属于其他服务或仓库，不能直接提交。") }
        guard busyRoots.insert(root.path).inserted else { throw DesktopCloudError.message("云同步正在进行；草稿已保留，请稍后重试。") }
        let api = apiFactory(binding.endpoint)
        do {
            if let fact = draft.fact {
                let _: SnapshotResponse = try await api.post("/v1/facts", body: FactWriteRequest(entry: fact,
                    metadata: WriteMetadata(baseRevision: draft.revision, idempotencyKey: draft.id), repositoryID: binding.repositoryID), as: SnapshotResponse.self)
            } else {
                let _: CloudFileManifest = try await api.post("/v1/files/commit", body: CloudFileCommitRequest(repositoryID: binding.repositoryID,
                    metadata: WriteMetadata(baseRevision: draft.revision, idempotencyKey: draft.id), files: draft.files), as: CloudFileManifest.self)
            }
            try requireSame(root, binding)
            // The explicit saved content is now authoritative. Only replace the local
            // version if it is still the user's original input; external edits survive.
            var base = baseline(root, binding: binding)
            for file in draft.files {
                let url = try target(file.path, root: root), old = try? Data(contentsOf: url)
                let authoritative: CloudFileContent = try await api.post("/v1/files/read", body: CloudFileReadRequest(path: file.path), as: CloudFileContent.self)
                try requireSame(root, binding)
                guard authoritative.path == file.path, RequestSigning.bodyHash(Data(authoritative.content.utf8)) == authoritative.hash else { throw DesktopCloudError.message("云文件校验失败，已保留草稿。") }
                try writeCache(Data(authoritative.content.utf8), path: file.path, root: root, binding: binding)
                if (RequestSigning.bodyHash(old ?? Data()) == file.baseHash || old == nil && file.baseHash == nil), (try? Data(contentsOf: url)) == old {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(authoritative.content.utf8).write(to: url, options: .atomic)
                    base.hashes[file.path] = authoritative.hash
                }
            }
            try saveBaseline(base, root: root, binding: binding)
            try remove(draft.id, root: root, binding: binding)
            busyRoots.remove(root.path)
            try await synchronize(root: root)
        } catch {
            busyRoots.remove(root.path)
            // Preserve the original operation ID and revision even when the server may
            // have committed. A retry is idempotent; never refresh its CAS baseline.
            var saved = draft; saved.message = error.localizedDescription
            try? persist(saved, root: root, binding: binding)
            throw DesktopCloudError.message("云保存未完成：\(error.localizedDescription) 本机独立草稿已保留，可在设置查看与重试。")
        }
    }
    private func saveBaseline(_ value: Baseline, root: URL, binding: DesktopCloudBinding) throws {
        let dir = directory(root, binding: binding)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: dir.appendingPathComponent("baseline.json"), options: .atomic)
    }
    func synchronize(root: URL) async throws {
        let binding = try DesktopCloudBinding.read(root)
        guard busyRoots.insert(root.path).inserted else { return }
        defer { busyRoots.remove(root.path) }
        let api = apiFactory(binding.endpoint)
        let manifest: CloudFileManifest = try await api.get("/v1/files/manifest", as: CloudFileManifest.self)
        guard manifest.repositoryID == binding.repositoryID else { throw DesktopCloudError.message("云仓库身份已变化，请重新配对；本机文件未覆盖。") }
        var base = baseline(root, binding: binding)
        for file in manifest.files {
            try Task.checkCancellation(); try requireSame(root, binding)
            let url = try target(file.path, root: root), local = try? Data(contentsOf: url)
            let localHash = local.map(RequestSigning.bodyHash)
            if localHash == file.hash, let local {
                try writeCache(local, path: file.path, root: root, binding: binding)
                base.hashes[file.path] = file.hash; continue
            }
            let dirty = local != nil && localHash != base.hashes[file.path]
            if let local, localHash != base.hashes[file.path], let content = String(data: local, encoding: .utf8) {
                // Hash-derived IDs avoid duplicate drafts on each periodic refresh.
                let draft = DesktopCloudDraft(id: "external-" + RequestSigning.bodyHash(Data((binding.repositoryID + "|" + file.path + (localHash ?? "")).utf8)),
                    createdAt: .now, repositoryID: binding.repositoryID, endpoint: binding.endpoint,
                    revision: base.revision, files: [CloudFileChange(path: file.path, baseHash: base.hashes[file.path], content: content)],
                    message: "发现本机外部修改。原文已保留；请比较云版本后逐项处理。")
                try persist(draft, root: root, binding: binding)
                // Do not overwrite a dirty working file. Official UI reads the
                // separate authoritative cache; this original remains reviewable.
            }
            let cloud: CloudFileContent = try await api.post("/v1/files/read", body: CloudFileReadRequest(path: file.path), as: CloudFileContent.self)
            guard cloud.path == file.path, cloud.hash == file.hash,
                  RequestSigning.bodyHash(Data(cloud.content.utf8)) == cloud.hash else { throw DesktopCloudError.message("云文件在同步期间发生变化，请刷新重试。") }
            try requireSame(root, binding)
            try writeCache(Data(cloud.content.utf8), path: file.path, root: root, binding: binding)
            guard !dirty, (try? Data(contentsOf: url)) == local else { continue }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(cloud.content.utf8).write(to: url, options: .atomic)
            base.hashes[file.path] = cloud.hash
            try saveBaseline(base, root: root, binding: binding)
        }
        try pruneCache(root: root, binding: binding, authoritativePaths: Set(manifest.files.map(\.path)))
        base.revision = manifest.revision
        try saveBaseline(base, root: root, binding: binding)
        await MainActor.run { NotificationCenter.default.post(name: .studyRocketWorkspaceChanged, object: nil) }
    }
    private func pruneCache(root: URL, binding: DesktopCloudBinding, authoritativePaths: Set<String>) throws {
        let mirror = directory(root, binding: binding).appendingPathComponent("mirror", isDirectory: true).resolvingSymlinksInPath()
        guard let files = FileManager.default.enumerator(at: mirror, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in files where url.pathExtension == "md" {
            let canonical = url.resolvingSymlinksInPath()
            guard canonical.path.hasPrefix(mirror.path + "/") else { continue }
            let relative = String(canonical.path.dropFirst(mirror.path.count + 1))
            if !authoritativePaths.contains(relative) { try FileManager.default.removeItem(at: canonical) }
        }
    }

    func cloudContent(path: String, root: URL) async throws -> CloudFileContent {
        let binding = try DesktopCloudBinding.read(root)
        return try await apiFactory(binding.endpoint).post("/v1/files/read", body: CloudFileReadRequest(path: path), as: CloudFileContent.self)
    }
    /// User explicitly chose the cloud version, after reviewing both texts.
    func acceptCloud(path: String, root: URL, expectedLocalHash: String, expectedCloudHash: String? = nil) async throws {
        let binding = try DesktopCloudBinding.read(root), cloud = try await cloudContent(path: path, root: root)
        try requireSame(root, binding)
        if let expectedCloudHash, expectedCloudHash != cloud.hash { throw DesktopCloudError.message("云版本已更新，请重新查看差异后确认。") }
        let url = try target(path, root: root)
        guard RequestSigning.bodyHash((try? Data(contentsOf: url)) ?? Data()) == expectedLocalHash else { throw MarkdownError.conflict }
        try Data(cloud.content.utf8).write(to: url, options: .atomic)
        try writeCache(Data(cloud.content.utf8), path: path, root: root, binding: binding)
        var base = baseline(root, binding: binding); base.hashes[path] = cloud.hash
        try saveBaseline(base, root: root, binding: binding)
        await MainActor.run { NotificationCenter.default.post(name: .studyRocketWorkspaceChanged, object: nil) }
    }
}

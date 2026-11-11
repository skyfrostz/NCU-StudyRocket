import Foundation
import CryptoKit
import SwiftUI
import StudyRocketShared

@MainActor final class DesktopCloudBackupStatus: ObservableObject {
    static let shared = DesktopCloudBackupStatus()
    @Published var message = "尚未下载并校验云端一致备份"
    @Published var location: URL?
    @Published var repositoryID: String?
}

/// Downloads a server-created, transaction-consistent backup, never a live SQLite
/// file. Chunks stay bounded; only a fully verified directory becomes a backup.
actor DesktopCloudBackup {
    static let shared = DesktopCloudBackup()
    private let directory: URL
    private let apiFactory: @Sendable (URL) -> DesktopCloudAPI
    private var active = Set<String>()
    private var verified: [String: String] = [:]
    init(directory: URL? = nil, apiFactory: @escaping @Sendable (URL) -> DesktopCloudAPI = { DesktopCloudAPI(endpoint: $0) }) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NCU StudyRocket/CloudBackups", isDirectory: true)
        self.apiFactory = apiFactory
    }
    func synchronize(root: URL) async throws -> URL? {
        let binding = try DesktopCloudBinding.read(root)
        let scope = RequestSigning.bodyHash(Data(binding.repositoryID.utf8))
        guard active.insert(scope).inserted else { return nil }
        defer { active.remove(scope) }
        let api = apiFactory(binding.endpoint)
        let manifest: CloudBackupManifest = try await api.get("/v1/backups/latest", as: CloudBackupManifest.self)
        guard !manifest.id.isEmpty, manifest.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              !manifest.files.isEmpty, Set(manifest.files.map(\.path)).count == manifest.files.count else { throw DesktopCloudError.message("云备份清单无效，未创建本机备份。") }
        let manifestEncoder = JSONEncoder(); manifestEncoder.outputFormatting = [.sortedKeys]
        let manifestSignature = RequestSigning.bodyHash(try manifestEncoder.encode(manifest))
        let parent = directory.appendingPathComponent(scope, isDirectory: true)
        let final = parent.appendingPathComponent(manifest.id, isDirectory: true)
        if verified[scope] == manifestSignature, FileManager.default.fileExists(atPath: final.appendingPathComponent("_download-receipt.json").path) { return final }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? Data(contentsOf: final.appendingPathComponent("_download-receipt.json")),
           let existing = try? JSONDecoder().decode(CloudBackupManifest.self, from: data),
           existing.id == manifest.id, try verify(manifest, at: final) {
            verified[scope] = manifestSignature
            return final
        }
        let temporary = parent.appendingPathComponent(".incoming-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for entry in manifest.files {
                try Task.checkCancellation()
                guard try DesktopCloudBinding.read(root) == binding else { throw DesktopCloudError.message("备份期间云绑定已变化，未发布本机备份。") }
                let target = try validated(entry.path, under: temporary)
                guard entry.byteCount >= 0 else { throw DesktopCloudError.message("云备份长度无效。") }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                let handle = try FileHandle(forWritingTo: target)
                do {
                    var offset = 0
                    var hash = SHA256()
                    repeat {
                        let chunk: CloudBackupFile = try await api.post("/v1/backups/read", body: CloudBackupReadRequest(backupID: manifest.id, path: entry.path, offset: offset, limit: 262_144), as: CloudBackupFile.self)
                        guard chunk.backupID == manifest.id, chunk.path == entry.path, chunk.sha256 == entry.sha256,
                              chunk.offset == offset, chunk.totalBytes == entry.byteCount,
                              let bytes = Data(base64Encoded: chunk.base64Data), bytes.count <= 262_144,
                              offset + bytes.count <= entry.byteCount,
                              chunk.nextOffset == (offset + bytes.count < entry.byteCount ? offset + bytes.count : nil),
                              !bytes.isEmpty || entry.byteCount == 0 else { throw DesktopCloudError.message("云备份分块校验失败，已拒绝不完整备份。") }
                        try handle.write(contentsOf: bytes); hash.update(data: bytes); offset += bytes.count
                        if chunk.nextOffset == nil { break }
                    } while true
                    try handle.synchronize()
                    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                    guard offset == entry.byteCount, digest == entry.sha256 else { throw DesktopCloudError.message("云备份 SHA-256 或长度校验失败。") }
                    try handle.close()
                } catch { try? handle.close(); throw error }
            }
            guard try DesktopCloudBinding.read(root) == binding else { throw DesktopCloudError.message("备份期间云绑定已变化，未发布本机备份。") }
            try JSONEncoder().encode(manifest).write(to: temporary.appendingPathComponent("_download-receipt.json"), options: .atomic)
            if FileManager.default.fileExists(atPath: final.path) {
                // Preserve an older incomplete/corrupt copy for audit, never clobber it.
                try FileManager.default.moveItem(at: final, to: parent.appendingPathComponent("unverified-" + manifest.id + "-" + UUID().uuidString))
            }
            try FileManager.default.moveItem(at: temporary, to: final)
            verified[scope] = manifestSignature
            return final
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
    private func validated(_ path: String, under root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.contains("\\"), !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              path != "_download-receipt.json" else { throw DesktopCloudError.message("备份路径无效。") }
        let target = root.appendingPathComponent(path).standardizedFileURL
        guard target.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw DesktopCloudError.message("备份路径越界。") }
        return target
    }
    private func verify(_ manifest: CloudBackupManifest, at root: URL) throws -> Bool {
        for entry in manifest.files {
            let file = try validated(entry.path, under: root)
            guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
            defer { try? handle.close() }
            var hash = SHA256(), count = 0
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { count += bytes.count; hash.update(data: bytes) }
            if count != entry.byteCount || hash.finalize().map({ String(format: "%02x", $0) }).joined() != entry.sha256 { return false }
        }
        return true
    }
    func refreshAutomatically(root: URL) async {
        let repositoryID = try? DesktopCloudBinding.read(root).repositoryID
        do {
            if let location = try await synchronize(root: root) {
                await MainActor.run { DesktopCloudBackupStatus.shared.repositoryID = repositoryID; DesktopCloudBackupStatus.shared.location = location; DesktopCloudBackupStatus.shared.message = "最新一致备份已下载并通过 SHA-256 校验" }
            }
        } catch {
            await MainActor.run { DesktopCloudBackupStatus.shared.repositoryID = repositoryID; DesktopCloudBackupStatus.shared.location = nil; DesktopCloudBackupStatus.shared.message = "一致备份尚未更新：" + error.localizedDescription }
        }
    }
}

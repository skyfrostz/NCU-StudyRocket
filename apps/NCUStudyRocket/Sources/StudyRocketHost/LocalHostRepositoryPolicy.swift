import Foundation

/// A cloud-bound checkout is a mirror, never another authoritative writer.
/// Treat an unreadable binding as managed until the user repairs or explicitly
/// removes it; a partial configuration write must not re-enable the old Host.
enum LocalHostRepositoryPolicy {
    static func requiresCloud(_ root: URL) -> Bool {
        let marker = root.appendingPathComponent(".studyrocket-cloud.json")
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }
        guard let data = try? Data(contentsOf: marker),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mode = value["mode"] as? String else { return true }
        return mode != "legacy"
    }

    static func ensureLocalWritesAllowed(_ root: URL) throws {
        guard !requiresCloud(root) else {
            throw HostWriteError(code: "cloud_repository", message: "此仓库已由云端管理，请通过 StudyRocket 云端连接保存。Mac Host 不再接受写入。")
        }
    }
}

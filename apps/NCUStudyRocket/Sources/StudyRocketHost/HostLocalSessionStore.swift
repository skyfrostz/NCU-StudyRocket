import Foundation
import StudyRocketShared

final class HostLocalSessionStore {
    private let fileManager: FileManager
    private let url: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        url = StudyRocketLocalSession.tokenURL(fileManager: fileManager)
    }

    func issue() throws -> String {
        let token = "\(UUID().uuidString).\(UUID().uuidString)"
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(token.utf8).write(to: url, options: .atomic)
        do {
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
        return token
    }

    func read() -> String? {
        guard let data = try? Data(contentsOf: url),
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clear() {
        try? fileManager.removeItem(at: url)
    }
}

import Foundation

/// Bundled CLI layouts change across desktop updates. Resolve when connecting
/// so an update does not leave a running StudyRocket with a stale path.
public enum StudyRocketCodexExecutable {
    public static func resolve(
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        for app in ["Codex", "ChatGPT"] {
            let resources = "/Applications/\(app).app/Contents/Resources"
            for path in [
                "\(resources)/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "\(resources)/codex"
            ] where isExecutable(path) {
                return path
            }
        }
        return nil
    }
}

import Foundation

/// Debug-only process configuration for an isolated StudyRocket self-check.
/// Release builds always return `nil`, even when the command-line flags are
/// present, so production behavior cannot be redirected by these arguments.
public struct StudyRocketSelfCheckConfiguration: Equatable, Sendable {
    public static let trigger = "--studyrocket-self-check"
    public static let deviceRuntimeTrigger = "--self-check-device-runtime"

    public let repositoryRoot: URL
    public let stateDirectory: URL
    public let port: UInt16
    public let runID: String
    public let disablesCodex: Bool

    public var pairingKeychainService: String {
        "com.skyfrost.ncustudyrocket.host.self-check.\(runID)"
    }

    public let pairingKeychainAccount = "paired-devices"

    /// All self-check backup writes stay beneath the caller-provided state
    /// directory rather than the production Application Support location.
    public var backupDirectory: URL {
        stateDirectory.appendingPathComponent("Backups", isDirectory: true)
    }

    /// The Desktop app shares its production bundle identifier with Debug, so
    /// its weekly-plan display preferences need a separate defaults domain.
    public var desktopPreferencesSuite: String {
        "com.skyfrost.ncustudyrocket.desktop.self-check.\(runID)"
    }

    public var localSessionURL: URL {
        stateDirectory.appendingPathComponent("host-local-session")
    }

    public var codexLeaseURL: URL {
        stateDirectory.appendingPathComponent("codex-owner.json")
    }

    public var taskDescriptorDirectory: URL {
        stateDirectory.appendingPathComponent("Academic Tasks", isDirectory: true)
    }

    public var proposalBackupDirectory: URL {
        backupDirectory
    }

    public var pairingCodeURL: URL {
        stateDirectory.appendingPathComponent("pairing-code")
    }

    public static var current: StudyRocketSelfCheckConfiguration? {
        #if DEBUG
        return configuration(from: CommandLine.arguments)
        #else
        return nil
        #endif
    }

    /// Returns the explicitly requested isolated port, or the default
    /// isolated port when no override is supplied. The production Host port
    /// is never valid for self-check traffic.
    public static func isolatedPort(from arguments: [String]) -> UInt16? {
        let deviceRuntimeRequested = arguments.contains(deviceRuntimeTrigger)
        guard arguments.contains("--self-check-port") else {
            return deviceRuntimeRequested ? nil : 43818
        }
        guard let rawPort = singleValue(for: "--self-check-port", in: arguments) else {
            return nil
        }
        guard let value = UInt16(rawPort),
              value >= 1024 else {
            return nil
        }
        if value == StudyRocketAPI.defaultHostPort {
            return deviceRuntimeRequested ? value : nil
        }
        guard !deviceRuntimeRequested else { return nil }
        return value
    }

    /// Parses a Debug self-check configuration. Release builds always return
    /// nil so command-line flags cannot redirect production behavior.
    public static func configuration(from arguments: [String]) -> StudyRocketSelfCheckConfiguration? {
        #if DEBUG
        return parseDebugConfiguration(arguments: arguments)
        #else
        return nil
        #endif
    }

    private static func parseDebugConfiguration(arguments: [String]) -> StudyRocketSelfCheckConfiguration? {
        guard arguments.contains(trigger),
              let rootValue = singleValue(for: "--self-check-root", in: arguments),
              let stateValue = singleValue(for: "--self-check-state", in: arguments),
              let rawRunID = singleValue(for: "--self-check-run-id", in: arguments),
              let parsedRunID = UUID(uuidString: rawRunID) else {
            return nil
        }

        let fileManager = FileManager.default
        let requestedRoot = URL(fileURLWithPath: rootValue, isDirectory: true).standardizedFileURL
        let requestedState = URL(fileURLWithPath: stateValue, isDirectory: true).standardizedFileURL
        guard rootValue.hasPrefix("/"),
              stateValue.hasPrefix("/"),
              isExistingDirectory(requestedRoot, fileManager: fileManager),
              isExistingDirectory(requestedState, fileManager: fileManager) else {
            return nil
        }

        let root = requestedRoot.resolvingSymlinksInPath()
        let state = requestedState.resolvingSymlinksInPath()
        let temporaryDirectory = fileManager.temporaryDirectory.resolvingSymlinksInPath()
        guard root.path != "/",
              state.path != "/",
              root != state,
              isSameOrDescendant(root, of: temporaryDirectory),
              isSameOrDescendant(state, of: temporaryDirectory),
              !isSameOrDescendant(root, of: state),
              !isSameOrDescendant(state, of: root),
              !isProtectedProductionPath(root),
              !isProtectedProductionPath(state) else {
            return nil
        }

        guard let port = isolatedPort(from: arguments) else { return nil }

        return StudyRocketSelfCheckConfiguration(
            repositoryRoot: root,
            stateDirectory: state,
            port: port,
            runID: parsedRunID.uuidString.lowercased(),
            disablesCodex: arguments.contains("--self-check-no-codex")
        )
    }

    private static func isExistingDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func isSameOrDescendant(_ candidate: URL, of base: URL) -> Bool {
        candidate.path == base.path || candidate.path.hasPrefix(base.path + "/")
    }

    private static func isProtectedProductionPath(_ candidate: URL) -> Bool {
        let productionRepository = URL(fileURLWithPath: "/Users/skyfrost/Desktop/大学", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let productionState = StudyRocketLocalSession.tokenURL()
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let productionApplicationSupport = productionState
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()

        return [productionRepository, productionState, productionApplicationSupport].contains {
            isSameOrDescendant(candidate, of: $0)
        }
    }

    private static func singleValue(for option: String, in arguments: [String]) -> String? {
        var values: [String] = []
        for index in arguments.indices where arguments[index] == option {
            let next = arguments.index(after: index)
            guard next < arguments.endIndex,
                  !arguments[next].hasPrefix("--") else {
                return nil
            }
            values.append(arguments[next])
        }
        guard values.count == 1, let value = values.first, !value.isEmpty else { return nil }
        return value
    }
}

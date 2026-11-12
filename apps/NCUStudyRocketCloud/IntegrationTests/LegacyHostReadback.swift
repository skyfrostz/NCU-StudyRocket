import Foundation
import StudyRocketShared

// Compile alongside the actual HostSnapshotBuilder.swift. This executable only
// runs the production snapshot projection; it never launches a Host or Codex.
@main
struct LegacyHostReadback {
    enum FixtureError: Error { case invalidArguments, missingTask }

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2 else { throw FixtureError.invalidArguments }
        if arguments[0] == "--task-id" {
            guard let task = PeriodTaskParser.tasks(from: arguments[1]).first else {
                throw FixtureError.missingTask
            }
            print(task.id)
            return
        }
        let root = URL(fileURLWithPath: arguments[0], isDirectory: true)
        let snapshot = HostSnapshotBuilder(root: root).build()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(
            to: URL(fileURLWithPath: arguments[1]), options: .atomic
        )
    }
}

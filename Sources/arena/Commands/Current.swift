import ArgumentParser
import Foundation

/// `arena @` — the lane the shell is standing in, with no name to type.
///
/// Shorthand for `arena <that lane>` rather than for `arena enter`, so it does whatever
/// naming the lane would do: hop into the sandbox if one is running, launch it if not.
/// `arena enter` stays attach-only, for when starting a sandbox is not what was meant.
///
/// Every other flag is handed to `new` untouched, so `arena @ --rebuild` and
/// `arena @ --herdr` work without this command knowing what those are.
struct Current: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "@",
        abstract: "Launch or join the sandbox for the lane the working directory is in."
    )

    @Argument(
        parsing: .captureForPassthrough,
        help: ArgumentHelp("Flags for `new`.", valueName: "new options"))
    var passthrough: [String] = []

    func run() async throws {
        let repository = Repository.discover()
        try repository.requireGit()
        let lane = try repository.currentLane()
        var command = try New.parse([lane.name] + passthrough)
        try await command.run()
    }
}

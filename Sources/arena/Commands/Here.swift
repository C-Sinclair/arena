import ArgumentParser
import Foundation

/// `arena .` — a sandbox against the worktree the shell is in, with no lane.
///
/// For repositories that are never laned, such as dotfiles, and for directories git does
/// not track at all, which this is the only command to accept (ADR-008). The worktree is
/// whatever `git rev-parse --show-toplevel` says, or the directory itself when that fails,
/// and the container id is its directory name. `lane` is never called and `--base` and
/// `--dirty` mean nothing here.
///
/// Every other flag is parsed by `new`, so the two cannot drift on what they accept.
struct Here: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: ".",
        abstract: "Launch or join a sandbox for the worktree the shell is in, without a lane."
    )

    @Argument(
        parsing: .captureForPassthrough,
        help: ArgumentHelp("Flags for `new`.", valueName: "new options"))
    var passthrough: [String] = []

    static func sandboxID(_ toplevel: URL) -> String {
        toplevel.standardizedFileURL.lastPathComponent.asContainerID()
    }

    func run() async throws {
        let options = try New.parse(["."] + passthrough)
        guard options.base == nil, !options.dirty else {
            throw ValidationError("--base and --dirty cut a lane; `arena .` does not cut one.")
        }

        let repository = Repository.discover()
        let worktree = Repository.hereWorktree()
        let sandbox = Self.sandboxID(worktree)

        try New.clearSandbox(named: sandbox, lane: ".", workdir: worktree)
        try options.launch(sandbox: sandbox, worktree: worktree, repository: repository)
    }
}

import ArgumentParser
import Foundation

/// `arena .` — a sandbox against the worktree the shell is in, with no lane.
///
/// For repositories that are never laned, such as dotfiles. The worktree is whatever
/// `git rev-parse --show-toplevel` says and the container id is its directory name, so
/// `lane` is never called and `--base` and `--dirty` mean nothing here.
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

        let repository = try Repository.discover()
        let worktree = try Repository.toplevel()
        let sandbox = Self.sandboxID(worktree)

        try New.clearSandbox(named: sandbox, lane: ".", workdir: worktree)
        try options.launch(sandbox: sandbox, worktree: worktree, repository: repository)
    }
}

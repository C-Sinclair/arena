import ArgumentParser
import Foundation

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Stop the sandbox, then delete the lane and its branch.",
        aliases: ["rm"]
    )

    @Argument(help: "Lane name.")
    var name: String

    @Flag(name: .shortAndLong, help: "Discard unmerged work in the branch.")
    var force = false

    @Flag(name: .long, help: "Remove the sandbox and the worktree, but keep the branch.")
    var keepBranch = false

    func run() async throws {
        let repository = try Repository.discover()
        let sandbox = name.asContainerID()

        // Herdr first: closing the workspace kills the panes still holding the sandbox and
        // the worktree open, so the removals below are not fighting live processes.
        Herdr.closeWorkspaces(labelled: sandbox)
        ContainerRuntime.stop(sandbox)
        ContainerRuntime.remove(sandbox)

        if repository.lanePath(name) != nil {
            try repository.deleteLane(name, force: force)
        } else {
            print("arena: no lane named \(name)")
        }

        // Verified rather than trusted to lane's exit status. Checked even when the lane
        // was already gone, or a half-finished teardown leaves the branch stranded with
        // nothing left to retry against.
        if !keepBranch, repository.branchExists(name) {
            guard force else {
                throw ArenaError.laneFailed(
                    "branch \(name) holds unmerged work; rerun with --force to delete it")
            }
            try Shell.run("git", ["-C", repository.root.path, "branch", "-D", name])
        }
    }
}

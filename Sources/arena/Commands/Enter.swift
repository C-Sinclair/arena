import ArgumentParser
import Foundation

struct Enter: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enter",
        abstract: "Open a second process in a sandbox that is already running.",
        discussion: """
            A sandbox runs with --rm, so it exists only while its agent does. `enter` joins \
            one that is still up; it does not restart a sandbox that has exited. Cut that \
            lane again with `arena new <name>`, which reuses the worktree.

            With no name, the lane is the one the working directory is in. `arena @` takes \
            the lane from there too, but launches a sandbox when none is running.
            """,
        aliases: ["attach"]
    )

    @Argument(
        help: "Lane name, or `.` for the worktree the shell is in. Defaults to the lane it is in.")
    var name: String?

    @Flag(name: [.customShort("a"), .long], help: "Start another agent rather than a shell.")
    var agent = false

    @Option(name: .long, help: "Agent binary to launch when --agent is given.")
    var agentBinary = "claude"

    static let shellCommand = "exec bash -l"

    func run() async throws {
        let repository = Repository.discover()
        let lane = try resolveLane(repository: repository)
        let toplevel = lane == "." ? Repository.hereWorktree() : nil
        let sandbox = toplevel.map(Here.sandboxID) ?? lane.asContainerID()

        guard let instance = try ContainerRuntime.instances().first(where: { $0.id == sandbox })
        else {
            throw ArenaError.laneFailed(
                "no sandbox named \(sandbox). `arena list --all` shows what there is, and "
                    + "`arena new \(lane)` launches one against the existing lane.")
        }
        guard instance.state == "running" else {
            throw ArenaError.laneFailed(
                "sandbox \(sandbox) is \(instance.state), and a stopped sandbox cannot be "
                    + "entered. `arena new \(lane)` launches a fresh one against the same lane.")
        }

        let command = agent ? New.command(agent: agentBinary) : Self.shellCommand
        try Shell.replace(
            ContainerRuntime.binary,
            ContainerRuntime.execArguments(
                id: sandbox,
                workdir: toplevel ?? repository.lanePath(lane),
                environment: New.terminalOverrides,
                command: command))
    }

    /// The named lane, or the one the working directory is in.
    private func resolveLane(repository: Repository) throws -> String {
        if let name { return name }
        try repository.requireGit()
        return try repository.currentLane().name
    }
}

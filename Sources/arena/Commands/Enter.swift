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

    @Argument(help: "Lane name. Defaults to the lane the working directory is in.")
    var name: String?

    @Flag(name: [.customShort("a"), .long], help: "Start another agent rather than a shell.")
    var agent = false

    @Option(name: .long, help: "Agent binary to launch when --agent is given.")
    var agentBinary = "claude"

    static let shellCommand = "exec bash -l"

    func run() async throws {
        let repository = try Repository.discover()
        let lane = try resolveLane(repository: repository)
        let sandbox = lane.asContainerID()

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
                workdir: repository.lanePath(lane),
                environment: New.terminalOverrides,
                command: command))
    }

    /// The named lane, or the one the working directory is in.
    private func resolveLane(repository: Repository) throws -> String {
        if let name { return name }
        return try repository.currentLane().name
    }
}

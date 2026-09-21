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
            """,
        aliases: ["attach"]
    )

    @Argument(help: "Lane name.")
    var name: String

    @Flag(name: [.customShort("a"), .long], help: "Start another agent rather than a shell.")
    var agent = false

    @Option(name: .long, help: "Agent binary to launch when --agent is given.")
    var agentBinary = "claude"

    static let shellCommand = "exec bash -l"

    func run() async throws {
        let sandbox = name.asContainerID()

        guard let instance = try ContainerRuntime.instances().first(where: { $0.id == sandbox })
        else {
            throw ArenaError.laneFailed(
                "no sandbox named \(sandbox). `arena list --all` shows what there is, and "
                    + "`arena new \(name)` launches one against the existing lane.")
        }
        guard instance.state == "running" else {
            throw ArenaError.laneFailed(
                "sandbox \(sandbox) is \(instance.state), and a stopped sandbox cannot be "
                    + "entered. `arena new \(name)` launches a fresh one against the same lane.")
        }

        let command = agent ? New.command(agent: agentBinary) : Self.shellCommand
        try Shell.replace(
            ContainerRuntime.binary,
            ContainerRuntime.execArguments(
                id: sandbox,
                workdir: try Repository.discover().lanePath(name),
                environment: New.terminalOverrides,
                command: command))
    }
}

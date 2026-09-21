import ArgumentParser

@main
struct Arena: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "arena",
        abstract:
            "Run a coding agent in a disposable Apple container sandbox, one per git worktree.",
        discussion: """
            arena cuts a lane with `lane`, then launches an agent in a container whose \
            workspace is the WHOLE repository, so git works, with the agent's working \
            directory set to the lane.

            A repository declares its own toolchain by committing .arena/Dockerfile. If that \
            image provides /usr/local/bin/arena-init, arena runs it before the agent starts.
            """,
        version: "0.1.0",
        subcommands: [New.self, Current.self, Enter.self, List.self, Remove.self, Build.self],
        defaultSubcommand: New.self
    )
}

/// Flags shared by the commands that launch or address a sandbox.
struct ResourceOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "CPUs for the sandbox.")
    var cpus: Int = 6

    @Option(name: .shortAndLong, help: "Memory for the sandbox.")
    var memory: String = "8g"

    @Option(name: .long, help: "Size of /dev/shm. Chromium needs well over the 64M default.")
    var shmSize: String = "2g"

    var resources: Resources {
        Resources(cpus: cpus, memory: memory, shmSize: shmSize)
    }
}

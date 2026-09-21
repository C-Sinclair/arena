import ArgumentParser
import Foundation

struct New: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "Cut a lane and launch an agent in a sandbox against it."
    )

    @Argument(help: "Lane name. Becomes the branch, the worktree and the container id.")
    var name: String

    @Option(
        name: [.customShort("b"), .long],
        help: "Branch the lane from this rev instead of the default base.")
    var base: String?

    @Flag(name: .long, help: "Carry uncommitted work from the main worktree into the lane.")
    var dirty = false

    @Option(
        name: [.customShort("M"), .long],
        help: ArgumentHelp(
            "Mount an extra host directory, at the same path inside the sandbox. Repeatable.",
            discussion: "Append ':ro' for a read-only mount."))
    var mount: [String] = []

    @Option(
        name: .long, help: "Extra environment variable for the sandbox, as KEY=VALUE. Repeatable.")
    var env: [String] = []

    @Flag(
        name: [.customShort("H"), .long],
        help: "Run the agent in a new Herdr workspace instead of here.")
    var herdr = false

    @Option(name: .long, help: "Image to run, overriding the repository's own Dockerfile.")
    var image: String?

    @Flag(name: [.customShort("R"), .long], help: "Rebuild the repository's image first.")
    var rebuild = false

    @OptionGroup var imageOptions: DockerfileOptions

    @Option(name: .long, help: "Agent binary to launch inside the sandbox.")
    var agent = "claude"

    @OptionGroup var resourceOptions: ResourceOptions

    /// `new` is the default subcommand, so a subcommand arena does not have is parsed as a
    /// lane name and silently cuts a lane. `arena list` did that before `list` existed as a
    /// name, building an image to run a lane called "list".
    static let reservedNames: Set<String> = [
        "new", "list", "ls", "remove", "rm", "build", "help",
    ]

    func run() async throws {
        guard !Self.reservedNames.contains(name) else {
            throw ValidationError(
                "\(name) is an arena subcommand, not a lane name. Run `arena \(name)`, or "
                    + "`arena new <name>` to cut a lane.")
        }

        let repository = try Repository.discover()
        let sandbox = name.asContainerID()
        if sandbox != name.replacingOccurrences(of: "/", with: "-") {
            print("arena: name too long for a container id; using \(sandbox)")
        }

        let worktree: URL
        if let existing = repository.lanePath(name) {
            print("arena: reusing existing lane at \(existing.path)")
            worktree = existing
        } else {
            worktree = try repository.createLane(name, base: base, dirty: dirty)
        }

        let resolvedImage =
            try image
            ?? ImageResolver(repository: repository, worktree: worktree).resolve(rebuild: rebuild)

        let home = try SandboxHome(repository: repository)
        try home.seedAgentSettings(trusting: worktree)
        try home.writeGitIdentity()

        do {
            try home.writeAgentCredentials()
        } catch {
            warn("\(error)")
            warn("run /login inside the sandbox; it persists in \(home.root.path)")
        }

        if let token = Credentials.githubToken() {
            try home.writeGitHubCredentials(token: token, login: Credentials.githubLogin())
        } else {
            warn("'gh auth token' returned nothing; fetch and push will fail")
        }

        let spec = SandboxSpec(
            name: sandbox,
            image: resolvedImage,
            workdir: worktree,
            resources: resourceOptions.resources,
            mounts: try mounts(repository: repository, home: home) + extraMounts(),
            environment: Self.gitOverrides
                .merging(Self.terminalOverrides) { _, new in new }
                .merging(try extraEnvironment()) { _, new in new },
            command: Self.command(agent: agent)
        )

        if herdr {
            try launchInHerdr(spec: spec, worktree: worktree)
        } else {
            try Shell.replace(ContainerRuntime.binary, ContainerRuntime.runArguments(spec: spec))
        }
    }

    // MARK: - Assembly

    /// Extra host directories, each mounted at its own path so it is reachable inside the
    /// sandbox exactly where it lives outside. A trailing `:ro` is a mount mode, not part of
    /// the path.
    private func extraMounts() throws -> [Mount] {
        try mount.map { specification in
            let readOnly = specification.hasSuffix(":ro")
            let path = readOnly ? String(specification.dropLast(3)) : specification
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ArenaError.laneFailed("no such directory to mount: \(url.path)")
            }
            return Mount(url, readOnly: readOnly)
        }
    }

    private func extraEnvironment() throws -> [String: String] {
        try env.reduce(into: [:]) { result, entry in
            guard let separator = entry.firstIndex(of: "="), separator != entry.startIndex else {
                throw ArenaError.laneFailed("--env expects KEY=VALUE, got \(entry)")
            }
            result[String(entry[entry.startIndex..<separator])] =
                String(entry[entry.index(after: separator)...])
        }
    }

    private func mounts(repository: Repository, home: SandboxHome) -> [Mount] {
        var mounts = [
            Mount(repository.root),
            Mount(home.root, at: "/home/agent"),
            // State that has to outlive the container, which is every run: arena always
            // runs with --rm, so the container's own root filesystem goes with it.
            Mount(home.state, at: "/var/lib/arena"),
        ]

        // Transcripts go to the host's own ~/.claude/projects rather than the sandbox home
        // nested inside the mount above. Every path inside the container matches its host
        // path, so the agent derives the same per-project directory name it would on the
        // host: `--resume` in the lane finds a sandbox session, and `memex index` picks it
        // up without a second source.
        let transcripts = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        try? FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        mounts.append(Mount(transcripts, at: "/home/agent/.claude/projects"))

        // The global agent configuration is reached through symlinks in ~/.claude pointing
        // into the dotfiles repository. Mounting what they resolve to, read-only, is what
        // lets a host edit reach a sandbox that has been running for days.
        for entry in ["CLAUDE.md", "agents", "commands", "skills"] {
            let link = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/\(entry)")
            guard
                let resolved = try? FileManager.default
                    .destinationOfSymbolicLink(atPath: link.path)
            else { continue }

            let directory = URL(
                fileURLWithPath: resolved, relativeTo: link.deletingLastPathComponent()
            )
            .standardizedFileURL.deletingLastPathComponent()

            // Anything already inside the repository mount is reachable at that same path.
            if directory.path == repository.root.path
                || directory.path.hasPrefix(repository.root.path + "/")
            {
                continue
            }
            if mounts.contains(where: { $0.host.path == directory.path }) { continue }

            mounts.append(Mount(directory, readOnly: true))
        }
        return mounts
    }

    /// A repository's `.git/config` comes in with the repository mount, so `commit.gpgsign`
    /// set there reaches the sandbox, while `gpg.format = ssh` and the 1Password signer sit
    /// in the host's global config and do not. Git then looks for a `gpg` binary the image
    /// has no reason to ship and every commit fails. `GIT_CONFIG_*` is the only tier that
    /// beats a repository-local setting, so the override cannot be a file.
    static let gitOverrides: [String: String] = [
        "GIT_CONFIG_COUNT": "3",
        "GIT_CONFIG_KEY_0": "commit.gpgsign", "GIT_CONFIG_VALUE_0": "false",
        "GIT_CONFIG_KEY_1": "tag.gpgsign", "GIT_CONFIG_VALUE_1": "false",
        "GIT_CONFIG_KEY_2": "credential.helper", "GIT_CONFIG_VALUE_2": "store",
    ]

    /// `container run -t` allocates a pty but leaves TERM at `dumb`, so the agent's input
    /// handling has no terminfo to map an escape sequence with and the arrow keys do
    /// nothing. The host's own TERM is deliberately not carried: `xterm-ghostty` and its
    /// like are not in the image's terminfo database, which fails the same way. Pass
    /// `--env TERM=...` to override.
    static let terminalOverrides: [String: String] = [
        "TERM": "xterm-256color",
        "COLORTERM": "truecolor",
    ]

    /// `exec -a` names the pane's foreground process for the agent. Herdr identifies which
    /// agent occupies a pane from that name before applying its screen-detection rules;
    /// left as the runtime's name, the agent matches nothing and never appears in the
    /// agents tab.
    static func command(agent: String) -> String {
        "command -v arena-init >/dev/null && arena-init; "
            + "exec -a \(agent) \(agent) --dangerously-skip-permissions"
    }

    private func launchInHerdr(spec: SandboxSpec, worktree: URL) throws {
        let workspace = try Herdr.createWorkspace(cwd: worktree, label: spec.name)
        Herdr.rename(tab: workspace.tab, to: "agent")

        let argv = ([ContainerRuntime.binary] + ContainerRuntime.runArguments(spec: spec))
            .map(shellQuoted)
            .joined(separator: " ")
        try Herdr.run(pane: workspace.pane, command: argv)

        Herdr.addTab(workspace: workspace.id, cwd: worktree, label: "shell")
        print("arena: running in Herdr workspace \(spec.name)")
    }

    /// `herdr pane run` takes a shell string, so this is the one place arena has to quote.
    /// Single-quote everything and escape embedded quotes, rather than guessing which
    /// arguments are safe.
    private func shellQuoted(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("arena: \(message)\n".utf8))
    }
}

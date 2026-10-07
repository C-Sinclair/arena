import ArgumentParser
import Foundation

/// The host half of `arena-tab`, started by `arena new --herdr` beside the sandbox and gone
/// once that sandbox exits. See ADR-010.
///
/// Polls rather than watching with FSEvents. The files are written from inside the VM, and
/// whether a write through that mount raises an FSEvents notification on the host has not
/// been checked; a listing every half second costs a `readdir` and needs no answer to that.
struct TabReaderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tab-reader",
        abstract: "Serve arena-tab requests for one sandbox. Started by `arena new --herdr`.",
        shouldDisplay: false
    )

    @Option(help: "The sandbox whose requests this reader serves.")
    var sandbox: String

    @Option(help: "The Herdr workspace new tabs open in.")
    var workspace: String

    @Option(help: "The sandbox's worktree, which a shared child runs in.")
    var worktree: String

    @Option(help: "Agent binary a child runs.")
    var agent = "claude"

    @Option(help: "Identifies this reader. A newer reader for the same sandbox replaces it.")
    var token: String

    static let pollInterval: Duration = .milliseconds(500)
    /// One `container ls` is about 42 ms, so the liveness check runs every tenth poll.
    static let livenessEvery = 10
    /// `container run` has been typed into the pane but may not have started yet.
    static let startTimeout: Duration = .seconds(120)

    func run() async throws {
        let worktreeURL = URL(fileURLWithPath: worktree)
        let repository = Repository.discover(from: worktreeURL)
        let home = try SandboxHome(repository: repository)

        let reader = TabReader(
            inbox: Self.inbox(state: home.state, sandbox: sandbox),
            agents: home.state.appendingPathComponent("agents"),
            launcher: HerdrTabLauncher(
                sandbox: sandbox, workspace: workspace, worktree: worktreeURL, agent: agent,
                repository: repository))
        try reader.reset()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.startTimeout)
        while !isRunning() {
            guard clock.now < deadline, isCurrent() else {
                throw ArenaError.laneFailed("sandbox \(sandbox) never started; reader exiting")
            }
            try await Task.sleep(for: .seconds(1))
        }

        var polls = 0
        while isCurrent() {
            reader.drain()
            polls += 1
            if polls % Self.livenessEvery == 0, !isRunning() { break }
            try await Task.sleep(for: Self.pollInterval)
        }

        if isCurrent() {
            try? FileManager.default.removeItem(at: reader.inbox)
            try? FileManager.default.removeItem(at: Self.tokenFile(sandbox))
        }
    }

    /// A failed `container ls` counts as running, so one slow call does not end the reader
    /// while the sandbox is still up.
    private func isRunning() -> Bool {
        guard let instances = try? ContainerRuntime.instances() else { return true }
        return instances.contains { $0.id == sandbox && $0.state == "running" }
    }

    /// A sandbox removed and relaunched under the same name gets a new reader, and the old
    /// one may not yet have seen its container stop.
    private func isCurrent() -> Bool {
        (try? String(contentsOf: Self.tokenFile(sandbox), encoding: .utf8)) == token
    }

    static func inbox(state: URL, sandbox: String) -> URL {
        state.appendingPathComponent("requests").appendingPathComponent(sandbox)
    }

    /// Outside the state mount, so the guest cannot read or replace it.
    static var readersDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".arena/readers")
    }

    static func tokenFile(_ sandbox: String) -> URL {
        readersDirectory.appendingPathComponent("\(sandbox).token")
    }

    static func start(sandbox: String, workspace: String, worktree: URL, agent: String) throws {
        try FileManager.default.createDirectory(
            at: readersDirectory, withIntermediateDirectories: true)
        let token = UUID().uuidString
        try token.write(to: tokenFile(sandbox), atomically: true, encoding: .utf8)

        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        try Shell.spawnDetached(
            executable,
            [
                configuration.commandName!,
                "--sandbox", sandbox,
                "--workspace", workspace,
                "--worktree", worktree.path,
                "--agent", agent,
                "--token", token,
            ],
            log: readersDirectory.appendingPathComponent("\(sandbox).log"))
    }
}

/// Opens each child in a new tab of the parent's Herdr workspace.
struct HerdrTabLauncher: TabLauncher {
    let sandbox: String
    let workspace: String
    let worktree: URL
    let agent: String
    let repository: Repository

    /// `container exec` into the running sandbox. It carries the ARENA_* variables itself
    /// rather than relying on the exec inheriting the container's environment, so a shared
    /// child can open tabs of its own through the same reader.
    func openShared(_ child: TabChild) throws -> String {
        let pane = try Herdr.createTab(workspace: workspace, cwd: worktree, label: child.label).pane
        let environment = New.terminalOverrides.merging([
            ArenaTab.sandboxVariable: sandbox,
            ArenaTab.workspaceVariable: workspace,
            ArenaTab.agentVariable: child.name,
        ]) { _, new in new }

        let argv =
            [ContainerRuntime.binary]
            + ContainerRuntime.execArguments(
                id: sandbox, workdir: worktree, environment: environment,
                command: Self.command(agent: agent, child: child))
        try Herdr.run(pane: pane, command: argv.map(shellQuoted).joined(separator: " "))
        return pane
    }

    /// A new sandbox, because a running container cannot gain the mount a new worktree
    /// needs. It gets no workspace variable and so no reader: `arena-tab` in a lane child
    /// refuses rather than writing requests nobody serves.
    func openLane(branch: String, child: TabChild) throws -> String {
        let childSandbox = branch.asContainerID()
        if let running = try? ContainerRuntime.instances().first(where: { $0.id == childSandbox }) {
            throw ArenaError.refusedRequest(
                "a sandbox named \(childSandbox) already exists (\(running.state))")
        }

        let childWorktree = try repository.lanePath(branch) ?? repository.createLane(branch)
        let options = try New.parse(["--agent", agent, branch])
        var spec = try options.sandboxSpec(
            sandbox: childSandbox, worktree: childWorktree, repository: repository)
        spec.environment[ArenaTab.agentVariable] = child.name
        spec.command = Self.command(agent: agent, child: child)

        let pane = try Herdr.createTab(
            workspace: workspace, cwd: childWorktree, label: child.label
        ).pane
        let argv = [ContainerRuntime.binary] + ContainerRuntime.runArguments(spec: spec)
        try Herdr.run(pane: pane, command: argv.map(shellQuoted).joined(separator: " "))
        return pane
    }

    func prompt(pane: String, text: String) throws {
        try Herdr.prompt(pane: pane, text: text)
    }

    /// The same launch `arena new` makes, with the child's model, effort and brief. The
    /// brief is read from its file inside the container, so none of its text is in the
    /// string typed into the host pane.
    static func command(agent: String, child: TabChild) -> String {
        var command =
            New.command(agent: agent) + " "
            + ["--model", child.model, "--effort", child.effort].map(shellQuoted)
            .joined(separator: " ")
        if !child.brief.isEmpty {
            command += " \"$(cat \(shellQuoted(ArenaTab.guestBrief(child.name))))\""
        }
        return command
    }
}

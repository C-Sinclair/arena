import Foundation

/// The host side of `/var/lib/arena/spawn`: reads each request a sandbox writes there, and
/// does what ADR-010 allows for it and nothing else.
///
/// One broker per state directory. The state directory is per repository, so two sandboxes
/// of one repository share a broker, and it answers the leader it was started for.
struct Broker {
    let state: URL
    let sandbox: String
    let leaderPane: String
    let workspace: String
    var home = FileManager.default.homeDirectoryForCurrentUser

    private let fileManager = FileManager.default

    var spool: URL { state.appendingPathComponent("spawn") }
    var rejected: URL { spool.appendingPathComponent("rejected") }
    var findings: URL { state.appendingPathComponent("findings") }
    var briefs: URL { state.appendingPathComponent("briefs") }
    var pidFile: URL { state.appendingPathComponent("broker.pid") }

    /// The guest sees `state` at this path.
    static let guestState = "/var/lib/arena"

    /// Polled rather than watched with FSEvents. A request is written by a person-paced
    /// agent, and a second of latency costs nothing against a `claude` start.
    static let pollInterval: Duration = .seconds(1)
    /// Checking the container costs a `container list`, so it is done every this many polls.
    static let livenessEvery = 10

    func run() async throws {
        for directory in [spool, rejected, findings, briefs] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard claimPidFile() else {
            log("another broker is already reading \(spool.path)")
            return
        }
        defer { try? fileManager.removeItem(at: pidFile) }

        log("reading \(spool.path) for \(sandbox), leader pane \(leaderPane)")
        var polls = 0
        while true {
            for request in pending() { handle(request) }

            polls += 1
            if polls % Self.livenessEvery == 0, !sandboxRunning() {
                log("\(sandbox) is no longer running; stopping")
                return
            }
            try await Task.sleep(for: Self.pollInterval)
        }
    }

    /// The `.json` files directly in the spool. `arena-spawn` writes `<name>.json.tmp` and
    /// renames it, so a half-written request never ends in `.json`.
    func pending() -> [URL] {
        let entries =
            (try? fileManager.contentsOfDirectory(
                at: spool, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func handle(_ file: URL) {
        let outcome: Result<BrokerAction, BrokerRejection>
        if let data = try? Data(contentsOf: file),
            let request = try? JSONDecoder().decode(BrokerRequest.self, from: data)
        {
            outcome = BrokerProtocol.validate(request, home: home)
        } else {
            outcome = .failure(BrokerRejection(reason: "not a JSON request"))
        }

        switch outcome {
        case .success(let action):
            try? fileManager.removeItem(at: file)
            do {
                try perform(action)
            } catch {
                log("\(file.lastPathComponent): \(error)")
            }
        case .failure(let rejection):
            // Kept rather than deleted, so a refused request can be read after the fact.
            let destination = rejected.appendingPathComponent(file.lastPathComponent)
            try? fileManager.removeItem(at: destination)
            try? fileManager.moveItem(at: file, to: destination)
            log("refused \(file.lastPathComponent): \(rejection)")
        }
    }

    func perform(_ action: BrokerAction) throws {
        switch action {
        case .split(let name, let brief, let model, let effort):
            try split(name: name, brief: brief, model: model, effort: effort)
        case .report(let name):
            try report(name: name)
        case .hop(let repository):
            try hop(to: repository)
        }
    }

    // MARK: - split and report

    private func split(name: String, brief: String, model: String, effort: String) throws {
        let file = BrokerProtocol.fileName(name)
        try (brief + Self.briefFooter(name: name)).write(
            to: briefs.appendingPathComponent("\(file).md"), atomically: true, encoding: .utf8)

        let pane = try Herdr.split(pane: leaderPane, cwd: state)
        let argv =
            [ContainerRuntime.binary]
            + Self.splitArguments(
                sandbox: sandbox, name: name, model: model, effort: effort)
        try Herdr.run(pane: pane, command: argv.map(New.shellQuoted).joined(separator: " "))
        log("split '\(name)' (\(model), \(effort)) in pane \(pane)")
    }

    /// The `container exec` that starts a split agent. The brief is read from the file
    /// inside the container rather than passed as an argument, so its text never reaches a
    /// command line on either side.
    static func splitArguments(sandbox: String, name: String, model: String, effort: String)
        -> [String]
    {
        let brief = "\(guestState)/briefs/\(BrokerProtocol.fileName(name)).md"
        let command =
            "export PATH=$HOME/.local/bin:\(ToolCache.guestBin):$PATH; "
            + "exec -a claude claude --dangerously-skip-permissions "
            + "--model \(model) --effort \(effort) \"$(cat \(brief))\""
        return ContainerRuntime.execArguments(
            id: sandbox, workdir: nil,
            environment: New.terminalOverrides.merging(["ARENA_BROKER": "1"]) { _, new in new },
            command: command)
    }

    static func briefFooter(name: String) -> String {
        """


        ---
        You are a split agent named `\(name)`, working in the same container and worktree as \
        the agent that asked for you. Do not commit. When you are done, write your findings \
        as Markdown to a file and run `arena-report \(name) <file>`. That copies it to \
        \(guestState)/findings/\(BrokerProtocol.fileName(name)).md and tells the leader.

        """
    }

    static func findingsMessage(name: String) -> String {
        "findings ready at \(guestState)/findings/\(BrokerProtocol.fileName(name)).md"
    }

    /// The text is fixed here, so a sandbox can make the leader read one file and nothing
    /// else. See ADR-010.
    private func report(name: String) throws {
        let file = findings.appendingPathComponent("\(BrokerProtocol.fileName(name)).md")
        guard fileManager.fileExists(atPath: file.path) else {
            throw BrokerRejection(reason: "report '\(name)': \(file.path) does not exist")
        }
        try Herdr.prompt(agent: leaderPane, text: Self.findingsMessage(name: name))
        log("reported '\(name)' to pane \(leaderPane)")
    }

    // MARK: - hop

    /// A new sandbox for another repository, in a tab of the leader's workspace, once the
    /// user has said yes. It runs `arena .`, so it gets its own container and broker.
    private func hop(to repository: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: repository.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw BrokerRejection(reason: "hop: \(repository.path) is not a directory")
        }
        guard Self.confirm(hopTo: repository, from: sandbox) else {
            log("hop to \(repository.path) declined")
            return
        }

        let label = repository.lastPathComponent
        let pane = try Herdr.createTab(workspace: workspace, cwd: repository, label: label)
        // Blocks this broker while the other repository's image builds. Requests queue in
        // the spool meanwhile; none is lost.
        try Shell.run(
            Bundle.main.executableURL?.path ?? "arena",
            [".", "--herdr-pane", pane, "--herdr-workspace", workspace],
            workingDirectory: repository)
        log("hopped to \(repository.path) in pane \(pane)")
    }

    /// A macOS dialog rather than a Herdr prompt: Herdr has no confirmation command, and a
    /// prompt typed into a pane could be answered by the agent in it. The path is passed as
    /// an argument to the script, never spliced into it.
    static func confirm(hopTo repository: URL, from sandbox: String) -> Bool {
        let message =
            "The sandbox \(sandbox) asks to open \(repository.path) in a new arena sandbox."
        return Shell.succeeds(
            "osascript",
            [
                "-e", "on run argv",
                "-e",
                "display dialog (item 1 of argv) with title \"arena\" buttons {\"Refuse\", \"Open\"} default button \"Refuse\" cancel button \"Refuse\"",
                "-e", "end run",
                message,
            ])
    }

    private func sandboxRunning() -> Bool {
        guard let instances = try? ContainerRuntime.instances(all: false) else { return true }
        return instances.contains { $0.id == sandbox }
    }

    /// False when the pid file names a process that is still alive.
    private func claimPidFile() -> Bool {
        if let existing = try? String(contentsOf: pidFile, encoding: .utf8),
            let pid = Int32(existing.trimmingCharacters(in: .whitespacesAndNewlines)),
            kill(pid, 0) == 0
        {
            return false
        }
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        return (try? pid.write(to: pidFile, atomically: true, encoding: .utf8)) != nil
    }

    func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) arena broker: \(message)\n".utf8))
    }

    /// Starts `arena broker` detached, logging to `<state>/broker.log`. Called by the Herdr
    /// launch, which returns as soon as the agent's pane is running.
    static func startDetached(state: URL, sandbox: String, pane: String, workspace: String)
        throws
    {
        let log = state.appendingPathComponent("broker.log")
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()

        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = [
            "broker", "--state", state.path, "--sandbox", sandbox, "--pane", pane,
            "--workspace", workspace,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
    }
}

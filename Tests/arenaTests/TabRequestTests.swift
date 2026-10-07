import Foundation
import Testing

@testable import arena

@Suite("arena-tab request parsing")
struct TabRequestParsingTests {
    private func parse(_ json: String) throws -> TabRequest {
        try TabRequest.parse(Data(json.utf8))
    }

    @Test("a shared request takes the sandbox defaults for what it leaves out")
    func sharedDefaults() throws {
        let request = try parse(#"{"kind":"shared","name":"probe","brief":"look"}"#)
        #expect(
            request
                == .shared(
                    TabChild(
                        name: "probe", label: "probe", model: SandboxHome.defaultModel,
                        effort: SandboxHome.defaultEffort, brief: "look")))
    }

    @Test("a lane request carries its branch")
    func lane() throws {
        let request = try parse(
            #"{"kind":"lane","branch":"feature/x","name":"x","model":"haiku","effort":"high"}"#)
        guard case .lane(let branch, let child) = request else {
            Issue.record("expected a lane request, got \(request)")
            return
        }
        #expect(branch == "feature/x")
        #expect(child.model == "haiku")
        #expect(child.effort == "high")
    }

    @Test("a prompt carries its text, and fields arena does not read are ignored")
    func prompt() throws {
        let request = try parse(#"{"kind":"prompt","name":"probe","text":"go on","extra":1}"#)
        #expect(request == .prompt(name: "probe", text: "go on"))
    }

    @Test(
        "a request that could reach a host command badly is refused",
        arguments: [
            #"{"kind":"shared","name":"../escape"}"#,
            #"{"kind":"shared","name":"a b"}"#,
            #"{"kind":"shared"}"#,
            #"{"kind":"shared","name":"x","model":"opus'; rm -rf ~"}"#,
            #"{"kind":"shared","name":"x","label":"two\nlines"}"#,
            #"{"kind":"lane","name":"x","branch":"--force"}"#,
            #"{"kind":"lane","name":"x","branch":"a/../b"}"#,
            #"{"kind":"lane","name":"x"}"#,
            #"{"kind":"prompt","name":"x","text":""}"#,
            #"{"kind":"prompt","name":"x"}"#,
            "not json",
        ])
    func refused(json: String) {
        #expect(throws: ArenaError.self) { try parse(json) }
    }

    @Test("an unknown kind is refused by name", arguments: ["focus", "close", "pane-run", ""])
    func unknownKind(kind: String) {
        do {
            _ = try parse(#"{"kind":"\#(kind)","name":"x"}"#)
            Issue.record("\(kind) was accepted")
        } catch {
            #expect("\(error)".contains("unknown kind"))
        }
    }
}

/// Stands in for Herdr, recording what the reader asked of it.
final class RecordingLauncher: TabLauncher {
    var shared: [TabChild] = []
    var lanes: [(branch: String, child: TabChild)] = []
    var prompts: [(pane: String, text: String)] = []

    func openShared(_ child: TabChild) throws -> String {
        shared.append(child)
        return "pane-\(child.name)"
    }

    func openLane(branch: String, child: TabChild) throws -> String {
        lanes.append((branch, child))
        return "pane-\(child.name)"
    }

    func prompt(pane: String, text: String) throws {
        prompts.append((pane, text))
    }
}

@Suite("Tab reader")
struct TabReaderTests {
    let state: URL
    let launcher = RecordingLauncher()
    let reader: TabReader

    init() throws {
        state = FileManager.default.temporaryDirectory
            .appendingPathComponent("arena-tab-\(UUID().uuidString)")
        reader = TabReader(
            inbox: TabReaderCommand.inbox(state: state, sandbox: "parent"),
            agents: state.appendingPathComponent("agents"),
            launcher: launcher)
        try reader.reset()
    }

    private func submit(_ id: String, _ json: String) throws {
        try json.write(
            to: reader.inbox.appendingPathComponent("\(id).json"), atomically: true,
            encoding: .utf8)
    }

    private func result(_ id: String) throws -> String {
        try String(
            contentsOf: reader.inbox.appendingPathComponent("\(id).result"), encoding: .utf8)
    }

    private func remaining() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: reader.inbox.path)
            .filter { !$0.hasSuffix(".result") }
    }

    @Test("an unknown kind is deleted and acted on in no way")
    func unknownKindDeleted() throws {
        try submit("1", #"{"kind":"pane-run","name":"x","text":"rm -rf ~"}"#)
        try "junk".write(
            to: reader.inbox.appendingPathComponent("stray.txt"), atomically: true,
            encoding: .utf8)
        reader.drain()

        #expect(try remaining().isEmpty)
        #expect(try result("1").hasPrefix("refused"))
        #expect(launcher.shared.isEmpty && launcher.lanes.isEmpty && launcher.prompts.isEmpty)
    }

    @Test("a half-written request is left for the next pass")
    func temporaryFileSkipped() throws {
        try submit(".2.tmp", "{")
        reader.drain()
        #expect(try remaining() == [".2.tmp.json"])
    }

    @Test("a prompt for a name this reader did not start is refused")
    func foreignPromptRefused() throws {
        try submit("1", #"{"kind":"prompt","name":"stranger","text":"hello"}"#)
        reader.drain()

        #expect(launcher.prompts.isEmpty)
        #expect(try result("1").contains("not a child this sandbox started"))
    }

    @Test("a prompt reaches the pane of a child this reader started")
    func ownPromptDelivered() throws {
        try submit("1", #"{"kind":"shared","name":"probe","brief":"start"}"#)
        try submit("2", #"{"kind":"prompt","name":"probe","text":"carry on"}"#)
        reader.drain()

        #expect(launcher.shared.map(\.name) == ["probe"])
        #expect(launcher.prompts.map(\.pane) == ["pane-probe"])
        #expect(launcher.prompts.map(\.text) == ["carry on"])
        #expect(try result("2").hasPrefix("ok"))
    }

    @Test("a second reader does not know the first one's children")
    func childrenAreNotShared() throws {
        try reader.handle(
            .shared(TabChild(name: "a", label: "a", model: "opus", effort: "low", brief: "")))
        let other = TabReader(
            inbox: TabReaderCommand.inbox(state: state, sandbox: "sibling"),
            agents: state.appendingPathComponent("agents"), launcher: launcher)

        #expect(throws: ArenaError.self) { try other.handle(.prompt(name: "a", text: "hi")) }
        #expect(launcher.prompts.isEmpty)
    }

    @Test("a launch writes the brief and resets the status a former child left")
    func launchWritesBriefAndStatus() throws {
        let directory = state.appendingPathComponent("agents/probe")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "done\n".write(
            to: directory.appendingPathComponent("status"), atomically: true, encoding: .utf8)
        try "old".write(
            to: directory.appendingPathComponent("last-message.md"), atomically: true,
            encoding: .utf8)

        try reader.handle(
            .lane(
                branch: "feature/x",
                child: TabChild(
                    name: "probe", label: "p", model: "opus", effort: "low", brief: "do it")))

        #expect(
            try String(contentsOf: directory.appendingPathComponent("status"), encoding: .utf8)
                == "working\n")
        #expect(
            try String(contentsOf: directory.appendingPathComponent("brief.md"), encoding: .utf8)
                == "do it")
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("last-message.md").path))
    }

    @Test("a name already in use is refused rather than sharing a status file")
    func duplicateNameRefused() throws {
        let child = TabChild(name: "a", label: "a", model: "opus", effort: "low", brief: "")
        try reader.handle(.shared(child))
        #expect(throws: ArenaError.self) { try reader.handle(.shared(child)) }
        #expect(launcher.shared.count == 1)
    }

    /// The guest script against the reader, through the files alone. Runs the script with
    /// the host's bash, which is the only part of this that is not the sandbox.
    @Test("arena-tab's JSON survives quotes, backslashes and newlines in a brief")
    func scriptRoundTrip() async throws {
        let script = state.appendingPathComponent("arena-tab")
        try ArenaTab.script
            .replacingOccurrences(of: "state=/var/lib/arena", with: "state=\(state.path)")
            .write(to: script, atomically: true, encoding: .utf8)

        let brief = "say \"hi\"\nthen C:\\path and 'quotes'\tand $HOME"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "--name", "probe", "--label", "Probe tab", brief]
        process.environment = [
            "ARENA_SANDBOX": "parent", "ARENA_HERDR_WORKSPACE": "w1",
            "PATH": "/usr/bin:/bin",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()

        for _ in 0..<100 where process.isRunning {
            reader.drain()
            try await Task.sleep(for: .milliseconds(100))
        }
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(launcher.shared.map(\.brief) == [brief])
        #expect(launcher.shared.map(\.label) == ["Probe tab"])
        #expect(try remaining().isEmpty)
    }
}

@Suite("Status hooks")
struct StatusHookTests {
    @Test("existing settings and hooks are kept, and a rerun does not duplicate arena's")
    func mergeKeepsExisting() throws {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "say done"]]]],
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [["type": "command", "command": "x"]]]
                ],
            ],
        ]
        let once = SandboxHome.mergingStatusHooks(into: existing)
        let twice = SandboxHome.mergingStatusHooks(into: once)

        #expect(twice["model"] as? String == "opus")
        let hooks = try #require(twice["hooks"] as? [String: Any])
        #expect((hooks["PreToolUse"] as? [[String: Any]])?.count == 1)

        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        let commands = stop.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(commands == ["say done", ArenaTab.hookCommand("stop")])

        for event in ["Notification", "UserPromptSubmit"] {
            #expect((hooks[event] as? [[String: Any]])?.count == 1)
        }
    }
}

@Suite("Child launch command")
struct ChildCommandTests {
    @Test("the brief is read from its file, so none of it is typed into a host pane")
    func briefStaysOutOfTheCommand() {
        let child = TabChild(
            name: "probe", label: "p", model: "opus", effort: "low", brief: "secret'; reboot")
        let command = HerdrTabLauncher.command(agent: "claude", child: child)
        #expect(!command.contains("reboot"))
        #expect(command.hasSuffix(#" "$(cat '/var/lib/arena/agents/probe/brief.md')""#))
        #expect(
            command.contains("--dangerously-skip-permissions '--model' 'opus' '--effort' 'low'"))
    }
}

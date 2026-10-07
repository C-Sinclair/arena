import Foundation

/// A child agent `arena-tab` asked for.
struct TabChild: Equatable {
    let name: String
    let label: String
    let model: String
    let effort: String
    let brief: String
}

/// The three things a sandboxed agent may ask of Herdr, and nothing else. See ADR-010.
///
/// Every field arrives from the guest, so each is checked against a pattern here, before any
/// of it reaches a host command. A name becomes a directory under `/var/lib/arena/agents`,
/// a branch becomes `lane`'s argument, and the model and effort are spliced into the command
/// typed into a host pane.
enum TabRequest: Equatable {
    case shared(TabChild)
    case lane(branch: String, child: TabChild)
    case prompt(name: String, text: String)

    /// Only the fields arena reads. Anything else in the file is ignored rather than refused.
    private struct Wire: Decodable {
        let kind: String
        let name: String?
        let label: String?
        let model: String?
        let effort: String?
        let brief: String?
        let branch: String?
        let text: String?
    }

    static let maximumText = 256 * 1024

    static func parse(_ data: Data) throws -> TabRequest {
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw ArenaError.refusedRequest("not a request arena can read: \(error)")
        }

        switch wire.kind {
        case "shared":
            return .shared(try child(wire))
        case "lane":
            let branch = try required(wire.branch, "branch")
            guard matches(branch, branchPattern), !branch.contains("..") else {
                throw ArenaError.refusedRequest("\(branch) is not a branch arena will cut")
            }
            return .lane(branch: branch, child: try child(wire))
        case "prompt":
            let name = try validName(wire.name)
            let text = try required(wire.text, "text")
            guard !text.isEmpty, text.utf8.count <= maximumText else {
                throw ArenaError.refusedRequest("prompt text must be 1 to \(maximumText) bytes")
            }
            return .prompt(name: name, text: text)
        default:
            throw ArenaError.refusedRequest(
                "unknown kind \(wire.kind); a request is shared, lane or prompt")
        }
    }

    private static func child(_ wire: Wire) throws -> TabChild {
        let name = try validName(wire.name)
        let model = wire.model ?? SandboxHome.defaultModel
        let effort = wire.effort ?? SandboxHome.defaultEffort
        for (field, value) in [("model", model), ("effort", effort)]
        where !matches(value, flagPattern) {
            throw ArenaError.refusedRequest("\(value) is not a \(field) arena will pass on")
        }

        let label = wire.label ?? name
        guard !label.isEmpty, label.count <= 80,
            !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ArenaError.refusedRequest("a label is 1 to 80 characters on one line")
        }

        let brief = wire.brief ?? ""
        guard brief.utf8.count <= maximumText else {
            throw ArenaError.refusedRequest("a brief is at most \(maximumText) bytes")
        }
        return TabChild(name: name, label: label, model: model, effort: effort, brief: brief)
    }

    private static func required(_ value: String?, _ field: String) throws -> String {
        guard let value else { throw ArenaError.refusedRequest("missing \(field)") }
        return value
    }

    private static func validName(_ value: String?) throws -> String {
        let name = try required(value, "name")
        guard matches(name, namePattern) else {
            throw ArenaError.refusedRequest(
                "\(name) is not a valid name: letters, digits, '.', '_' and '-'")
        }
        return name
    }

    static let namePattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$"
    // A leading '-' would reach `lane` as a flag.
    static let branchPattern = "^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$"
    static let flagPattern = #"^[A-Za-z0-9][A-Za-z0-9._\[\]-]{0,63}$"#

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

/// What the reader does on the host for each request, apart so a test can stand in for
/// Herdr. Each launch returns the pane the child runs in.
protocol TabLauncher {
    func openShared(_ child: TabChild) throws -> String
    func openLane(branch: String, child: TabChild) throws -> String
    func prompt(pane: String, text: String) throws
}

/// Takes requests out of one sandbox's directory and acts on the three kinds ADR-010 allows.
///
/// The inbox is `requests/<sandbox>` rather than `requests/` itself, because the state
/// directory is per repository and every sandbox of that repository shares it. The
/// subdirectory routes a request to its own sandbox's reader. It is not a security
/// boundary: a guest can write to any of them, and what holds is that each reader only
/// opens tabs in its own workspace and only prompts children it started.
final class TabReader {
    let inbox: URL
    let agents: URL
    let launcher: any TabLauncher

    /// Name to pane, in memory only. A child from an earlier reader, or from another
    /// sandbox, is not in here, and `prompt` refuses it.
    private(set) var children: [String: String] = [:]

    private let fileManager = FileManager.default

    init(inbox: URL, agents: URL, launcher: any TabLauncher) {
        self.inbox = inbox
        self.agents = agents
        self.launcher = launcher
    }

    /// Requests left by a previous container of the same name were written for a reader
    /// that is gone, so none of them is acted on.
    func reset() throws {
        try? fileManager.removeItem(at: inbox)
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    /// Handles every request waiting, oldest first by name. A request is deleted before it
    /// is acted on, which is what tells `arena-tab` the reader is alive; the answer goes to
    /// `<id>.result` once the action has finished.
    func drain() {
        let entries =
            (try? fileManager.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: nil)) ?? []

        for file in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let filename = file.lastPathComponent
            // Half-written requests and the answers arena-tab has yet to collect.
            if filename.hasPrefix(".") || filename.hasSuffix(".result") { continue }

            let data = try? Data(contentsOf: file)
            try? fileManager.removeItem(at: file)
            guard filename.hasSuffix(".json"), let data else { continue }

            let answer: String
            do {
                answer = "ok " + (try handle(TabRequest.parse(data)))
            } catch {
                answer = "refused \(error)"
            }
            log("\(filename): \(answer)")

            let result = inbox.appendingPathComponent(
                String(filename.dropLast(".json".count)) + ".result")
            try? (answer + "\n").write(to: result, atomically: true, encoding: .utf8)
        }
    }

    @discardableResult
    func handle(_ request: TabRequest) throws -> String {
        switch request {
        case .shared(let child):
            try prepare(child)
            children[child.name] = try launcher.openShared(child)
            try writeStatus("working", for: child.name)
            return "started \(child.name) in this sandbox, in tab \(child.label)"

        case .lane(let branch, let child):
            try prepare(child)
            children[child.name] = try launcher.openLane(branch: branch, child: child)
            try writeStatus("working", for: child.name)
            return "started \(child.name) in a sandbox for lane \(branch), in tab \(child.label)"

        case .prompt(let name, let text):
            guard let pane = children[name] else {
                throw ArenaError.refusedRequest(
                    "\(name) is not a child this sandbox started, so arena will not prompt it")
            }
            try launcher.prompt(pane: pane, text: text)
            try writeStatus("working", for: name)
            return "prompted \(name)"
        }
    }

    /// A second child under a name already in use would share its status file, and the
    /// parent could no longer tell which of the two had finished.
    private func prepare(_ child: TabChild) throws {
        guard children[child.name] == nil else {
            throw ArenaError.refusedRequest(
                "this sandbox already started a child named \(child.name)")
        }
        let directory = agents.appendingPathComponent(child.name)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // A child from an earlier session under the same name left these behind, and
        // `arena-tab wait` would read its `done` as this child's.
        for stale in ["status", "last-message.md"] {
            try? fileManager.removeItem(at: directory.appendingPathComponent(stale))
        }
        try child.brief.write(
            to: directory.appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
    }

    private func writeStatus(_ status: String, for name: String) throws {
        try (status + "\n").write(
            to: agents.appendingPathComponent(name).appendingPathComponent("status"),
            atomically: true, encoding: .utf8)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(
            Data(
                "arena tab-reader \(ISO8601DateFormatter().string(from: Date())): \(message)\n".utf8
            ))
    }
}

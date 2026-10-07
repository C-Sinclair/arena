import Foundation

/// Herdr, the terminal workspace manager the agent runs inside.
enum Herdr {
    struct Workspace {
        let id: String
        let tab: String
        let pane: String
    }

    static func createWorkspace(cwd: URL, label: String) throws -> Workspace {
        let json = try Shell.run(
            "herdr", ["workspace", "create", "--cwd", cwd.path, "--label", label, "--focus"])
        guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let result = root["result"] as? [String: Any],
            let workspace = (result["workspace"] as? [String: Any])?["workspace_id"] as? String,
            let tab = (result["tab"] as? [String: Any])?["tab_id"] as? String,
            let pane = (result["root_pane"] as? [String: Any])?["pane_id"] as? String
        else {
            throw ArenaError.laneFailed("herdr workspace create returned an unexpected shape")
        }
        return Workspace(id: workspace, tab: tab, pane: pane)
    }

    static func closeWorkspaces(labelled label: String) {
        guard let json = try? Shell.run("herdr", ["workspace", "list"]),
            let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let result = root["result"] as? [String: Any],
            let workspaces = result["workspaces"] as? [[String: Any]]
        else { return }

        for workspace in workspaces
        where workspace["label"] as? String == label {
            guard let id = workspace["workspace_id"] as? String else { continue }
            _ = try? Shell.run("herdr", ["workspace", "close", id])
        }
    }

    static func rename(tab: String, to name: String) {
        _ = try? Shell.run("herdr", ["tab", "rename", tab, name])
    }

    static func run(pane: String, command: String) throws {
        try Shell.run("herdr", ["pane", "run", pane, command])
    }

    /// A tab whose root pane the caller runs something in, which is why this one throws and
    /// returns the pane where `addTab` does neither.
    static func createTab(workspace: String, cwd: URL, label: String) throws -> (
        tab: String, pane: String
    ) {
        let json = try Shell.run(
            "herdr",
            [
                "tab", "create", "--workspace", workspace, "--cwd", cwd.path,
                "--label", label, "--no-focus",
            ])
        guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let result = root["result"] as? [String: Any],
            let tab = (result["tab"] as? [String: Any])?["tab_id"] as? String,
            let pane = (result["root_pane"] as? [String: Any])?["pane_id"] as? String
        else {
            throw ArenaError.laneFailed("herdr tab create returned an unexpected shape")
        }
        return (tab, pane)
    }

    /// Addressed by pane id rather than by an agent name. A child is never registered with
    /// `herdr agent start`, so it has no name in Herdr, and the pane id is the one handle
    /// the reader recorded itself.
    static func prompt(pane: String, text: String) throws {
        try Shell.run("herdr", ["agent", "prompt", pane, text])
    }

    static func addTab(workspace: String, cwd: URL, label: String) {
        _ = try? Shell.run(
            "herdr",
            [
                "tab", "create", "--workspace", workspace, "--cwd", cwd.path,
                "--label", label, "--no-focus",
            ])
    }
}

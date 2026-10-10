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

    static func addTab(workspace: String, cwd: URL, label: String) {
        _ = try? Shell.run(
            "herdr",
            [
                "tab", "create", "--workspace", workspace, "--cwd", cwd.path,
                "--label", label, "--no-focus",
            ])
    }

    /// A new pane to the right of `pane`, without taking focus from the agent in it.
    static func split(pane: String, cwd: URL) throws -> String {
        let json = try Shell.run(
            "herdr",
            ["pane", "split", pane, "--direction", "right", "--cwd", cwd.path, "--no-focus"])
        guard let id = paneID(in: json) else {
            throw ArenaError.laneFailed("herdr pane split returned no pane_id: \(json)")
        }
        return id
    }

    /// Like `addTab`, but returns the new tab's pane for the caller to run something in.
    static func createTab(workspace: String, cwd: URL, label: String) throws -> String {
        let json = try Shell.run(
            "herdr",
            [
                "tab", "create", "--workspace", workspace, "--cwd", cwd.path,
                "--label", label, "--no-focus",
            ])
        guard let id = paneID(in: json) else {
            throw ArenaError.laneFailed("herdr tab create returned no pane_id: \(json)")
        }
        return id
    }

    static func prompt(agent target: String, text: String) throws {
        try Shell.run("herdr", ["agent", "prompt", target, text])
    }

    /// The first `pane_id` anywhere in a Herdr result. `workspace create` nests it under
    /// `root_pane`; the shape `pane split` and `tab create` print has not been checked, so
    /// this does not assume one.
    static func paneID(in json: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else {
            return nil
        }
        return firstValue(forKey: "pane_id", in: root)
    }

    private static func firstValue(forKey key: String, in value: Any) -> String? {
        if let object = value as? [String: Any] {
            if let found = object[key] as? String { return found }
            for name in object.keys.sorted() {
                if let found = firstValue(forKey: key, in: object[name]!) { return found }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let found = firstValue(forKey: key, in: element) { return found }
            }
        }
        return nil
    }
}

import Foundation

/// The persistent home mounted over `/home/agent`, and the per-repository state directory
/// mounted at `/var/lib/arena`.
///
/// Without a persistent home every run starts a sandbox with no configuration, so the agent
/// asks for a theme and a login every single time. The image installs the agent, hex and
/// rebar outside `/home/agent` precisely so this mount cannot shadow them.
struct SandboxHome {
    let root: URL
    let state: URL

    private let fileManager = FileManager.default

    init(repository: Repository) throws {
        let base = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".arena")
        root = base.appendingPathComponent("home")
        // Per repository rather than per lane. The repositories that want durable state
        // name their databases after the branch already, so one Postgres cluster serves
        // every lane without collisions. See ADR-006.
        state = base.appendingPathComponent("state").appendingPathComponent(repository.name)

        try fileManager.createDirectory(
            at: root.appendingPathComponent(".claude"),
            withIntermediateDirectories: true)
        try fileManager.createDirectory(at: state, withIntermediateDirectories: true)
    }

    // MARK: - Agent configuration

    /// The entries in the host's `~/.claude` that are symlinks into the dotfiles repository
    /// and that the agent in the sandbox should read too. `settings.json` is deliberately
    /// absent: it names MCP servers and hooks that run host binaries, none of which exist in
    /// a Linux guest.
    static let globalAgentEntries = ["CLAUDE.md", "agents", "commands", "skills"]

    /// New.mounts puts the directories these resolve to into the container read-only at their
    /// own host paths, which on its own reaches nothing: the sandbox home is ~/.arena/home,
    /// not the host's, so `~/.claude/skills` does not exist there and the agent found none of
    /// the global configuration. Recreating each symlink here is what connects the two, and
    /// it names the same absolute path inside the container as outside.
    func linkGlobalAgentConfig() throws {
        for entry in Self.globalAgentEntries {
            let link = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/\(entry)")
            guard let resolved = try? fileManager.destinationOfSymbolicLink(atPath: link.path)
            else { continue }

            let target = URL(
                fileURLWithPath: resolved, relativeTo: link.deletingLastPathComponent()
            ).standardizedFileURL
            let destination = root.appendingPathComponent(".claude/\(entry)")

            // Replaced rather than left alone, so retargeting the host symlink reaches the
            // sandbox. Only a symlink is ever removed; a real file here is the agent's own.
            if let existing = try? fileManager.destinationOfSymbolicLink(atPath: destination.path) {
                if existing == target.path { continue }
                try fileManager.removeItem(at: destination)
            } else if fileManager.fileExists(atPath: destination.path) {
                continue
            }

            try fileManager.createSymbolicLink(at: destination, withDestinationURL: target)
        }
    }

    private var settingsFile: URL { root.appendingPathComponent(".claude.json") }

    /// Seeded once. `hasCompletedOnboarding` is what silences the theme picker. The host's
    /// own `.claude.json` is deliberately not shared: it is project history the sandbox has
    /// no business reading, and a shared file would have two agents writing to it at once.
    func seedAgentSettings(trusting worktree: URL) throws {
        var settings: [String: Any] =
            (try? Data(contentsOf: settingsFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? ["hasCompletedOnboarding": true, "theme": "dark"]

        // arena launches the agent with --dangerously-skip-permissions, which otherwise opens
        // a confirmation dialog on every launch. Accepting it is the point of a disposable
        // sandbox, and the dialog asks for no decision the user has not already made by
        // running arena.
        settings["bypassPermissionsModeAccepted"] = true

        // The agent asks to trust each new directory, and every lane is a new path, so
        // without this the trust dialog blocks every launch. arena cut this worktree from a
        // repository already on this machine; there is nothing for the prompt to protect.
        var projects = settings["projects"] as? [String: Any] ?? [:]
        var entry = projects[worktree.path] as? [String: Any] ?? [:]
        entry["hasTrustDialogAccepted"] = true
        projects[worktree.path] = entry
        settings["projects"] = projects

        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
        try data.write(to: settingsFile)
    }

    /// Rewritten every run so a refreshed host token propagates, and never mounted from the
    /// host copy: a token the sandbox rotated would otherwise invalidate the host's.
    func writeAgentCredentials() throws {
        let secret = try Credentials.keychainSecret(service: Credentials.claudeService)
        let file = root.appendingPathComponent(".claude/.credentials.json")
        try write(secret, to: file)
    }

    /// A file rather than `GH_TOKEN` in the environment. The Herdr path passes its command
    /// to `herdr pane run` as a string, and an environment variable would put the token on
    /// a command line.
    func writeGitHubCredentials(token: String, login: String) throws {
        try write(
            "https://x-access-token:\(token)@github.com\n",
            to: root.appendingPathComponent(".git-credentials"))

        let ghConfig = root.appendingPathComponent(".config/gh")
        try fileManager.createDirectory(at: ghConfig, withIntermediateDirectories: true)
        try write(
            "github.com:\n    oauth_token: \(token)\n    user: \(login)\n    git_protocol: https\n",
            to: ghConfig.appendingPathComponent("hosts.yml"))
    }

    /// Identity in the sandbox home's own gitconfig rather than an environment override, so
    /// a repository that sets its own `user.email` still wins.
    func writeGitIdentity() throws {
        let config = root.appendingPathComponent(".gitconfig")
        for key in ["user.name", "user.email"] {
            guard let value = try? Shell.run("git", ["config", "--global", "--get", key]),
                !value.isEmpty
            else { continue }
            try Shell.run("git", ["config", "--file", config.path, key, value])
        }
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

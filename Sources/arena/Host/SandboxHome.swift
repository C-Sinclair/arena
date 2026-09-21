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

    /// Puts the mounted Linux tools on the PATH of every shell in the sandbox.
    ///
    /// Not an `--env PATH`: the agent runs under `bash -lc`, and Ubuntu's `/etc/profile`
    /// assigns PATH outright rather than appending, so an inherited one is discarded before
    /// the agent starts. A file the login shell reads afterwards is the only place the
    /// prepend survives.
    ///
    /// Written to `.arena-profile` and sourced from `.profile` and `.bashrc`, so a line the
    /// user adds to either is never overwritten.
    func writeShellProfile() throws {
        let profile = root.appendingPathComponent(".arena-profile")
        try write("export PATH=\"\(ToolCache.guestBin):$PATH\"\n", to: profile)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: profile.path)

        let source = ". \"$HOME/.arena-profile\""
        for name in [".profile", ".bashrc"] {
            let file = root.appendingPathComponent(name)
            let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            guard !existing.contains(source) else { continue }
            let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            try (existing + separator + source + "\n").write(
                to: file, atomically: true, encoding: .utf8)
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

        try seedPermissionMode()
    }

    /// `bypassPermissionsModeAccepted` above records that the warning was read. It does not
    /// choose the mode, so the agent still started in its default one and asked on every
    /// launch. `permissions.defaultMode` in `.claude/settings.json` is the setting that
    /// starts it in bypass, and both are needed: the mode without the acceptance reopens the
    /// warning.
    private func seedPermissionMode() throws {
        let file = root.appendingPathComponent(".claude/settings.json")
        var settings: [String: Any] =
            (try? Data(contentsOf: file))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        permissions["defaultMode"] = "bypassPermissions"
        settings["permissions"] = permissions

        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
        try data.write(to: file)
    }

    private var agentCredentialsFile: URL {
        root.appendingPathComponent(".claude/.credentials.json")
    }

    /// Written from the Keychain, and never mounted from the host copy: a token the sandbox
    /// rotated would otherwise invalidate the host's.
    ///
    /// Reading the Keychain is what makes macOS ask for the login password. arena is not in
    /// the item's access control list, and an unsigned arena gets a fresh ad-hoc signature
    /// from every `swift build`, so "Always Allow" has no stable identity to remember.
    /// Skipping the read while the token arena last wrote is still valid turns that prompt
    /// from every launch into once a token lifetime. Sign the binary to be rid of it
    /// entirely.
    func writeAgentCredentials(force: Bool = false) throws {
        let cached = Self.expiry(of: agentCredentialsFile)
        if !force, let cached, cached > Date().addingTimeInterval(300) { return }

        let secret = try Credentials.keychainSecret(service: Credentials.claudeService)
        try write(secret, to: agentCredentialsFile)
    }

    /// `claudeAiOauth.expiresAt`, in milliseconds since the epoch. Nil for a file that is
    /// absent, unreadable or shaped differently, which sends the caller to the Keychain.
    private static func expiry(of file: URL) -> Date? {
        guard let data = try? Data(contentsOf: file),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any],
            let milliseconds = oauth["expiresAt"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    /// Where the sandbox's own signing key sits inside the container.
    static let guestSigningKey = "/home/agent/.ssh/arena_signing_ed25519"
    static let guestAllowedSigners = "/home/agent/.ssh/allowed_signers"

    /// A signing key that belongs to the sandbox, generated once and kept in the persistent
    /// home.
    ///
    /// The host signs with 1Password, and neither half of that reaches a Linux guest:
    /// `op-ssh-sign` is a Mach-O binary, and the agent socket cannot be mounted, because a
    /// socket shared through `--volume` appears in the guest and then refuses every
    /// connection. See docs/friction/FF-210926.
    ///
    /// A separate key rather than a relay to the host's agent. Relaying would let any agent
    /// in any lane sign anything with the 1Password key, which is the credential a sandbox
    /// exists to withhold. The cost is a second key, on disk rather than in 1Password, and
    /// a public half that has to be registered with GitHub before a lane's commits verify.
    ///
    /// Returns the public key, and whether this call was the one that made it.
    @discardableResult
    func ensureSigningKey() throws -> (publicKey: String, created: Bool) {
        let directory = root.appendingPathComponent(".ssh")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let key = directory.appendingPathComponent("arena_signing_ed25519")
        let publicKeyFile = URL(fileURLWithPath: key.path + ".pub")

        var created = false
        if !fileManager.fileExists(atPath: key.path) {
            try Shell.run(
                "ssh-keygen",
                [
                    "-t", "ed25519",
                    "-f", key.path,
                    "-N", "",
                    "-C", "arena sandbox signing key",
                ])
            created = true
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)

        let publicKey = try String(contentsOf: publicKeyFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Without this, every `git log --show-signature` in a lane prints "gpg.ssh.
        // allowedSignersFile needs to be configured and exist", and `%G?` answers N on a
        // commit that is signed. An agent reading that concludes signing is broken.
        let email = (try? Shell.run("git", ["config", "--global", "--get", "user.email"])) ?? ""
        if !email.isEmpty {
            try write(
                "\(email) \(publicKey)\n",
                to: directory.appendingPathComponent("allowed_signers"))
        }

        return (publicKey, created)
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

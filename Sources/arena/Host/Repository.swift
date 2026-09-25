import Foundation

/// The directory arena was invoked inside, the lanes cut from it, and whether git tracks it
/// at all.
struct Repository {
    let root: URL

    /// False for a directory git does not track. Only `arena .` and `arena build` run
    /// against one: a lane is a git worktree, so every command naming a lane needs this to
    /// be true. See ADR-008.
    let isGitRepository: Bool

    /// `--git-common-dir` resolves to the parent repository's `.git` even when the working
    /// directory is already a worktree, which `--show-toplevel` does not.
    ///
    /// A directory outside git is not an error here, because `arena .` works against one.
    /// The commands that need git call `requireGit` rather than relying on this to throw.
    static func discover(
        from directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> Repository {
        guard
            let common = try? Shell.run(
                "git", ["rev-parse", "--path-format=absolute", "--git-common-dir"],
                workingDirectory: directory)
        else {
            return Repository(root: directory.standardizedFileURL, isGitRepository: false)
        }
        return Repository(
            root: URL(fileURLWithPath: common).deletingLastPathComponent(),
            isGitRepository: true)
    }

    var name: String { root.lastPathComponent }

    /// Called by every command but `arena .` and `arena build`, so a lane operation in a
    /// directory git does not track fails naming the one command that does work there,
    /// rather than reaching `lane` and failing with lane's own error.
    func requireGit() throws {
        guard !isGitRepository else { return }
        throw ArenaError.notARepository(root.path)
    }

    /// The worktree a directory sits in, lane or not. `arena .` works against this, so it
    /// never asks `lane` anything.
    static func toplevel(
        from directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> URL {
        URL(
            fileURLWithPath: try Shell.run(
                "git", ["rev-parse", "--show-toplevel"], workingDirectory: directory))
    }

    /// What `arena .` launches against: the worktree the shell is in, or the directory
    /// itself when git does not track it.
    static func hereWorktree(
        from directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> URL {
        (try? toplevel(from: directory)) ?? directory.standardizedFileURL
    }

    /// `-C` into a directory git does not track still answers from the user's global file,
    /// which is what gives a non-git directory a global `arena.baseImage`.
    func config(_ key: String) -> String? {
        guard let value = try? Shell.run("git", ["-C", root.path, "config", "--get", key]),
            !value.isEmpty
        else { return nil }
        return value
    }

    func branchExists(_ name: String) -> Bool {
        Shell.succeeds(
            "git", ["-C", root.path, "show-ref", "--verify", "--quiet", "refs/heads/\(name)"])
    }

    // MARK: - Lanes

    /// Lane owns worktree layout; arena asks rather than reimplements. Keeping one
    /// definition of where a worktree lives is what lets `lane`, `herdr` and arena agree.
    ///
    /// `lane -l --json` rather than a path flag: the binary has no such flag, and the fish
    /// helpers this replaces filtered the JSON listing by name. Running the binary through
    /// `env` also sidesteps the shell-integration function `config.fish` installs, which
    /// cds into the lane it prints and would strand the caller.
    struct Lane: Decodable {
        let name: String
        let path: String
    }

    func lanes() -> [Lane] {
        guard let json = try? Shell.run("lane", ["-l", "--json"], workingDirectory: root),
            let lanes = try? JSONDecoder().decode([Lane].self, from: Data(json.utf8))
        else { return [] }
        return lanes
    }

    /// The lane a directory sits in, which is how `arena @` works out what to attach to.
    ///
    /// Matched on the longest path rather than the first, so a lane nested inside another
    /// lane's tree resolves to the inner one. Compared with a trailing separator, so
    /// `.../trees/probe-2` is not read as being inside `.../trees/probe`.
    func lane(containing directory: URL) -> Lane? {
        Self.lane(in: lanes(), containing: directory)
    }

    /// The lane the shell is standing in, for the commands that take no name.
    ///
    /// Being outside every lane is an error naming the lanes there are, rather than a
    /// guess: acting on the wrong lane is worse than being told to name one.
    func currentLane() throws -> Lane {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if let lane = lane(containing: cwd) { return lane }

        let names = lanes().map(\.name).sorted()
        let known =
            names.isEmpty
            ? "\(name) has no lanes."
            : "Lanes here: \(names.joined(separator: ", "))."
        throw ArenaError.laneFailed(
            "\(cwd.path) is not inside a lane. \(known) "
                + "`arena .` launches a sandbox against this worktree without one.")
    }

    static func lane(in lanes: [Lane], containing directory: URL) -> Lane? {
        let target = directory.standardizedFileURL.path
        return
            lanes
            .filter { lane in
                let path = URL(fileURLWithPath: lane.path).standardizedFileURL.path
                return target == path || target.hasPrefix(path + "/")
            }
            .max { $0.path.count < $1.path.count }
    }

    func lanePath(_ name: String) -> URL? {
        guard let lane = lanes().first(where: { $0.name == name }),
            FileManager.default.fileExists(atPath: lane.path)
        else { return nil }
        return URL(fileURLWithPath: lane.path)
    }

    /// `base` branches from a rev other than the default, and `dirty` carries uncommitted
    /// work into the new lane. Both are lane's own flags, passed through rather than
    /// reimplemented. lane has no separate branch flag: the lane name is the branch name.
    func createLane(_ name: String, base: String? = nil, dirty: Bool = false) throws -> URL {
        var arguments = [name]
        if let base { arguments += ["--base", base] }
        if dirty { arguments.append("--dirty") }

        let path = try Shell.run("lane", arguments, workingDirectory: root)
        guard !path.isEmpty else {
            throw ArenaError.laneFailed("lane \(name) produced no path")
        }
        return URL(fileURLWithPath: path)
    }

    func deleteLane(_ name: String, force: Bool) throws {
        try Shell.run("lane", [force ? "-D" : "-d", name], workingDirectory: root)
    }
}

enum ArenaError: Error, CustomStringConvertible {
    case notARepository(String)
    case laneFailed(String)
    case buildFailed(String)
    case missingCredentials(String)

    var description: String {
        switch self {
        case .notARepository(let path):
            "\(path) is not a git repository, and a lane is a git worktree. "
                + "`arena .` launches a sandbox against this directory without one."
        case .laneFailed(let detail): detail
        case .buildFailed(let detail): detail
        case .missingCredentials(let detail): detail
        }
    }
}

import Foundation

/// The git repository arena was invoked inside, and the lanes cut from it.
struct Repository {
    let root: URL

    /// `--git-common-dir` resolves to the parent repository's `.git` even when the working
    /// directory is already a worktree, which `--show-toplevel` does not.
    static func discover(
        from directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> Repository {
        let common = try Shell.run(
            "git", ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            workingDirectory: directory)
        return Repository(root: URL(fileURLWithPath: common).deletingLastPathComponent())
    }

    var name: String { root.lastPathComponent }

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
    case notARepository
    case laneFailed(String)
    case buildFailed(String)
    case missingCredentials(String)

    var description: String {
        switch self {
        case .notARepository: "not inside a git repository"
        case .laneFailed(let detail): detail
        case .buildFailed(let detail): detail
        case .missingCredentials(let detail): detail
        }
    }
}

import Foundation

/// The `container` CLI, decoded rather than scraped.
///
/// `container ls` and `container image ls` both take `--format json`, so arena reads a
/// documented machine format instead of parsing table columns. That is also why arena does
/// not link `ContainerAPIClient`: the library speaks XPC to the `container-apiserver` that
/// Homebrew installed, and linking it would put a second copy of that protocol in this
/// binary for `brew upgrade container` to skew. See ADR-001.
enum ContainerRuntime {
    static let binary = "container"

    // MARK: - Decoded shapes

    /// Only the fields arena uses. `container ls --format json` returns a great deal more,
    /// and decoding all of it would make every upstream addition a compile error here.
    struct Instance: Decodable {
        let id: String
        let image: String
        let state: String

        private enum RootKeys: String, CodingKey { case configuration, status }
        private enum ConfigKeys: String, CodingKey { case id, image }
        private enum ImageKeys: String, CodingKey { case reference }
        private enum StatusKeys: String, CodingKey { case state }

        init(from decoder: Decoder) throws {
            let root = try decoder.container(keyedBy: RootKeys.self)
            let config = try root.nestedContainer(keyedBy: ConfigKeys.self, forKey: .configuration)
            id = try config.decode(String.self, forKey: .id)
            let imageContainer = try config.nestedContainer(keyedBy: ImageKeys.self, forKey: .image)
            image = try imageContainer.decode(String.self, forKey: .reference)
            let status = try root.nestedContainer(keyedBy: StatusKeys.self, forKey: .status)
            state = try status.decode(String.self, forKey: .state)
        }
    }

    struct Image: Decodable {
        let name: String
        let tag: String
    }

    // MARK: - Queries

    static func instances(all: Bool = true) throws -> [Instance] {
        var args = ["ls", "--format", "json"]
        if all { args.append("--all") }
        let json = try Shell.run(binary, args)
        return try JSONDecoder().decode([Instance].self, from: Data(json.utf8))
    }

    static func imageExists(name: String, tag: String) -> Bool {
        guard let json = try? Shell.run(binary, ["image", "ls", "--format", "json"]),
            let images = try? JSONDecoder().decode([Image].self, from: Data(json.utf8))
        else { return false }
        return images.contains { $0.name == name && $0.tag == tag }
    }

    // MARK: - Lifecycle

    static func build(tag: String, dockerfile: URL, context: URL) throws {
        try Shell.exec(
            binary,
            [
                "build", "--tag", tag, "--file", dockerfile.path, context.path,
            ])
    }

    static func stop(_ id: String) { _ = try? Shell.run(binary, ["stop", id]) }
    static func remove(_ id: String) { _ = try? Shell.run(binary, ["rm", id]) }

    /// The argument vector for a sandbox, built once and used by both the direct and the
    /// Herdr launch path so the two cannot drift.
    static func runArguments(spec: SandboxSpec) -> [String] {
        var args = ["run", "--rm", "--name", spec.name, "--workdir", spec.workdir.path]
        args += spec.resources.arguments
        for mount in spec.mounts { args += ["--volume", mount.specification] }
        for (key, value) in spec.environment.sorted(by: { $0.key < $1.key }) {
            args += ["--env", "\(key)=\(value)"]
        }
        args += ["-i", "-t", spec.image, "bash", "-lc", spec.command]
        return args
    }
}

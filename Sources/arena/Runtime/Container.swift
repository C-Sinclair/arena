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

    /// `container image ls --format json` carries the reference at `configuration.name`, as
    /// one `name:tag` string. There is no top-level `name` or `tag`. Decoding for those threw,
    /// `imageExists` swallowed the error and answered false, and every `arena new` rebuilt an
    /// image that was already present.
    struct Image: Decodable {
        let reference: String

        private enum RootKeys: String, CodingKey { case configuration }
        private enum ConfigKeys: String, CodingKey { case name }

        init(from decoder: Decoder) throws {
            let root = try decoder.container(keyedBy: RootKeys.self)
            let config = try root.nestedContainer(keyedBy: ConfigKeys.self, forKey: .configuration)
            reference = try config.decode(String.self, forKey: .name)
        }
    }

    // MARK: - Queries

    static func instances(all: Bool = true) throws -> [Instance] {
        var args = ["ls", "--format", "json"]
        if all { args.append("--all") }
        let json = try Shell.run(binary, args)
        return try JSONDecoder().decode([Instance].self, from: Data(json.utf8))
    }

    static func images() throws -> [Image] {
        let json = try Shell.run(binary, ["image", "ls", "--format", "json"])
        return try JSONDecoder().decode([Image].self, from: Data(json.utf8))
    }

    /// Answering false rebuilds, so a decode failure here costs a full image build rather
    /// than an error. Say so on stderr instead of letting it look like a cache miss.
    static func imageExists(name: String, tag: String) -> Bool {
        let listed: [Image]
        do {
            listed = try images()
        } catch {
            FileHandle.standardError.write(
                Data("arena: could not read `container image ls`: \(error)\n".utf8))
            return false
        }

        let wanted = Self.unqualified(name)
        return listed.contains { image in
            let reference = ImageResolver.split(image.reference)
            return Self.unqualified(reference.name) == wanted && reference.tag == tag
        }
    }

    /// An image pulled from Docker Hub is listed registry-qualified, so `alpine:latest` in
    /// `arena.baseImage` has to match `docker.io/library/alpine:latest`.
    private static func unqualified(_ name: String) -> String {
        for prefix in ["docker.io/library/", "docker.io/"] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
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

    /// A second process in a sandbox that is already up. `container exec` takes none of the
    /// mounts or resources, which the running container already has, so this shares only the
    /// pty flags and the environment the agent needs with `runArguments`.
    static func execArguments(
        id: String,
        workdir: URL?,
        environment: [String: String],
        command: String
    ) -> [String] {
        var args = ["exec", "-i", "-t"]
        if let workdir { args += ["--workdir", workdir.path] }
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            args += ["--env", "\(key)=\(value)"]
        }
        args += [id, "bash", "-lc", command]
        return args
    }
}

import Foundation

/// Which image a sandbox runs, and building it when the repository declares its own.
///
/// A repository states its toolchain by committing `.arena/Dockerfile`, rather than every
/// sandbox carrying a browser and a database it will never start. See ADR-004.
struct ImageResolver {
    /// Used only when a repository declares no Dockerfile of its own. There is no image every
    /// machine already has, so this is a name rather than a promise: set `arena.baseImage` in
    /// git config, or `ARENA_BASE_IMAGE`, to point at whatever carries your agent and
    /// toolchain.
    static let defaultBaseImage = "agent-base:latest"
    static let defaultDockerfile = ".arena/Dockerfile"

    let repository: Repository
    let worktree: URL

    /// A path from `--dockerfile`, which beats both `arena.dockerfile` and the conventional
    /// path. Unlike those, a path named here that does not exist is an error rather than a
    /// fallback to the base image: silently ignoring an explicit request is the failure
    /// ADR-004 records, in a different costume.
    var dockerfileOverride: String?

    var baseImage: String {
        repository.config("arena.baseImage")
            ?? ProcessInfo.processInfo.environment["ARENA_BASE_IMAGE"]
            ?? Self.defaultBaseImage
    }

    /// The worktree is checked before the repository root, so a branch that changes its own
    /// Dockerfile is sandboxed with the image that branch describes rather than the default
    /// branch's.
    func dockerfile() throws -> URL? {
        if let override = dockerfileOverride {
            guard let found = locate(override) else {
                throw ArenaError.buildFailed("no Dockerfile at \(override)")
            }
            return found
        }
        return locate(repository.config("arena.dockerfile") ?? Self.defaultDockerfile)
    }

    /// An absolute path is taken as given. A relative one is looked for in the worktree and
    /// then the repository root, so a branch that changes its own Dockerfile is sandboxed
    /// with the image that branch describes rather than the default branch's.
    private func locate(_ path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath

        if expanded.hasPrefix("/") {
            let absolute = URL(fileURLWithPath: expanded)
            return FileManager.default.fileExists(atPath: absolute.path) ? absolute : nil
        }

        for base in [worktree, repository.root] {
            let candidate = base.appendingPathComponent(expanded)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The tag carries a digest of the Dockerfile rather than `latest`, because a per-repo
    /// `latest` already present is indistinguishable from one built by the Dockerfile in
    /// front of us. Tagged `latest`, an edited Dockerfile silently keeps running the old
    /// image, which is exactly the failure this project hit in fish.
    func resolve(rebuild: Bool) throws -> String {
        guard let dockerfile = try dockerfile() else { return try resolveBaseImage() }

        let name = "arena-\(repository.name)"
        let tag = String(try SHA256.hexDigest(ofFileAt: dockerfile).prefix(12))

        if rebuild || !ContainerRuntime.imageExists(name: name, tag: tag) {
            FileHandle.standardError.write(Data("arena: building \(name):\(tag)\n".utf8))
            try ContainerRuntime.build(
                tag: "\(name):\(tag)", dockerfile: dockerfile, context: repository.root)
        }
        return "\(name):\(tag)"
    }

    /// A missing base image otherwise reaches the user as a registry pull failure from inside
    /// `container run`, which names the image but not the reason arena chose it.
    private func resolveBaseImage() throws -> String {
        let image = baseImage
        let (name, tag) = Self.split(image)
        guard ContainerRuntime.imageExists(name: name, tag: tag) else {
            throw ArenaError.buildFailed(
                """
                no \(Self.defaultDockerfile) in this repository, and the base image \(image) \
                is not present.
                Commit a \(Self.defaultDockerfile) describing this project's toolchain, or \
                point arena at an image you already have:
                    git config arena.baseImage <image>
                """)
        }
        return image
    }

    /// `name:tag`, defaulting the tag the way a registry client does. A colon in the final
    /// path segment is a tag; one before a slash is a registry port.
    static func split(_ image: String) -> (name: String, tag: String) {
        guard let colon = image.lastIndex(of: ":"),
            !image[image.index(after: colon)...].contains("/")
        else { return (image, "latest") }
        return (
            String(image[image.startIndex..<colon]),
            String(image[image.index(after: colon)...])
        )
    }
}

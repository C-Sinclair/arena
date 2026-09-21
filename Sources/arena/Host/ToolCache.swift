import Foundation

/// A host tool the sandbox should have too, fetched as a Linux build of the same version.
///
/// A macOS binary cannot run in the guest, and a tool installed by each repository's own
/// Dockerfile drifts from the host's: memex reads an index the host wrote, and 0.23.1
/// opening a 0.12.2 index refuses with "term dictionaries this build cannot read". Deriving
/// the version from the host copy is what makes that skew impossible.
struct HostTool {
    /// Where the version to fetch comes from.
    enum Version {
        /// Whatever `<name> --version` reports on the host. For a tool that shares state
        /// with the host copy, this is the only safe answer.
        case matchingHost
        /// A release named here. For a tool that shares nothing, and whose host copy is
        /// built from a branch and so reports a version no release carries.
        case pinned(String)
        /// The commit the working tree is on. Only for `.containerBuild`, where the thing
        /// being cached is a build of that tree rather than a published artifact.
        case sourceRevision
    }

    enum Source {
        /// An asset on a GitHub release, downloaded with `gh`.
        case githubRelease(
            repository: String,
            /// The release tag. `{version}` is substituted.
            tag: String,
            /// `{version}` and `{arch}` are substituted.
            asset: String,
            /// What the project calls arm64 and x86_64 in its asset names.
            archNames: (arm64: String, intel: String),
            /// The binary's path inside the archive.
            pathInArchive: String)

        /// Built from a working tree on the host, in a container. For a tool whose
        /// published releases are not the code the host runs.
        case containerBuild(
            /// A `git config` key naming the working tree. Unset means the tool is skipped.
            sourceConfigKey: String,
            /// The builder image. It must produce a binary the sandbox image can run.
            image: String,
            /// Run with `sh -c`, with the source read-only at /src and a persistent build
            /// directory at /out.
            command: String,
            /// The binary's path under /out once the command has run.
            artifact: String)
    }

    let name: String
    let version: Version
    let source: Source

    /// Matched to the host, because the two share an index and 0.23.1 refuses to open one
    /// 0.12.2 wrote. See docs/friction/FF-210926.
    static let memex = HostTool(
        name: "memex",
        version: .matchingHost,
        source: .githubRelease(
            repository: "nicosuave/memex",
            tag: "v{version}",
            asset: "memex-{version}-linux-{arch}.tar.gz",
            archNames: (arm64: "arm64", intel: "x86_64"),
            pathInArchive: "memex")
    )

    /// Pinned: the host copy answers `vale version master`, which names no release.
    static let vale = HostTool(
        name: "vale",
        version: .pinned("3.22.0"),
        source: .githubRelease(
            repository: "errata-ai/vale",
            tag: "v{version}",
            asset: "vale_{version}_Linux_{arch}.tar.gz",
            archNames: (arm64: "arm64", intel: "64-bit"),
            pathInArchive: "vale")
    )

    /// Pinned: the host copy is a build from a branch, `4.1.0-293-g819759840`. The Linux
    /// asset is one static binary, so nothing else has to be installed beside it.
    static let fish = HostTool(
        name: "fish",
        version: .pinned("4.9.3"),
        source: .githubRelease(
            repository: "fish-shell/fish-shell",
            tag: "{version}",
            asset: "fish-{version}-linux-{arch}.tar.xz",
            archNames: (arm64: "aarch64", intel: "x86_64"),
            pathInArchive: "fish")
    )

    /// Built rather than downloaded. The releases carrying a linux-musl asset belong to
    /// `lukeed/lane`, and the fork the host runs sits 16 commits either side of v0.2.0, so
    /// upstream's binary would be a different `lane` from the host's, and lane is what cuts
    /// worktrees. The version is the working tree's commit, so moving the fork on rebuilds.
    ///
    /// `git config arena.laneSource <path>` names the tree. Unset, lane is skipped.
    ///
    /// rust:alpine targets musl natively, which gives a static binary that runs whatever
    /// the sandbox image is. `sh -c` rather than `sh -lc`: a login shell replaces the PATH
    /// the image set, and cargo lives on the image's.
    static let lane = HostTool(
        name: "lane",
        version: .sourceRevision,
        source: .containerBuild(
            sourceConfigKey: "arena.laneSource",
            image: "rust:alpine",
            command: "export PATH=/usr/local/cargo/bin:$PATH"
                + " && apk add --no-cache musl-dev >/dev/null"
                + " && cd /src && cargo build --release --locked",
            artifact: "target/release/lane")
    )

    /// Everything a sandbox gets. A new tool is an entry here.
    static let all: [HostTool] = [.memex, .vale, .fish, .lane]
}

/// Linux builds of host tools, under `~/.arena/tools`, mounted read-only into every sandbox.
///
/// The layout is `<name>/<version>/<name>`, with `bin/<name>` a *relative* symlink into it.
/// Relative matters: an absolute one would name a host path the container does not mount,
/// and the link would dangle inside the sandbox.
struct ToolCache {
    static let guestRoot = "/opt/arena/tools"
    static let guestBin = guestRoot + "/bin"

    let root: URL

    private let fileManager = FileManager.default

    init() throws {
        root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".arena/tools")
        try fileManager.createDirectory(
            at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
    }

    /// Fetches the tool if the cache does not already hold the host's version, and points
    /// `bin/<name>` at it. Returns the version linked, or nil when the host does not have
    /// the tool at all, which is not an error: a sandbox without memex still works.
    @discardableResult
    func link(_ tool: HostTool) throws -> String? {
        guard case .containerBuild(let key, _, _, _) = tool.source else {
            guard let version = try resolvedVersion(tool, sourceTree: nil) else { return nil }
            return try cache(tool, version: version) { binary in
                print("arena: fetching \(tool.name) \(version) for the sandbox")
                try download(tool, version: version, to: binary)
            }
        }

        guard let sourceTree = Self.configuredPath(key) else { return nil }
        guard let version = try resolvedVersion(tool, sourceTree: sourceTree) else { return nil }
        return try cache(tool, version: version) { binary in
            print("arena: building \(tool.name) \(version) for the sandbox, from \(key)")
            try build(tool, version: version, from: sourceTree, to: binary)
        }
    }

    /// Builds the path, runs `produce` when nothing is cached there, and relinks.
    private func cache(
        _ tool: HostTool, version: String, produce: (URL) throws -> Void
    ) throws -> String {
        let binary =
            root
            .appendingPathComponent(tool.name)
            .appendingPathComponent(version)
            .appendingPathComponent(tool.name)

        if !fileManager.isExecutableFile(atPath: binary.path) {
            try produce(binary)
        }

        try relink(tool.name, to: "../\(tool.name)/\(version)/\(tool.name)")
        return version
    }

    private func resolvedVersion(_ tool: HostTool, sourceTree: URL?) throws -> String? {
        switch tool.version {
        case .matchingHost:
            return Self.hostVersion(of: tool.name)
        case .pinned(let pinned):
            return pinned
        case .sourceRevision:
            guard let sourceTree else { return nil }
            return try? Shell.run(
                "git", ["-C", sourceTree.path, "rev-parse", "--short", "HEAD"])
        }
    }

    /// A path from `git config`, expanded. Absent means the caller skips the tool, which is
    /// how a machine without that working tree gets a sandbox anyway.
    private static func configuredPath(_ key: String) -> URL? {
        guard let value = try? Shell.run("git", ["config", "--global", "--get", key]),
            !value.isEmpty
        else { return nil }
        let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `memex --version` prints `memex 0.23.1`. A tool that is absent, or that answers in
    /// some other shape, is skipped rather than guessed at.
    private static func hostVersion(of name: String) -> String? {
        guard let output = try? Shell.run(name, ["--version"]) else { return nil }
        let fields = output.split(separator: " ")
        guard fields.count >= 2 else { return nil }
        return String(fields[1])
    }

    /// Builds in a container, with the source read-only and a build directory that outlives
    /// the run, so a later build of a moved working tree is incremental rather than cold.
    private func build(_ tool: HostTool, version: String, from source: URL, to binary: URL) throws {
        guard case .containerBuild(_, let image, let command, let artifact) = tool.source else {
            return
        }

        let output = root.appendingPathComponent(".build").appendingPathComponent(tool.name)
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)

        try Shell.run(
            ContainerRuntime.binary,
            [
                "run", "--rm",
                "--volume", "\(source.path):/src:ro",
                "--volume", "\(output.path):/out",
                "--env", "CARGO_TARGET_DIR=/out/target",
                image, "sh", "-c", command,
            ])

        let built = output.appendingPathComponent(artifact)
        guard fileManager.isReadableFile(atPath: built.path) else {
            throw ArenaError.laneFailed(
                "\(tool.name) \(version): the build left no \(artifact) under \(output.path)")
        }

        try fileManager.createDirectory(
            at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: binary)
        try fileManager.copyItem(at: built, to: binary)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }

    private func download(_ tool: HostTool, version: String, to binary: URL) throws {
        guard
            case .githubRelease(
                let repository, let tagTemplate, let assetTemplate, let archNames,
                let pathInArchive) = tool.source
        else { return }

        let arch = Self.guestIsARM64 ? archNames.arm64 : archNames.intel
        func substituted(_ template: String) -> String {
            template
                .replacingOccurrences(of: "{version}", with: version)
                .replacingOccurrences(of: "{arch}", with: arch)
        }

        let tag = substituted(tagTemplate)
        let asset = substituted(assetTemplate)

        let staging = root.appendingPathComponent(".staging-\(tool.name)-\(version)")
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        // `gh` rather than `curl`, because a release asset in a private repository answers
        // an unauthenticated request with a failed transfer rather than a 404. lane is
        // private, and curl reported only `exited 56`.
        try Shell.run(
            "gh",
            [
                "release", "download", tag,
                "--repo", repository,
                "--pattern", asset,
                "--dir", staging.path,
            ])

        // `-xf` rather than `-xzf`: fish ships .tar.xz where the others ship .tar.gz, and
        // bsdtar picks the decompressor from the content.
        let archive = staging.appendingPathComponent(asset)
        try Shell.run("tar", ["-xf", archive.path, "-C", staging.path])

        let extracted = staging.appendingPathComponent(pathInArchive)
        guard fileManager.isReadableFile(atPath: extracted.path) else {
            throw ArenaError.laneFailed(
                "\(tool.name) \(version): \(asset) holds no \(pathInArchive)")
        }

        try fileManager.createDirectory(
            at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: binary)
        try fileManager.moveItem(at: extracted, to: binary)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }

    private func relink(_ name: String, to target: String) throws {
        let link = root.appendingPathComponent("bin").appendingPathComponent(name)
        if let existing = try? fileManager.destinationOfSymbolicLink(atPath: link.path) {
            if existing == target { return }
            try fileManager.removeItem(at: link)
        }
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target)
    }

    /// The guest is the same architecture as the host; Apple container does not emulate.
    private static var guestIsARM64: Bool {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return machine == "arm64"
    }
}

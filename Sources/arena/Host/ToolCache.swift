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
    }

    let name: String
    let version: Version
    /// `owner/repo` on GitHub.
    let repository: String
    /// The release tag. `{version}` is substituted.
    let tag: String
    /// The asset to download. `{version}` and `{arch}` are substituted.
    let asset: String
    /// What the project calls arm64 and x86_64 in its asset names, in that order.
    let archNames: (arm64: String, intel: String)
    /// The binary's path inside the archive.
    let pathInArchive: String

    /// Matched to the host, because the two share an index and 0.23.1 refuses to open one
    /// 0.12.2 wrote. See docs/friction/FF-210926.
    static let memex = HostTool(
        name: "memex",
        version: .matchingHost,
        repository: "nicosuave/memex",
        tag: "v{version}",
        asset: "memex-{version}-linux-{arch}.tar.gz",
        archNames: (arm64: "arm64", intel: "x86_64"),
        pathInArchive: "memex"
    )

    /// Pinned: the host copy answers `vale version master`, which names no release.
    static let vale = HostTool(
        name: "vale",
        version: .pinned("3.22.0"),
        repository: "errata-ai/vale",
        tag: "v{version}",
        asset: "vale_{version}_Linux_{arch}.tar.gz",
        archNames: (arm64: "arm64", intel: "64-bit"),
        pathInArchive: "vale"
    )

    /// Pinned: the host copy is a build from a branch, `4.1.0-293-g819759840`. The Linux
    /// asset is one static binary, so nothing else has to be installed beside it.
    static let fish = HostTool(
        name: "fish",
        version: .pinned("4.9.3"),
        repository: "fish-shell/fish-shell",
        tag: "{version}",
        asset: "fish-{version}-linux-{arch}.tar.xz",
        archNames: (arm64: "aarch64", intel: "x86_64"),
        pathInArchive: "fish"
    )

    /// Not in `all`, and not shipped. The releases carrying a linux-musl asset belong to
    /// `lukeed/lane`; the fork the host runs, `C-Sinclair/lane`, publishes none and sits 16
    /// commits either side of v0.2.0. Shipping upstream's binary would put a different
    /// `lane` in the sandbox from the one on the host, and lane is what cuts worktrees.
    /// Cutting a release on the fork with a `lane-{arch}-unknown-linux-musl.tar.gz` asset
    /// is all this needs; then change the repository below and add it to `all`.
    static let lane = HostTool(
        name: "lane",
        version: .pinned("0.2.0"),
        repository: "C-Sinclair/lane",
        tag: "v{version}",
        asset: "lane-{arch}-unknown-linux-musl.tar.gz",
        archNames: (arm64: "aarch64", intel: "x86_64"),
        pathInArchive: "lane"
    )

    /// Everything a sandbox gets. A new tool is an entry here.
    static let all: [HostTool] = [.memex, .vale, .fish]
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
        let version: String
        switch tool.version {
        case .matchingHost:
            guard let hosted = Self.hostVersion(of: tool.name) else { return nil }
            version = hosted
        case .pinned(let pinned):
            version = pinned
        }

        let binary =
            root
            .appendingPathComponent(tool.name)
            .appendingPathComponent(version)
            .appendingPathComponent(tool.name)

        if !fileManager.isExecutableFile(atPath: binary.path) {
            print("arena: fetching \(tool.name) \(version) for the sandbox")
            try fetch(tool, version: version, to: binary)
        }

        try relink(tool.name, to: "../\(tool.name)/\(version)/\(tool.name)")
        return version
    }

    /// `memex --version` prints `memex 0.23.1`. A tool that is absent, or that answers in
    /// some other shape, is skipped rather than guessed at.
    private static func hostVersion(of name: String) -> String? {
        guard let output = try? Shell.run(name, ["--version"]) else { return nil }
        let fields = output.split(separator: " ")
        guard fields.count >= 2 else { return nil }
        return String(fields[1])
    }

    private func fetch(_ tool: HostTool, version: String, to binary: URL) throws {
        let arch = Self.guestIsARM64 ? tool.archNames.arm64 : tool.archNames.intel
        func substituted(_ template: String) -> String {
            template
                .replacingOccurrences(of: "{version}", with: version)
                .replacingOccurrences(of: "{arch}", with: arch)
        }

        let tag = substituted(tool.tag)
        let asset = substituted(tool.asset)

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
                "--repo", tool.repository,
                "--pattern", asset,
                "--dir", staging.path,
            ])

        // `-xf` rather than `-xzf`: fish ships .tar.xz where the others ship .tar.gz, and
        // bsdtar picks the decompressor from the content.
        let archive = staging.appendingPathComponent(asset)
        try Shell.run("tar", ["-xf", archive.path, "-C", staging.path])

        let extracted = staging.appendingPathComponent(tool.pathInArchive)
        guard fileManager.isReadableFile(atPath: extracted.path) else {
            throw ArenaError.laneFailed(
                "\(tool.name) \(version): \(asset) holds no \(tool.pathInArchive)")
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

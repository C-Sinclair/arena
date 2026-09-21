import Foundation

/// A host tool the sandbox should have too, fetched as a Linux build of the same version.
///
/// A macOS binary cannot run in the guest, and a tool installed by each repository's own
/// Dockerfile drifts from the host's: memex reads an index the host wrote, and 0.23.1
/// opening a 0.12.2 index refuses with "term dictionaries this build cannot read". Deriving
/// the version from the host copy is what makes that skew impossible.
struct HostTool {
    let name: String
    /// `{version}` and `{arch}` are substituted. `{arch}` is `arm64` or `x86_64`.
    let releaseURL: String
    /// The binary's path inside the archive.
    let pathInArchive: String

    static let memex = HostTool(
        name: "memex",
        releaseURL:
            "https://github.com/nicosuave/memex/releases/download/v{version}/"
            + "memex-{version}-linux-{arch}.tar.gz",
        pathInArchive: "memex"
    )
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
        guard let version = Self.hostVersion(of: tool.name) else { return nil }

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
        let url =
            tool.releaseURL
            .replacingOccurrences(of: "{version}", with: version)
            .replacingOccurrences(of: "{arch}", with: Self.guestArchitecture)

        let staging = root.appendingPathComponent(".staging-\(tool.name)-\(version)")
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let archive = staging.appendingPathComponent("archive.tar.gz")
        try Shell.run("curl", ["--fail", "--silent", "--location", "--output", archive.path, url])
        try Shell.run("tar", ["-xzf", archive.path, "-C", staging.path])

        let extracted = staging.appendingPathComponent(tool.pathInArchive)
        guard fileManager.isReadableFile(atPath: extracted.path) else {
            throw ArenaError.laneFailed(
                "\(tool.name) \(version) archive has no \(tool.pathInArchive); "
                    + "downloaded from \(url)")
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
    private static var guestArchitecture: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return machine == "arm64" ? "arm64" : "x86_64"
    }
}

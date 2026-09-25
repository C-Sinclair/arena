import Foundation
import Testing

@testable import arena

/// A throwaway git repository on disk, so the resolver is exercised against real files and a
/// real `git config` rather than a stub of them.
private struct TemporaryRepository: ~Copyable {
    let root: URL
    let worktree: URL

    init() throws {
        _ = GitIsolation.enabled
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arena-tests-\(UUID().uuidString)")
        worktree = root.appendingPathComponent(".lane/trees/demo")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Shell.run("git", ["-C", root.path, "init", "--quiet"])
    }

    var repository: Repository { Repository(root: root, isGitRepository: true) }

    func write(_ contents: String, to relative: String, under base: URL) throws {
        let file = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

@Suite("Dockerfile resolution")
struct ImageResolverTests {
    @Test("a repository with no Dockerfile resolves to none")
    func noDockerfile() throws {
        let temporary = try TemporaryRepository()
        let resolver = ImageResolver(repository: temporary.repository, worktree: temporary.worktree)
        #expect(try resolver.dockerfile() == nil)
    }

    @Test("the repository root is used when the worktree has none")
    func fallsBackToRoot() throws {
        let temporary = try TemporaryRepository()
        try temporary.write("FROM base", to: ".arena/Dockerfile", under: temporary.root)

        let resolver = ImageResolver(repository: temporary.repository, worktree: temporary.worktree)
        #expect(try resolver.dockerfile()?.path.hasPrefix(temporary.root.path) == true)
        #expect(try resolver.dockerfile()?.path.contains(".lane") == false)
    }

    /// The failure ADR-004 records. A Dockerfile written into a worktree was never found,
    /// because the resolver looked only at the repository root, and the sandbox silently ran
    /// the base image instead.
    @Test("the worktree wins over the repository root")
    func worktreeTakesPrecedence() throws {
        let temporary = try TemporaryRepository()
        try temporary.write("FROM base", to: ".arena/Dockerfile", under: temporary.root)
        try temporary.write("FROM branch", to: ".arena/Dockerfile", under: temporary.worktree)

        let resolver = ImageResolver(repository: temporary.repository, worktree: temporary.worktree)
        let found = try #require(try resolver.dockerfile())
        #expect(try String(contentsOf: found, encoding: .utf8) == "FROM branch")
    }

    @Test("git config arena.dockerfile overrides the conventional path")
    func configuredPath() throws {
        let temporary = try TemporaryRepository()
        try temporary.write("FROM elsewhere", to: "ci/sandbox.Dockerfile", under: temporary.root)
        try Shell.run(
            "git",
            ["-C", temporary.root.path, "config", "arena.dockerfile", "ci/sandbox.Dockerfile"])

        let resolver = ImageResolver(repository: temporary.repository, worktree: temporary.worktree)
        let found = try #require(try resolver.dockerfile())
        #expect(found.lastPathComponent == "sandbox.Dockerfile")
    }

    @Test("git config arena.baseImage overrides the default base")
    func configuredBaseImage() throws {
        let temporary = try TemporaryRepository()
        let resolver = ImageResolver(repository: temporary.repository, worktree: temporary.worktree)
        #expect(resolver.baseImage == ImageResolver.defaultBaseImage)

        try Shell.run("git", ["-C", temporary.root.path, "config", "arena.baseImage", "mine:v2"])
        #expect(resolver.baseImage == "mine:v2")
    }

    /// The other failure ADR-004 records. Tagged `latest`, an edited Dockerfile silently kept
    /// running the old image; the tag has to move when the file does.
    @Test("editing the Dockerfile changes the digest the image is tagged with")
    func digestFollowsContent() throws {
        let temporary = try TemporaryRepository()
        let file = temporary.root.appendingPathComponent(".arena/Dockerfile")
        try temporary.write("FROM base", to: ".arena/Dockerfile", under: temporary.root)
        let before = try SHA256.hexDigest(ofFileAt: file)

        try temporary.write(
            "FROM base\nRUN apt-get update", to: ".arena/Dockerfile", under: temporary.root)
        let after = try SHA256.hexDigest(ofFileAt: file)

        #expect(before != after)
    }
}

@Suite("--dockerfile override")
struct DockerfileOverrideTests {
    @Test("an explicit path beats the conventional one")
    func beatsConvention() throws {
        let temporary = try TemporaryRepository()
        try temporary.write("FROM conventional", to: ".arena/Dockerfile", under: temporary.root)
        try temporary.write("FROM explicit", to: "ci/other.Dockerfile", under: temporary.root)

        var resolver = ImageResolver(
            repository: temporary.repository, worktree: temporary.worktree)
        resolver.dockerfileOverride = "ci/other.Dockerfile"

        let found = try #require(try resolver.dockerfile())
        #expect(try String(contentsOf: found, encoding: .utf8) == "FROM explicit")
    }

    @Test("an explicit path beats git config too")
    func beatsGitConfig() throws {
        let temporary = try TemporaryRepository()
        try temporary.write("FROM configured", to: "a.Dockerfile", under: temporary.root)
        try temporary.write("FROM explicit", to: "b.Dockerfile", under: temporary.root)
        try Shell.run(
            "git", ["-C", temporary.root.path, "config", "arena.dockerfile", "a.Dockerfile"])

        var resolver = ImageResolver(
            repository: temporary.repository, worktree: temporary.worktree)
        resolver.dockerfileOverride = "b.Dockerfile"

        let found = try #require(try resolver.dockerfile())
        #expect(found.lastPathComponent == "b.Dockerfile")
    }

    /// The distinction that makes the flag safe: a conventional path that is absent means
    /// "this repository has no image of its own", but an explicit one that is absent means
    /// the caller asked for something that is not there.
    @Test("an explicit path that does not exist is an error, not a fallback")
    func missingIsAnError() throws {
        let temporary = try TemporaryRepository()
        var resolver = ImageResolver(
            repository: temporary.repository, worktree: temporary.worktree)
        resolver.dockerfileOverride = "nowhere/Dockerfile"

        #expect(throws: ArenaError.self) { try resolver.dockerfile() }
    }

    @Test("the worktree is still preferred for a relative explicit path")
    func relativeStillPrefersWorktree() throws {
        let temporary = try TemporaryRepository()
        try temporary.write("FROM root", to: "ci/box.Dockerfile", under: temporary.root)
        try temporary.write("FROM branch", to: "ci/box.Dockerfile", under: temporary.worktree)

        var resolver = ImageResolver(
            repository: temporary.repository, worktree: temporary.worktree)
        resolver.dockerfileOverride = "ci/box.Dockerfile"

        let found = try #require(try resolver.dockerfile())
        #expect(try String(contentsOf: found, encoding: .utf8) == "FROM branch")
    }
}

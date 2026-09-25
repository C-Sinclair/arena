import Foundation
import Testing

@testable import arena

@Suite("Lane containing a directory")
struct LaneContainingTests {
    private let lanes = [
        Repository.Lane(name: "probe", path: "/repo/.lane/trees/probe"),
        Repository.Lane(name: "probe-2", path: "/repo/.lane/trees/probe-2"),
        Repository.Lane(name: "inner", path: "/repo/.lane/trees/probe/inner"),
    ]

    private func lane(_ path: String) -> String? {
        Repository.lane(in: lanes, containing: URL(fileURLWithPath: path))?.name
    }

    @Test("the lane's own root resolves to it")
    func root() {
        #expect(lane("/repo/.lane/trees/probe") == "probe")
    }

    @Test("a directory below the lane resolves to it")
    func nested() {
        #expect(lane("/repo/.lane/trees/probe/lib/deep") == "probe")
    }

    /// Without comparing on a separator, `probe-2` is read as being inside `probe`, and
    /// `arena @` attaches to the wrong sandbox.
    @Test("a lane sharing a name prefix is not mistaken for its neighbour")
    func siblingPrefix() {
        #expect(lane("/repo/.lane/trees/probe-2/lib") == "probe-2")
    }

    /// Both lanes contain the path; the nearer one is the answer.
    @Test("a lane nested in another resolves to the inner one")
    func nestedLanes() {
        #expect(lane("/repo/.lane/trees/probe/inner/src") == "inner")
    }

    @Test("a directory outside every lane resolves to nothing")
    func outside() {
        #expect(lane("/repo/src") == nil)
    }

    @Test("a path needing standardizing still matches")
    func unstandardized() {
        #expect(lane("/repo/.lane/trees/probe/lib/../lib") == "probe")
    }
}

/// `discover` answers for a directory git does not track, because `arena .` runs against
/// one. See ADR-008.
@Suite("Discovery outside git")
struct DiscoveryOutsideGitTests {
    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arena-nongit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a directory git does not track discovers as itself")
    func rootIsTheDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = Repository.discover(from: directory)
        #expect(repository.isGitRepository == false)
        #expect(repository.root.path == directory.standardizedFileURL.path)
    }

    @Test("hereWorktree outside git is the directory itself")
    func hereWorktreeOutsideGit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(
            Repository.hereWorktree(from: directory).path
                == directory.standardizedFileURL.path)
    }

    @Test("lanes outside git is empty rather than an error")
    func noLanes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(Repository.discover(from: directory).lanes().isEmpty)
    }

    @Test("requireGit names the directory and points at `arena .`")
    func requireGitThrows() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = Repository.discover(from: directory)
        #expect(throws: ArenaError.self) { try repository.requireGit() }
    }

    @Test("requireGit passes inside a git repository")
    func requireGitPasses() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Shell.run("git", ["-C", directory.path, "init", "--quiet"])

        let repository = Repository.discover(from: directory)
        #expect(repository.isGitRepository)
        #expect(throws: Never.self) { try repository.requireGit() }
    }
}

/// `arena.mount` takes as many values as the user adds, so the reader has to be
/// `--get-all`. See ADR-009.
@Suite("Multi-valued config")
struct ConfigAllTests {
    /// A key of its own rather than `New.mountKey`. `configAll` reads the user's global
    /// config as well as the repository's, so a test asserting on `arena.mount` fails on
    /// the machine of anyone who has set one.
    private let key = "arena.testMount"

    private func repository() throws -> (Repository, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arena-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Shell.run("git", ["-C", root.path, "init", "--quiet"])
        return (Repository(root: root, isGitRepository: true), root)
    }

    @Test("every value of a repeated key is returned, in git's order")
    func allValues() throws {
        let (repository, root) = try self.repository()
        defer { try? FileManager.default.removeItem(at: root) }

        try Shell.run("git", ["-C", root.path, "config", "--add", key, "/a:ro"])
        try Shell.run("git", ["-C", root.path, "config", "--add", key, "/b"])

        #expect(repository.configAll(key) == ["/a:ro", "/b"])
    }

    @Test("a key that is not set returns nothing")
    func unset() throws {
        let (repository, root) = try self.repository()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(repository.configAll("arena.nothingSetHere").isEmpty)
    }
}

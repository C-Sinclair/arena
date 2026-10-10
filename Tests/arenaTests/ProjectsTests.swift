import Foundation
import Testing

@testable import arena

@Suite("arena projects")
struct ProjectsTests {
    private func makeRepos() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arena-projects-\(UUID().uuidString)")
        for path in [
            "acme/web/.arena", "acme/api", "C-Sinclair/dotfiles", ".hidden/x", "acme/.cache",
        ] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("acme/web/.arena/Dockerfile").path,
            contents: Data())
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("acme/README").path, contents: Data())
        return root
    }

    @Test("lists ORG/REPO directories, sorted, skipping hidden ones and files")
    func scan() throws {
        let repos = try makeRepos()
        defer { try? FileManager.default.removeItem(at: repos) }

        let projects = Projects.scan(repos: repos, running: [])
        #expect(projects.map(\.name) == ["C-Sinclair/dotfiles", "acme/api", "acme/web"])
        #expect(projects.map(\.hasDockerfile) == [false, false, true])
    }

    @Test("a sandbox is matched by its image or by arena .'s id")
    func running() {
        let running = [
            Projects.RunningSandbox(id: "fix-login", image: "arena-web:0123456789ab"),
            Projects.RunningSandbox(id: "dotfiles", image: "ghcr.io/me/base:latest"),
        ]
        #expect(Projects.isRunning("web", in: running))
        #expect(Projects.isRunning("dotfiles", in: running))
        #expect(!Projects.isRunning("api", in: running))
        #expect(!Projects.isRunning("we", in: running))
    }

    @Test("JSON uses snake_case keys")
    func json() throws {
        let project = Projects.Project(
            name: "acme/web", path: "/r/acme/web", hasDockerfile: true, sandboxRunning: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        #expect(
            String(decoding: try encoder.encode(project), as: UTF8.self)
                == #"{"has_dockerfile":true,"name":"acme/web","path":"/r/acme/web","sandbox_running":false}"#
        )
    }
}

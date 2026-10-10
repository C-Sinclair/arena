import ArgumentParser
import Foundation

/// `arena projects` — every repository under `~/Repos/ORG/REPO`, the paths `hop` accepts.
struct Projects: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "projects",
        abstract: "List the repositories under ~/Repos/ORG/REPO and whether a sandbox runs one."
    )

    @Flag(help: "Print JSON, one object per repository.")
    var json = false

    struct Project: Encodable, Equatable {
        let name: String
        let path: String
        let hasDockerfile: Bool
        let sandboxRunning: Bool

        enum CodingKeys: String, CodingKey {
            case name, path
            case hasDockerfile = "has_dockerfile"
            case sandboxRunning = "sandbox_running"
        }
    }

    struct RunningSandbox: Equatable {
        let id: String
        let image: String
    }

    func run() async throws {
        let repos = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Repos")
        // No `container` service is an answer here, not a fault: nothing is running.
        let running = ((try? ContainerRuntime.instances(all: false)) ?? [])
            .map { RunningSandbox(id: $0.id, image: $0.image) }
        let projects = Self.scan(repos: repos, running: running)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(projects), as: UTF8.self))
            return
        }

        let width = projects.map(\.name.count).max() ?? 0
        for project in projects {
            let name = project.name.padding(toLength: width, withPad: " ", startingAt: 0)
            let image = project.hasDockerfile ? "dockerfile" : "base      "
            let state = project.sandboxRunning ? "running" : "-"
            print("\(name)  \(image)  \(state)  \(project.path)")
        }
    }

    /// Hidden directories are skipped at both levels, as `BrokerProtocol.hopTarget` refuses
    /// them.
    static func scan(repos: URL, running: [RunningSandbox]) -> [Project] {
        let fileManager = FileManager.default
        func directories(in url: URL) -> [URL] {
            let entries =
                (try? fileManager.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles])) ?? []
            return entries.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
        }

        var projects: [Project] = []
        for organisation in directories(in: repos) {
            for repository in directories(in: organisation) {
                let dockerfile = repository.appendingPathComponent(".arena/Dockerfile")
                projects.append(
                    Project(
                        name: "\(organisation.lastPathComponent)/\(repository.lastPathComponent)",
                        path: repository.standardizedFileURL.path,
                        hasDockerfile: fileManager.fileExists(atPath: dockerfile.path),
                        sandboxRunning: isRunning(repository.lastPathComponent, in: running)))
            }
        }
        return projects.sorted { $0.name < $1.name }
    }

    /// A sandbox built from the repository's own Dockerfile runs `arena-<repo>:<digest>`,
    /// whatever its lane. One on a base image is recognised only by `arena .`'s id, which is
    /// the directory name; a lane of it on a base image is missed.
    static func isRunning(_ repository: String, in running: [RunningSandbox]) -> Bool {
        running.contains {
            $0.image.hasPrefix("arena-\(repository):") || $0.id == repository.asContainerID()
        }
    }
}

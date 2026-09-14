import ArgumentParser
import Foundation

struct Build: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build the repository's .arena/Dockerfile without launching a sandbox."
    )

    @Option(name: .long, help: "Resolve the Dockerfile as this lane would see it.")
    var lane: String?

    func run() async throws {
        let repository = try Repository.discover()
        let worktree = lane.flatMap { repository.lanePath($0) } ?? repository.root

        let resolver = ImageResolver(repository: repository, worktree: worktree)
        guard resolver.dockerfile() != nil else {
            print(
                "arena: no \(ImageResolver.defaultDockerfile) in this repository; "
                    + "sandboxes use the base image \(resolver.baseImage)")
            return
        }
        print(try resolver.resolve(rebuild: true))
    }
}

import ArgumentParser
import Foundation

struct Build: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build the repository's .arena/Dockerfile without launching a sandbox."
    )

    @Option(name: .long, help: "Resolve the Dockerfile as this lane would see it.")
    var lane: String?

    @OptionGroup var imageOptions: DockerfileOptions

    func run() async throws {
        let repository = Repository.discover()
        // The build itself needs no git, so a non-git directory builds its own
        // .arena/Dockerfile. `--lane` names a worktree, which does need git.
        if lane != nil { try repository.requireGit() }
        let worktree = lane.flatMap { repository.lanePath($0) } ?? repository.root

        var resolver = ImageResolver(repository: repository, worktree: worktree)
        resolver.dockerfileOverride = imageOptions.dockerfile

        guard try resolver.dockerfile() != nil else {
            print(
                "arena: no \(ImageResolver.defaultDockerfile) in this repository; "
                    + "sandboxes use the base image \(resolver.baseImage)")
            return
        }
        print(try resolver.resolve(rebuild: true))
    }
}

/// Shared by `new` and `build`, so the two cannot disagree about where a Dockerfile is.
struct DockerfileOptions: ParsableArguments {
    @Option(
        name: .long,
        help: ArgumentHelp(
            "Path to the Dockerfile, overriding .arena/Dockerfile and git config arena.dockerfile.",
            discussion: """
                Relative paths are looked for in the worktree first, then the repository root. \
                Unlike the conventional path, a --dockerfile that does not exist is an error \
                rather than a quiet fallback to the base image.
                """,
            valueName: "path"))
    var dockerfile: String?
}

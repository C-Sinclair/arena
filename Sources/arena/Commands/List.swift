import ArgumentParser
import Foundation

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List the sandboxes arena is running."
    )

    @Flag(name: .shortAndLong, help: "Include sandboxes that are not running.")
    var all = false

    func run() async throws {
        // A sandbox built from a repository's own Dockerfile is named for arena. One running
        // a base image is not distinguishable from any other container, so it is listed only
        // when arena cut a lane of that name.
        let lanes = Set(
            (try? Repository.discover().lanes().map { $0.name.asContainerID() }) ?? [])

        let instances = try ContainerRuntime.instances(all: all)
            .filter { $0.image.hasPrefix("arena-") || lanes.contains($0.id) }

        guard !instances.isEmpty else {
            print("no arena sandboxes")
            return
        }

        let width = instances.map { $0.id.count }.max() ?? 4
        for instance in instances.sorted(by: { $0.id < $1.id }) {
            let id = instance.id.padding(toLength: width, withPad: " ", startingAt: 0)
            print("\(id)  \(instance.state)  \(instance.image)")
        }
    }
}

import ArgumentParser
import Foundation

/// `arena broker` — reads the requests a sandbox writes into `/var/lib/arena/spawn`.
///
/// `arena new --herdr` starts one for every sandbox it launches, so this is run by hand only
/// to restart a broker that died.
struct BrokerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "broker",
        abstract: "Answer a sandbox's split, report and hop requests. Started by `new --herdr`."
    )

    @Option(help: "The repository's state directory, ~/.arena/state/<repo>.")
    var state: String

    @Option(help: "The sandbox's container id. The broker stops when it stops.")
    var sandbox: String

    @Option(help: "The Herdr pane the leader agent runs in.")
    var pane: String

    @Option(help: "The Herdr workspace hop tabs open in.")
    var workspace: String

    func run() async throws {
        try await Broker(
            state: URL(fileURLWithPath: state), sandbox: sandbox, leaderPane: pane,
            workspace: workspace
        ).run()
    }
}

import Foundation
import Testing

@testable import arena

@Suite("Broker split and report")
struct BrokerSplitTests {
    private let arguments = Broker.splitArguments(
        sandbox: "dotfiles", name: "fix/dig", model: "opus", effort: "xhigh")

    @Test("a split execs into the leader's own container")
    func sameContainer() {
        #expect(Array(arguments.prefix(3)) == ["exec", "-i", "-t"])
        #expect(arguments.suffix(4).first == "dotfiles")
    }

    @Test("the brief is read from a file, never passed as text")
    func briefFromFile() throws {
        let command = try #require(arguments.last)
        #expect(command.contains(#""$(cat /var/lib/arena/briefs/fix-dig.md)""#))
        #expect(command.contains("--model opus --effort xhigh"))
        #expect(command.contains("exec -a claude claude"))
    }

    @Test("the split agent can reach the broker too")
    func brokerFlag() {
        #expect(arguments.contains("ARENA_BROKER=1"))
    }

    @Test("the footer names the verb and the file the leader will read")
    func footer() {
        let footer = Broker.briefFooter(name: "fix/dig")
        #expect(footer.contains("arena-report fix/dig <file>"))
        #expect(footer.contains("/var/lib/arena/findings/fix-dig.md"))
    }

    @Test("the leader is told a guest path, never a host one")
    func message() {
        #expect(
            Broker.findingsMessage(name: "fix/dig")
                == "findings ready at /var/lib/arena/findings/fix-dig.md")
    }
}

@Suite("Herdr pane ids")
struct HerdrPaneIDTests {
    @Test("workspace create nests the pane under root_pane")
    func workspaceCreate() {
        let json = #"""
            {"result":{"workspace":{"workspace_id":"w1"},"tab":{"tab_id":"t1"},
            "root_pane":{"pane_id":"p1"}}}
            """#
        #expect(Herdr.paneID(in: json) == "p1")
    }

    @Test("a pane_id at any depth is found")
    func anyDepth() {
        #expect(Herdr.paneID(in: #"{"result":{"pane":{"pane_id":"p9"}}}"#) == "p9")
        #expect(Herdr.paneID(in: #"{"result":[{"pane_id":"p2"}]}"#) == "p2")
    }

    @Test("output that is not JSON, or has no pane, gives nothing")
    func none() {
        #expect(Herdr.paneID(in: "split ok") == nil)
        #expect(Herdr.paneID(in: #"{"result":{}}"#) == nil)
    }
}

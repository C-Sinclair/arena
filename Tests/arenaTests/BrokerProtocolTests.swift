import Foundation
import Testing

@testable import arena

@Suite("Broker request validation")
struct BrokerProtocolTests {
    private let home = URL(fileURLWithPath: "/Users/me")

    private func decode(_ json: String) throws -> BrokerRequest {
        try JSONDecoder().decode(BrokerRequest.self, from: Data(json.utf8))
    }

    private func validate(_ json: String) throws -> Result<BrokerAction, BrokerRejection> {
        BrokerProtocol.validate(try decode(json), home: home)
    }

    @Test("a split with no model or effort runs opus at xhigh")
    func splitDefaults() throws {
        #expect(
            try validate(#"{"kind":"split","name":"dig","brief":"look"}"#)
                == .success(.split(name: "dig", brief: "look", model: "opus", effort: "xhigh")))
    }

    @Test("a split names its own model and effort from the allow-lists")
    func splitChosen() throws {
        #expect(
            try validate(
                #"{"kind":"split","name":"dig","brief":"b","model":"sonnet","effort":"low"}"#)
                == .success(.split(name: "dig", brief: "b", model: "sonnet", effort: "low")))
    }

    @Test(
        "a split outside the allow-lists is refused",
        arguments: [
            #"{"kind":"split","name":"dig","brief":"b","model":"gpt"}"#,
            #"{"kind":"split","name":"dig","brief":"b","effort":"ultra"}"#,
            #"{"kind":"split","name":"dig","brief":"b","model":"opus --x"}"#,
            #"{"kind":"split","name":"dig","brief":""}"#,
            #"{"kind":"split","name":"dig"}"#,
        ])
    func splitRefused(json: String) throws {
        guard case .failure = try validate(json) else {
            Issue.record("accepted \(json)")
            return
        }
    }

    @Test("a brief over 64 KiB is refused")
    func briefTooLarge() throws {
        let brief = String(repeating: "x", count: BrokerProtocol.maximumBriefBytes + 1)
        let request = BrokerRequest(
            kind: "split", name: "dig", brief: brief, model: nil, effort: nil, path: nil)
        guard case .failure = BrokerProtocol.validate(request, home: home) else {
            Issue.record("accepted an oversized brief")
            return
        }
    }

    @Test(
        "names are held to arena-spawn's pattern",
        arguments: [
            ("dig", true), ("fix/login-bug", true), ("a.b_c-d", true),
            ("Dig", false), (".hidden", false), ("-x", false), ("", false),
            ("a b", false), ("a;rm", false), ("$(x)", false),
            (String(repeating: "a", count: 64), false),
        ])
    func names(name: String, valid: Bool) {
        #expect(BrokerProtocol.validName(name) == valid)
    }

    /// The pattern allows `/` and `.`, so a name alone can spell a traversal.
    @Test("a name's file name never climbs out of its directory")
    func fileNameFlattens() {
        #expect(BrokerProtocol.validName("a/../../etc"))
        #expect(BrokerProtocol.fileName("a/../../etc") == "a-..-..-etc")
    }

    @Test("a report needs only a valid name")
    func report() throws {
        #expect(try validate(#"{"kind":"report","name":"dig"}"#) == .success(.report(name: "dig")))
        guard case .failure = try validate(#"{"kind":"report","name":"../x"}"#) else {
            Issue.record("accepted a traversal")
            return
        }
    }

    @Test("an arena-spawn request with no kind is refused, as is an unknown kind")
    func kinds() throws {
        let spawn = #"{"name":"x","base":"","model":"opus","effort":"low","brief":"b"}"#
        #expect(try validate(spawn) == .failure(BrokerRejection(reason: "request has no kind")))
        guard case .failure = try validate(#"{"kind":"prompt","name":"x"}"#) else {
            Issue.record("accepted an unknown kind")
            return
        }
    }

    @Test(
        "a hop reaches exactly ~/Repos/ORG/REPO",
        arguments: [
            ("~/Repos/C-Sinclair/dotfiles", "/Users/me/Repos/C-Sinclair/dotfiles"),
            ("/Users/me/Repos/org/repo", "/Users/me/Repos/org/repo"),
            ("~/Repos/org/repo/", "/Users/me/Repos/org/repo"),
        ])
    func hopAccepted(path: String, expected: String) {
        #expect(BrokerProtocol.hopTarget(path, home: home)?.path == expected)
    }

    @Test(
        "a hop anywhere else is refused",
        arguments: [
            "~/Repos/org", "~/Repos/org/repo/sub", "~/Repos/../.ssh/x", "~/Repos/org/../../x/y",
            "/etc/passwd", "Repos/org/repo", "~/Repos/.hidden/repo", "~/Repos/org/.git",
            "/Users/other/Repos/org/repo", "~/Documents/org/repo",
        ])
    func hopRefused(path: String) {
        #expect(BrokerProtocol.hopTarget(path, home: home) == nil)
    }
}

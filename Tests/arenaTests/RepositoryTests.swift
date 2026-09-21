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

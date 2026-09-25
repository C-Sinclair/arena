import Foundation
import Testing

@testable import arena

@Suite("Sandbox id for `arena .`")
struct HereSandboxIDTests {
    @Test("the id is the worktree's directory name")
    func basename() {
        #expect(Here.sandboxID(URL(fileURLWithPath: "/Users/me/dotfiles")) == "dotfiles")
    }

    @Test("a trailing slash does not empty the id")
    func trailingSlash() {
        #expect(Here.sandboxID(URL(fileURLWithPath: "/Users/me/dotfiles/")) == "dotfiles")
    }

    @Test("a long directory name goes through the same truncation as a lane name")
    func long() {
        let name = String(repeating: "a", count: 200)
        #expect(Here.sandboxID(URL(fileURLWithPath: "/r/\(name)")) == name.asContainerID())
    }
}

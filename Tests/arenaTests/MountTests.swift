import Foundation
import Testing

@testable import arena

@Suite("Extra mounts and the sandbox's own")
struct MountDeduplicationTests {
    private func mount(_ path: String, readOnly: Bool = false) -> Mount {
        Mount(URL(fileURLWithPath: path), readOnly: readOnly)
    }

    private let base = [
        Mount(URL(fileURLWithPath: "/Users/me/repo")),
        Mount(URL(fileURLWithPath: "/Users/me/.arena/home"), at: "/home/agent"),
    ]

    private func guests(_ extra: [Mount]) -> [String] {
        New.deduplicated(base: base, extra: extra).map(\.guest)
    }

    @Test("an extra directory is added after the sandbox's own")
    func added() {
        #expect(guests([mount("/Users/me/Screenshots")]).last == "/Users/me/Screenshots")
    }

    /// The repository mount is the one a configured `arena.mount` most easily collides
    /// with: any repository under a configured directory is already mounted.
    @Test("an extra naming a path the sandbox already mounts is dropped")
    func collidesWithBase() {
        #expect(guests([mount("/Users/me/repo")]) == base.map(\.guest))
    }

    @Test("a path given twice is mounted once")
    func repeated() {
        let guests = guests([mount("/Users/me/Screenshots", readOnly: true), mount("/Users/me/Screenshots")])
        #expect(guests.filter { $0 == "/Users/me/Screenshots" }.count == 1)
    }

    /// `arena.mount` is read first, so the later value is `--mount`, and a launch that asks
    /// for write access to a directory configured read-only gets it.
    @Test("the last of two mounts for one path wins")
    func lastWins() {
        let result = New.deduplicated(
            base: base,
            extra: [
                mount("/Users/me/Screenshots", readOnly: true),
                mount("/Users/me/Screenshots"),
            ])
        #expect(result.last?.readOnly == false)
    }

    @Test("the sandbox's own mounts keep their order")
    func baseOrder() {
        #expect(guests([mount("/Users/me/Screenshots")]).prefix(2) == base.map(\.guest).prefix(2))
    }
}

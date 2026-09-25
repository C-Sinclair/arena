import Foundation
import Testing

@testable import arena

@Suite("Container id derivation")
struct ContainerIDTests {
    @Test("a plain name passes through")
    func plainName() {
        #expect("e2e".asContainerID() == "e2e")
    }

    @Test("slashes become hyphens, because a container id is a DNS label")
    func branchStyleName() {
        #expect("feature/e2e-in-a-box".asContainerID() == "feature-e2e-in-a-box")
    }

    @Test("an over-long name is digested rather than truncated")
    func overLongName() {
        let long = String(repeating: "a", count: 80)
        let id = long.asContainerID()
        #expect(id.utf8.count <= 63)
        // Deterministic, so a rerun resolves to the same sandbox.
        #expect(id == long.asContainerID())
    }

    @Test("two long names that share a prefix do not collide")
    func noPrefixCollision() {
        let a = String(repeating: "a", count: 60) + "-one"
        let b = String(repeating: "a", count: 60) + "-two"
        #expect(a.asContainerID() != b.asContainerID())
    }
}

@Suite("Mount specifications")
struct MountTests {
    @Test("a mount lands at its host path by default")
    func identityPath() {
        let mount = Mount(URL(fileURLWithPath: "/Users/x/repo"))
        #expect(mount.specification == "/Users/x/repo:/Users/x/repo")
    }

    @Test("read-only is a flag, not a string suffix the caller appends")
    func readOnly() {
        let mount = Mount(URL(fileURLWithPath: "/Users/x/dotfiles"), readOnly: true)
        #expect(mount.specification == "/Users/x/dotfiles:/Users/x/dotfiles:ro")
    }

    @Test("a remapped guest path is honoured")
    func remapped() {
        let mount = Mount(URL(fileURLWithPath: "/Users/x/.arena/home"), at: "/home/agent")
        #expect(mount.specification == "/Users/x/.arena/home:/home/agent")
    }
}

@Suite("Run arguments")
struct RunArgumentsTests {
    private var spec: SandboxSpec {
        SandboxSpec(
            name: "e2e",
            image: "arena-demo:abc123",
            workdir: URL(fileURLWithPath: "/repo/.lane/trees/e2e"),
            resources: Resources(),
            mounts: [Mount(URL(fileURLWithPath: "/repo"))],
            environment: ["GIT_CONFIG_COUNT": "3"],
            command: "true"
        )
    }

    @Test("the default sandbox is sized past Apple container's 1 GB and 64 MB /dev/shm")
    func resourceDefaults() {
        let args = ContainerRuntime.runArguments(spec: spec)
        #expect(args.contains("--memory"))
        #expect(args.contains("8g"))
        #expect(args.contains("--shm-size"))
        #expect(args.contains("2g"))
    }

    @Test("the image and command come last, after every option")
    func argumentOrder() throws {
        let args = ContainerRuntime.runArguments(spec: spec)
        let image = try #require(args.firstIndex(of: "arena-demo:abc123"))
        let volume = try #require(args.firstIndex(of: "--volume"))
        #expect(volume < image)
        #expect(args.last == "true")
    }
}

@Suite("Image reference splitting")
struct ImageSplitTests {
    @Test("a bare name defaults to latest")
    func bareName() {
        let (name, tag) = ImageResolver.split("agent-base")
        #expect(name == "agent-base")
        #expect(tag == "latest")
    }

    @Test("an explicit tag is taken")
    func explicitTag() {
        let (name, tag) = ImageResolver.split("arena-demo:abc123")
        #expect(name == "arena-demo")
        #expect(tag == "abc123")
    }

    @Test("a registry port is not mistaken for a tag")
    func registryPort() {
        let (name, tag) = ImageResolver.split("localhost:5000/agent-base")
        #expect(name == "localhost:5000/agent-base")
        #expect(tag == "latest")
    }
}

@Suite("Extra mount parsing")
struct ExtraMountTests {
    /// The parsing `--mount` does, isolated from the filesystem check around it.
    private func parse(_ specification: String) -> Mount {
        let readOnly = specification.hasSuffix(":ro")
        let path = readOnly ? String(specification.dropLast(3)) : specification
        return Mount(
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL,
            readOnly: readOnly)
    }

    @Test("a bare path mounts read-write at the same path")
    func bare() {
        #expect(parse("/tmp/notes").specification == "/tmp/notes:/tmp/notes")
    }

    @Test("a ':ro' suffix is a mount mode, not part of the path")
    func readOnlySuffix() {
        #expect(parse("/tmp/notes:ro").specification == "/tmp/notes:/tmp/notes:ro")
    }

    @Test("a tilde is expanded, so the guest path is real")
    func tilde() {
        let specification = parse("~/notes").specification
        #expect(!specification.contains("~"))
        #expect(specification.hasSuffix("/notes"))
    }
}

/// The shape is copied from `container image ls --format json` under container 1.3.1. Arena
/// decoded a top-level `name` and `tag` here, which threw and rebuilt every image.
@Suite("Image listing decode")
struct ImageListingTests {
    static let listing = """
        [
          {"configuration":{"name":"arena-demo:abc123"},"id":"sha256:1"},
          {"configuration":{"name":"docker.io/library/alpine:latest"},"id":"sha256:2"}
        ]
        """

    @Test("the reference comes from configuration.name")
    func decodesReference() throws {
        let images = try JSONDecoder().decode(
            [ContainerRuntime.Image].self, from: Data(Self.listing.utf8))
        #expect(
            images.map(\.reference) == ["arena-demo:abc123", "docker.io/library/alpine:latest"])
    }
}

@Suite("Agent command")
struct AgentCommandTests {
    @Test("the refreshed agent in the persistent home wins over the image's")
    func homeBinFirst() {
        #expect(New.command(agent: "claude").hasPrefix("export PATH=$HOME/.local/bin:"))
    }

    @Test("claude-refresh runs before arena-init, guarded for images without it")
    func refreshBeforeInit() throws {
        let command = New.command(agent: "claude")
        let refresh = try #require(
            command.range(of: "command -v claude-refresh >/dev/null && claude-refresh; "))
        let initialise = try #require(command.range(of: "arena-init"))
        #expect(refresh.lowerBound < initialise.lowerBound)
    }

    @Test("--update-claude forces a refresh through the environment")
    func updateClaudeEnvironment() throws {
        #expect(New.refreshOverrides(force: true) == ["ARENA_CLAUDE_REFRESH": "1"])
        #expect(New.refreshOverrides(force: false).isEmpty)
        let parsed = try New.parse(["e2e", "-U"])
        #expect(parsed.updateClaude)
    }
}

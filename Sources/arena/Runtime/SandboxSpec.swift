import Foundation

/// A bind mount, typed so a missing or misplaced `:ro` cannot be a silent string bug.
struct Mount {
    let host: URL
    let guest: String
    let readOnly: Bool

    /// Mounted at the identical host path by default. That is load-bearing rather than
    /// tidy: a worktree's `.git` is a file holding an absolute pointer into
    /// `<repo>/.git/worktrees/<name>`, so the repository has to appear at the same path
    /// inside the sandbox or every git command fails.
    init(_ host: URL, at guest: String? = nil, readOnly: Bool = false) {
        self.host = host
        self.guest = guest ?? host.path
        self.readOnly = readOnly
    }

    var specification: String {
        "\(host.path):\(guest)" + (readOnly ? ":ro" : "")
    }
}

/// CPU, memory and `/dev/shm`, with defaults sized for a browser-driven end-to-end suite.
///
/// Apple container hands out 4 CPUs, 1 GB and a 64 MB `/dev/shm`. Chromium maps its
/// renderer shared memory into `/dev/shm` and dies with `Target closed` once that fills,
/// which reads as a flaky test rather than as an exhausted mount. See ADR-005.
struct Resources {
    var cpus: Int = 6
    var memory: String = "8g"
    var shmSize: String = "2g"

    var arguments: [String] {
        ["--cpus", String(cpus), "--memory", memory, "--shm-size", shmSize]
    }
}

/// Everything needed to launch one sandbox, assembled before anything is run.
///
/// Built as a value rather than accumulated into a command string, so the direct launch and
/// the Herdr launch are the same sandbox by construction.
struct SandboxSpec {
    let name: String
    let image: String
    let workdir: URL
    var resources: Resources
    var mounts: [Mount]
    var environment: [String: String]
    var command: String
}

extension String {
    /// A container id is a DNS label: 63 bytes, no slashes. Ticket-style branch names run
    /// past that, and Apple container rejects them with `is not a valid container ID`. The
    /// tail becomes a digest of the full name so a rerun still resolves to the same
    /// sandbox.
    func asContainerID() -> String {
        let flattened = replacingOccurrences(of: "/", with: "-")
        guard flattened.utf8.count > 63 else { return flattened }
        let digest = SHA256.hexDigest(of: flattened).prefix(8)
        let stem = String(flattened.prefix(54)).replacingOccurrences(
            of: "-+$", with: "", options: .regularExpression)
        return "\(stem)-\(digest)"
    }
}

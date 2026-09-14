# DD-001 — The arena CLI

**Status:** building
**Date:** 2026-09-14
**Decisions:** [ADR-001](../decisions/ADR-001-drive-the-container-cli.md),
[ADR-002](../decisions/ADR-002-one-runtime-drop-sbx.md),
[ADR-003](../decisions/ADR-003-write-arena-in-swift.md),
[ADR-004](../decisions/ADR-004-repositories-declare-their-own-image.md),
[ADR-005](../decisions/ADR-005-size-sandboxes-for-a-browser-suite.md),
[ADR-006](../decisions/ADR-006-project-services-run-inside-the-sandbox.md)
**Lands in:** the `arena` binary

## What this is

A single binary that cuts a git worktree and launches a coding agent inside an Apple container
sandbox against it. It replaces two fish functions that did the same job. Four subcommands: `new`, `ls`, `rm`, `build`.

## What this proves

Most load-bearing first:

- **A sandbox can be launched from a typed specification rather than an assembled string.**
  `SandboxSpec` is built as a value and turned into an argument vector once, so the direct
  launch and the Herdr launch are the same sandbox by construction. Checkable by the
  `Run arguments` test suite.
- **A repository can state its own toolchain.** `.arena/Dockerfile` in a repository produces a
  different image with no change to arena. Checkable by running `arena build` in a repository
  that has one, against one that does not.
- **The container id derivation survives real branch names.** Checkable by the
  `Container id derivation` suite, including the case two long names sharing a prefix.
- **Keychain access needs no subprocess.** `Credentials.keychainSecret` uses
  `SecItemCopyMatching`. Checkable by launching a sandbox and confirming the agent does not ask
  to log in.

## Why it needs a sandbox

The agent runs with `--dangerously-skip-permissions`, so the boundary is what makes that
acceptable. A container gives process isolation and a filesystem the agent cannot escape into
the rest of the machine.

What crosses the boundary, and why each one:

| Crosses | Direction | Why |
|---|---|---|
| The whole repository, at its host path | read-write | A worktree's `.git` is a pointer into `<repo>/.git/worktrees/<name>`. Mount the worktree alone and every git command fails. |
| `~/.arena/home` at `/home/agent` | read-write | Without it the agent re-onboards on every launch. |
| `~/.arena/state/<repo>` at `/var/lib/arena` | read-write | Service data that must outlive a `--rm` container. |
| `~/.claude/projects` | read-write | Transcripts land where `--resume` and `memex index` already look. |
| The dotfiles directories behind `~/.claude` symlinks | read-only | A host edit reaches a sandbox that has been running for days. |
| The agent OAuth token, from the Keychain | copied in | The guest cannot read the macOS Keychain. |
| A GitHub token, from `gh auth token` | copied in | `gh auth git-credential` does not exist in the guest. |
| Anything named by `--mount` | as asked | Opt-in per run, read-write unless suffixed `:ro`. |

The honest gap: the repository is mounted read-write and is the host's real checkout, not a
copy. An agent that runs `rm -rf` against it destroys the host's work. The worktree boundary is
about git correctness, not containment.

## Non-goals

- **Not a general container manager.** `arena ls` lists arena's own sandboxes and nothing else.
  Use `container` for anything beyond that.
- **Not a second runtime abstraction.** Apple container only ([ADR-002](../decisions/ADR-002-one-runtime-drop-sbx.md)).
- **Not a network policy.** sbx had an egress policy; Apple container has no equivalent and
  arena does not build one. A sandboxed agent reaches the whole internet.
- **Not a credential vault.** arena copies tokens the host already holds. It does not mint,
  scope or rotate them.
- **Not a build system.** `arena build` shells to `container build` and does nothing else.

## Data model

What lives where, and whether it is copied or mounted:

- **In the image**: the toolchain, the agent binary, and any service the project declared.
  Rebuilt when `.arena/Dockerfile` changes, which the digest tag detects.
- **On a host-backed mount**: the agent home, service state, and transcripts. Survives `--rm`.
- **Regenerated every run**: the agent's OAuth token, the GitHub token and `gh` hosts file, and
  the git identity. Rewritten each launch so a rotated host token propagates, and never mounted
  from the host copy, because a token the sandbox refreshed would invalidate the host's.

## Trade-offs

- **Digest tags against `latest`.** Digest tags mean an edited Dockerfile is a cache miss by
  construction. They also mean arena never cleans up old tags.
- **Resources on every run against system properties.** Explicit arguments keep the host's
  global defaults untouched, at the cost of arena's defaults being invisible until you read
  `--help`.
- **`lane` as a subprocess against reimplementing worktree layout.** Shelling to `lane` keeps
  one definition of where a worktree lives, shared with `herdr`. It costs a dependency on a
  tool that has to be installed.

## Measurements this must produce

Named in advance so a convenient subset cannot be reported later:

- **Launch latency**, from `arena new` to the agent's first prompt, on a warm image, median of
  10. Split into lane creation, image resolution and `container run`.
- **First-launch cost in a repository with a Dockerfile**, cold, once. This is a cliff rather
  than a slope: the parameter that triggers it is the absence of the digest-tagged image.
- **Peak sandbox memory during a full Playwright run**, to confirm or correct the 8 GB default
  in [ADR-005](../decisions/ADR-005-size-sandboxes-for-a-browser-suite.md). The current
  evidence only shows Chromium starting.

None of these have been taken.

## Staging

1. **Package skeleton, `Shell`, `ContainerRuntime`, `SandboxSpec`.** Checkable by `swift test`
   and by `arena ls` returning the live runtime's state. *Done.*
2. **`new`, `ls`, `rm`, `build` ported from `sandc`.** Checkable by launching a sandbox in a
   real repository. *Written, not yet exercised end to end.*
3. **Delete `sand` and `sandc` from the dotfiles repository.** Checkable by that repository no
   longer referencing sbx. *Not started.*
4. **Install path.** `swift build -c release` and a symlink, or a Homebrew formula. Undecided.
5. **The measurements above.** *Not started.*

## Where it stops

- **`arena new` has not been run end to end.** Every piece is written and the package builds,
  but no sandbox has been launched by this binary. `ls` is the only command exercised against
  the live runtime.
- **No `arena-init` failure handling.** If a project's database fails to start, the agent
  launches anyway and the failure presents as a confusing test error.
- **No cleanup command.** Old digest-tagged images and `~/.arena/state/<repo>` directories
  accumulate with nothing to prune them.
- **Herdr's pane command is still a shell string.** arena quotes every argument, which is
  better than concatenation, but the interface is still a string.

## Open risks

- **The JSON shapes are undocumented.** `container ls --format json` is decoded into narrow
  `Decodable` structs. An upstream rename breaks `arena ls` at runtime. Closing it means either
  a pinned `container` version or a smoke test that runs against the installed one.
- **The base image is assumed to exist.** arena falls back to `arena.baseImage` and never
  builds it. It now fails with an actionable message rather than a registry pull error, but a
  stranger still has to supply their own base. Closing it means arena shipping a base
  Dockerfile of its own.
- **Keychain access under a locked keychain is untested.** Closing it means testing a fresh
  login session.

# ADR-009 — Standing extra mounts live in git config, as `arena.mount`

**Status:** accepted
**Date:** 2026-09-25
**Deciders:** Conor Sinclair
**Relates to:** `Sources/arena/Commands/New.swift`, `Sources/arena/Host/Repository.swift`, `Sources/arena/Runtime/SandboxSpec.swift`, [ADR-004](ADR-004-repositories-declare-their-own-image.md), [ADR-008](ADR-008-arena-here-runs-without-git.md)

## The decision

A directory that should be in every sandbox is named by `arena.mount` in git config, which takes as many values as the user adds. `New` reads them with `git config --get-all` through `Repository.configAll`, parses each exactly as `--mount` does, and mounts each at its own host path. A configured directory that does not exist warns and is skipped; one named by `--mount` still fails the launch. Set it globally to cover every repository:

```
git config --global --add arena.mount ~/Screenshots:ro
```

## Context

The agent in a sandbox cannot read a file path pasted from the host. Inside the sandbox `/Users/conor` contains only `Repos`, the repository mount, so `/Users/conor/Library/CloudStorage/Dropbox/Screenshots/CleanShot 2026-09-25 at 12.54.10.png` resolves to nothing and the agent reports the file missing. Handing the agent a screenshot is a thing this user does many times a day, which makes a per-launch flag the wrong shape: the cost is paid on every `arena .`, `arena @` and `arena new`, forever.

`--mount` already existed and already mounts at the identical host path, which is the property that makes a pasted path work without rewriting. What was missing was a way to say it once.

## Options considered

### Option A — type `--mount` on every launch

Works today, no code. `arena . -M "$HOME/Library/CloudStorage/Dropbox/Screenshots:ro"`. It costs the typing on every launch of every lane, and the failure when it is forgotten is the agent saying a file does not exist, which reads as a broken path rather than a missing mount. Rejected as the standing answer; it remains the right tool for a one-off directory.

### Option B — `arena.mount` in git config, multi-valued

One `git config --global --add`, and every sandbox thereafter has the directory. It reuses the configuration channel `arena.baseImage` and `arena.dockerfile` already use ([ADR-004](ADR-004-repositories-declare-their-own-image.md)), so there is no second place to look, and git's own scoping gives a per-repository override for free. It costs a `configAll` reader, because `config(_:)` returns only the last value and would hide every global value behind one repository-local one. Taken.

### Option C — an `ARENA_MOUNTS` environment variable

No new reader, and it composes with a shell function. It costs a separator convention inside a value that is already a path with an optional `:ro` suffix, on paths that contain spaces. It also lives in the shell profile rather than with the other arena settings, and it cannot be scoped per repository. Rejected.

### Option D — mount a screenshots directory by default

Nothing to configure, which is the whole appeal. It costs a hard-coded path that is right for one person: CleanShot's output directory is a setting, `~/Library/CloudStorage/Dropbox` is one cloud provider's, and a default that silently mounts a Dropbox folder into every sandbox is a surprise rather than a convenience. Rejected.

### Option E — a dedicated `~/.arena/inbox`, mounted always

A fixed directory the user copies or symlinks images into. It avoids configuration and avoids mounting anything the user did not put there. It costs the copy step on every image, which is the cost the whole change exists to remove, and a symlink into Dropbox reintroduces the mount with an extra indirection. Rejected.

## Decision and why

Option B, because the setting is the same kind of thing as `arena.baseImage` and belongs in the same place. A reader who knows where a repository's image is configured now also knows where its mounts are, and `git config --get arena.mount` answers the question "why is this directory in my sandbox" without reading any Swift.

Two behaviours were decided alongside it, both on judgement rather than evidence:

A configured mount that has gone missing warns and is skipped, rather than failing the launch. A cloud-backed directory is not always mounted on the host, and a sandbox that refuses to start because Dropbox is not running is worse than one that starts without a screenshots folder. A `--mount` path is still fatal, because it was asked for by this launch.

A guest path named twice is mounted once, on the reading that `container run` rejects a launch whose volumes collide. That reading is not verified here. `New.deduplicated` keeps the sandbox's own mounts — the repository, the home, the tool cache, the transcripts — and among the rest keeps the last, so `--mount` overrides an `arena.mount` value for the same path. An extra that collides with the repository mount is dropped rather than reported, which is safe only because the directory is then already present inside the sandbox at that path.

## Consequences

- **What it rules out.** Mounting a directory at a guest path different from its host path. Every extra mount is at its own path, which is what makes a pasted path work, and there is no syntax for `host:guest`.
- **What it makes worse.** A global `arena.mount` is a standing hole in sandbox isolation that is opted into once and then invisible: every sandbox for every repository gets the directory, including one running code the user has not read. `:ro` limits it to reading, and nothing enforces `:ro`. Nothing prints the extra mounts at launch, so the only way to see the standing set is `git config --get-all arena.mount`.
- **What stays open.** Whether `arena list` or the launch banner should name the non-default mounts. Whether `:ro` should be the default for a configured mount and `:rw` the opt-in, which would be the safer default and a break from how `--mount` reads today.
- **What now depends on it.** `Repository.configAll`, `New.mountKey`, `New.deduplicated`, and the `--mount` help text, which documents the config key.

## Evidence

- `Tests/arenaTests/MountTests.swift`, suite `Extra mounts and the sandbox's own`: `added`, `collidesWithBase`, `repeated`, `lastWins`, `baseOrder`.
- `Tests/arenaTests/RepositoryTests.swift`, suite `Multi-valued config`: `allValues`, `unset`. Both suites passed on 2026-09-25, swift-testing 1501 on arm64e-apple-macos14.0. That run asserted on `arena.testMount`; the key was changed to `arena.mount` when `GitIsolation` landed, and that version has not been re-run.
- `configAll` reading the user's global config is not hypothetical. On that run `Dockerfile resolution/configuredBaseImage` failed, `elixir-agent:latest` against an expected `agent-base:latest`, because the author's global `arena.baseImage` reached a throwaway repository that set none. `Tests/arenaTests/GitIsolation.swift` now points `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` at `/dev/null` for the whole test process, which is what lets `Multi-valued config` assert on the real `arena.mount` key.
- The problem, observed from inside a running sandbox on 2026-09-25: `ls /Users/conor` prints `Repos` and nothing else, and `ls /Users/conor/Library` fails with `No such file or directory`.
- **Not verified:** whether Apple container will bind-mount `~/Library/CloudStorage/Dropbox`, which is a File Provider path rather than a plain directory, and whether a dataless file materializes when the guest reads it. If it does not, the workaround is to point the screenshot tool at a plain directory such as `~/Screenshots` and configure that. No sandbox has been launched with `arena.mount` set, so nothing here is checked past the unit tests.

## Notes

`container run` rejecting duplicate volumes is the reason `deduplicated` exists, and that claim is from the runtime's behaviour as understood when this was written, not from a run that reproduced it here. If it turns out that `container` tolerates duplicates, `deduplicated` is still worth keeping for the `:ro` override it gives `--mount`.

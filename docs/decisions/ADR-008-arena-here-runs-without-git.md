# ADR-008 — `arena .` runs without git, and no other command does

**Status:** accepted
**Date:** 2026-09-25
**Deciders:** Conor Sinclair
**Relates to:** `Sources/arena/Host/Repository.swift`, `Sources/arena/Commands/Here.swift`, [ADR-004](ADR-004-repositories-declare-their-own-image.md), [DD-001](../designs/DD-001-the-arena-cli.md)

## The decision

`Repository.discover` no longer throws when git does not track the directory. It returns a `Repository` whose `root` is the directory itself and whose `isGitRepository` is false. `arena .` runs against such a directory, and `arena build` builds its `.arena/Dockerfile`. Every other command calls `Repository.requireGit()` first and fails with a message naming the directory and pointing at `arena .`.

## Context

arena is meant to replace running the agent on the host outright, which means it has to cover the directories a person opens the agent in that are not repositories: a notes folder, a scratch directory, a downloaded tarball. Before this change every command began with `Repository.discover()`, which ran `git rev-parse --path-format=absolute --git-common-dir` and threw on failure. In a directory outside git that reached the user as `CommandFailure` carrying git's own text:

```
fatal: not a git repository (or any of the parent directories): .git
```

That names neither arena nor the thing to do instead. `lane` was already not the obstacle: `arena .` (Here.swift) and `arena @` (Current.swift) both exist because some repositories are never laned, and `Repository.lanes()` already swallows a failed `lane` invocation and returns `[]`. Git was the obstacle, in three places: `discover`, `toplevel`, and the `repository.root` mount that `New.mounts` builds the workspace from.

## Options considered

### Option A — make every command work without git

`New`, `Enter`, `Remove` and `@` all name a lane, and a lane is a git worktree that `lane` cuts. Making them work without git means inventing a second notion of workspace that is not a worktree, with its own naming, its own listing and its own teardown. It buys nothing: there is no useful thing `arena new feature` could do in a directory with no branches. Rejected.

### Option B — a flag, `arena . --no-git`

Explicit, and it makes the non-git case something the user opts into rather than something they fall into. It costs a flag that exists only to describe a fact arena can already observe, and it fails in the direction that wastes time: the user who does not know the flag exists gets git's error and no hint. Rejected.

### Option C — `arena .` detects it, every other command refuses it

`Here` is already the command that does not ask `lane` anything, and its container id is already the worktree's directory name rather than a lane name. The only change it needs is a worktree that falls back to the invocation directory. The refusal for the rest is one call, `requireGit()`, and one error case. Taken.

### Option D — treat a non-git directory as a repository silently, everywhere

Drop the throw from `discover` and leave every command to fail later, wherever it happened to need git. `arena new foo` would then call `lane` and surface lane's error, and `arena build --lane foo` would find no lane, fall back to the repository root and build the wrong Dockerfile without saying so. That silent fallback is the failure [ADR-004](ADR-004-repositories-declare-their-own-image.md) records, in a different costume. Rejected, and it is why `Build` calls `requireGit()` when `--lane` is given even though the build itself needs no git.

## Decision and why

The argument is about error messages, not capability. Option C and Option D reach the same set of working commands; they differ only in what the user is told when they run one of the others. `requireGit()` throws `ArenaError.notARepository(path)`, which names the directory, states that a lane is a git worktree, and names `arena .`. A reader who has never read this ADR can act on it.

`arena build` is the one non-lane exception. It resolves `.arena/Dockerfile` and runs `container build`, and neither needs a commit, so refusing it in a non-git directory would block the one thing a scratch directory most plausibly wants: an image of its own.

This is a judgement about which commands are meaningful, not a measurement. Nothing here was decided on a number.

## Consequences

- **What it rules out.** There is no arena workspace that is not either a lane or the directory you are standing in. A second workspace notion for non-git directories is off the table, and `arena list` still only knows about sandboxes named for a lane, for `arena .`'s directory, or running an `arena-` image.
- **What it makes worse.** `discover` no longer fails fast, so a bug that loses git detection now presents as a sandbox mounting the wrong root rather than as an error. `requireGit()` in each command is the thing standing between that and a silent wrong mount, and it is a call that a new command can forget to make.
- **What stays open.** `New.gitOverrides` still sets `commit.gpgsign`, `gpg.format` and the signing key for a sandbox whose workspace has no git repository in it. They are inert there, and they are left in place rather than made conditional, because the overrides are per-sandbox and the directory may gain a repository while the sandbox runs. Also open: `arena enter <name>` in a non-git directory still enters a running sandbox of that name with no working directory, since `lanePath` returns nil.
- **What now depends on it.** `Repository.isGitRepository` and `Repository.hereWorktree`. Every command's first two lines. `SandboxHome`'s state directory, which is `state/<root.lastPathComponent>` and is now sometimes a plain directory's name rather than a repository's.

## Evidence

- `Tests/arenaTests/RepositoryTests.swift`, suite `Discovery outside git`: `rootIsTheDirectory`, `hereWorktreeOutsideGit`, `noLanes`, `requireGitThrows`, `requireGitPasses`.
- The pre-change failure, run in an empty directory under `/tmp` with git 2.55.0: `git rev-parse --path-format=absolute --git-common-dir` exits 128 with `fatal: not a git repository (or any of the parent directories): .git`.
- `Repository.config` deliberately keeps working outside a repository: `git -C <dir> config --get` answers from the user's global file, which is what gives a non-git directory a global `arena.baseImage`.
- **Not verified:** no sandbox has been launched from a non-git directory. The Swift toolchain was not available where this change was written, so `swift build` and `swift test` have not been run against it either. `arena new` has still never been run end to end.

## Notes

The container id for `arena .` is `Here.sandboxID`, the directory's basename truncated by `asContainerID()`. Two non-git directories with the same basename in different parents collide on that id, exactly as two repositories with the same name already do. A revisit that cares about collisions should look at hashing the path into the id, for lanes and for `arena .` together.

# arena

[![CI](https://github.com/C-Sinclair/arena/actions/workflows/ci.yml/badge.svg)](https://github.com/C-Sinclair/arena/actions/workflows/ci.yml)

**arena runs a coding agent in a disposable sandbox, one per git worktree.** It cuts a branch
and a worktree, builds the image that repository asked for, starts an Apple container microVM
with the repository mounted, and hands the terminal to the agent inside it.

macOS 15 or later on Apple silicon. Built for letting an agent run with permissions skipped
without letting it near the rest of the machine.

## Install

Build it. There are no releases and no Homebrew tap: it is one Swift package with a single
dependency, and the toolchain is already on any Mac with Xcode.

```sh
git clone https://github.com/C-Sinclair/arena && cd arena
swift build -c release
ln -s "$PWD/.build/release/arena" /usr/local/bin/arena
```

Needs `container`, `git`, `gh`, [`lane`](https://github.com/C-Sinclair/lane) and, for the
`--herdr` flag, [`herdr`](https://herdr.dev) on the PATH.

## Use

```sh
arena new e2e                      # branch, worktree, image, sandbox, agent
arena new e2e --herdr              # the same, in a new Herdr workspace
arena new hotfix --base v1.2.0     # branch from a rev other than the default
arena new spike --dirty            # carry uncommitted work into the lane
arena @                            # launch or join the lane the shell is in
arena .                            # launch against this worktree, no lane cut
arena enter .                      # a shell in the sandbox `arena .` started
arena ls                           # what is running
arena build                        # rebuild this repository's image
arena rm e2e --force               # stop it, delete the worktree and the branch
arena rm e2e --keep-branch         # stop it, keep the branch
```

`--base` and `--dirty` are [`lane`](https://github.com/C-Sinclair/lane)'s own flags, passed
through. There is no separate branch flag because lane has none: the lane name is the branch
name.

`arena .` is for repositories that are never laned, such as dotfiles, and for directories git does not track at all. The worktree is `git rev-parse --show-toplevel`, or the directory itself when that fails, and the container id is its directory name. It takes every `new` option except `--base` and `--dirty`. It has not been run end to end.

`arena .` and `arena build` are the only commands that run outside a git repository ([ADR-008](docs/decisions/ADR-008-arena-here-runs-without-git.md)). Every other command names a lane, a lane is a git worktree, and they refuse with a message pointing at `arena .`.

Extra host directories and environment variables go in per run, each mounted at the path it
already has so it is reachable inside the sandbox exactly where it lives outside:

```sh
arena new e2e --mount ~/Documents/notes --mount ~/fixtures:ro --env FOO=bar
```

A directory every sandbox should have goes in git config as `arena.mount`, which takes as many values as you add ([ADR-009](docs/decisions/ADR-009-standing-mounts-live-in-git-config.md)). Setting it globally is what makes a screenshot path pasted from the host readable by the agent, since the directory appears at its own path inside the sandbox:

```sh
git config --global --add arena.mount ~/Screenshots:ro
```

A configured directory that is missing at launch warns and is skipped; one named by `--mount` fails the launch. A global mount is a standing hole in the sandbox's isolation, so `:ro` is worth typing.

Resources default to 6 CPUs, 8 GB and a 2 GB `/dev/shm`, overridable per run with `--cpus`,
`--memory` and `--shm-size`. The defaults are deliberately past the runtime's, because a
browser test suite dies under 1 GB and a 64 MB `/dev/shm`
([ADR-005](docs/decisions/ADR-005-size-sandboxes-for-a-browser-suite.md)).

## Images

A repository declares its own toolchain by committing `.arena/Dockerfile`. arena builds it with
the repository root as context and tags it with a digest of the file, so editing the Dockerfile
is a cache miss by construction rather than a stale image you have to notice.

```dockerfile
FROM agent-base:latest
USER root
RUN apt-get update && apt-get install -y --no-install-recommends postgresql
COPY .arena/arena-init /usr/local/bin/arena-init
USER agent
```

If the image provides `/usr/local/bin/arena-init`, arena runs it before starting the agent.
That is where a project brings up a service its tests need. State that must outlive the
container goes in `/var/lib/arena`, which arena mounts from `~/.arena/state/<repo>`
([ADR-006](docs/decisions/ADR-006-project-services-run-inside-the-sandbox.md)).

If the image provides `claude-refresh`, arena runs it before `arena-init`. It reinstalls Claude Code into `~/.local/bin` on the persistent sandbox home when the last install is over 8h old, and arena puts `~/.local/bin` first on the agent's PATH so that install wins over the image's. `-U` / `--update-claude` sets `ARENA_CLAUDE_REFRESH=1` to force the reinstall on this launch. Neither has been run end to end.

The path is overridable three ways, most specific first:

```sh
arena new e2e --dockerfile ci/sandbox.Dockerfile   # this run only
git config arena.dockerfile ci/sandbox.Dockerfile  # this repository
```

A relative `--dockerfile` is looked for in the worktree before the repository root, like the
conventional path. Unlike it, a `--dockerfile` that does not exist is an error rather than a
quiet fallback to the base image.

**arena does not ship a base image.** A repository with no Dockerfile falls back to whatever
`arena.baseImage` names, and arena will not build it for you:

```sh
git config arena.baseImage my-agent-base:latest
```

## What this does not do

- **It is not a containment boundary against the agent.** The repository is mounted read-write
  at its real host path, because a worktree's `.git` is a pointer into the parent repository
  and git breaks without it. An agent that runs `rm -rf` there destroys your work. The sandbox
  protects the rest of the machine, not the repository.
- **It does not restrict the network.** A sandboxed agent reaches the whole internet.
- **It does not manage containers in general.** `arena ls` shows arena's sandboxes. Use
  `container` for anything else.
- **It does not mint or scope credentials.** It copies tokens the host already holds.

## Why wrap `container`

Apple container is a good runtime and a poor fit for what an agent needs, which is not a
container but a place to work. arena is everything between `container run` and an agent that
can do something useful:

- **A worktree, not a copy.** A worktree's `.git` holds an absolute path into
  `<repo>/.git/worktrees/<name>`, so mounting the worktree alone gives you a directory where
  every git command fails. arena mounts the whole repository at its identical host path and
  sets the working directory to the worktree.
- **Credentials the guest cannot fetch.** The agent's OAuth token is in the macOS Keychain,
  which Linux cannot read, and the copy on disk is stale. `gh auth git-credential` does not
  exist in the guest either. arena reads both on the host and writes current ones in on every
  launch.
- **A home that survives.** Without one the agent re-onboards every launch. Mounted naively it
  shadows what the image installed.
- **Transcripts where your tools look.** Every path in the sandbox matches its host path, so
  the agent derives the same per-project directory it would on the host. `--resume` in the
  worktree finds the sandbox's session.
- **Sizes that let a real suite run.** See ADR-005.

## Where the reasoning lives

Three kinds of document under [`docs/`](docs/), each with an `INDEX.md`
([ADR-007](docs/decisions/ADR-007-docs-are-four-kinds.md)):
[decisions](docs/decisions/INDEX.md) for why it is this way and what lost,
[designs](docs/designs/INDEX.md) for what is being built and where it stops, and
[friction](docs/friction/INDEX.md) for obstacles whose fix lives in someone else's repository.

[DD-001](docs/designs/DD-001-the-arena-cli.md) is the design doc for the tool itself.

## History

It began as two fish functions. `sand` drove sbx on Docker Desktop and built the Elixir
toolchain from source inside a live sandbox, which took about fifteen minutes and needed egress
holes punched for it. `sandc` drove Apple container instead, kept alongside so the two could be
compared: one microVM per sandbox costing about 1 GB while running and nothing when stopped,
against Docker Desktop's always-on VM, and a prebuilt toolchain image instead of a build.

Apple container won, so the second runtime went
([ADR-002](docs/decisions/ADR-002-one-runtime-drop-sbx.md)). What forced the rewrite was a
Playwright suite: it needed node, Chromium and a Postgres on `localhost`, none of which belong
in a base image every sandbox shares. Letting the repository declare its own image worked, then
failed twice in ways a shell function could not have caught. A Dockerfile written into a
worktree was never found, because the resolver only looked at the repository root. And a
`latest` tag meant an edited Dockerfile silently kept running the old image.

Both are now tested. The name is Spanish for sand, which is where it came from, and an arena is
where the agents work.

## Develop

```sh
swift test                                          # 41 tests
swift format lint --recursive --strict Sources Tests
./scripts/check-links.sh                            # every relative markdown link resolves
```

CI runs all three on every push and pull request.

The tests cover the pure logic: container id derivation, mount specifications, image reference
splitting, the argument vector, the subprocess layer, and the two Dockerfile resolution rules
that have each failed once in production. They do **not** cover anything needing a live
runtime, a Keychain or a Herdr server, so a green CI run means the logic holds, not that a
sandbox launches.

## Status

Pre-release. `arena new` has not been run end to end, and `ls` is the only command exercised
against a live runtime. [DD-001](docs/designs/DD-001-the-arena-cli.md) says exactly where it
stops.

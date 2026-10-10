# ADR-010 — A sandboxed agent asks the host for a split, a report or a hop by writing request files, and can do nothing else to Herdr

**Status:** proposed
**Last changed:** 2026-10-08 — the request kinds are now `split`, `report` and `hop`, read by `arena broker` from `/var/lib/arena/spawn`; the earlier `shared`, `lane` and `prompt` kinds were not built
**Date:** 2026-10-07
**Deciders:** Conor Sinclair
**Relates to:** `Sources/arena/Broker/BrokerRequest.swift`, `Sources/arena/Broker/Broker.swift`, `Sources/arena/Commands/New.swift`, `Sources/arena/Host/Herdr.swift`, the `arena-spawn` script in the dotfiles repository's `containers/elixir-agent/`, [ADR-006](ADR-006-project-services-run-inside-the-sandbox.md), [DD-001](../designs/DD-001-the-arena-cli.md)

## The decision

The guest gets no `herdr`. It writes one JSON object per file into `/var/lib/arena/spawn/`, which is `~/.arena/state/<repo>/spawn` on the host. `arena broker`, which `arena new --herdr` starts detached for each sandbox it launches, polls that directory once a second and handles exactly three request kinds:

| `kind` | Fields | What the host does |
|---|---|---|
| `split` | `name`, `brief`, optional `model`, `effort` | Writes the brief to `<state>/briefs/<name>.md`, runs `herdr pane split <leader pane> --direction right --no-focus`, then `herdr pane run` of `container exec -it <sandbox> bash -lc 'claude --model M --effort E "$(cat /var/lib/arena/briefs/<name>.md)"'`. Same container, same filesystem. Defaults `opus` and `xhigh`. |
| `report` | `name` | Checks `<state>/findings/<name>.md` exists, then `herdr agent prompt <leader pane> "findings ready at /var/lib/arena/findings/<name>.md"`. |
| `hop` | `path` | Asks the user in a macOS dialog. Only on "Open" does it run `herdr tab create` in the leader's workspace and `arena . --herdr-pane <new pane>` in `~/Repos/ORG/REPO`, which is a separate sandbox with its own container and its own broker. |

Every field is validated before any subprocess runs, by `BrokerProtocol.validate`:

- `name` matches `^[a-z0-9][a-z0-9._/-]{0,62}$`, the pattern `arena-spawn` already enforces. `/` is replaced with `-` before a name becomes a file name, so `a/../../x` cannot leave the directory.
- `model` is one of `opus`, `sonnet`, `haiku`, `fable`. `effort` is one of `low`, `medium`, `high`, `xhigh`, `max`.
- `brief` is non-empty and at most 64 KiB. It never appears on a command line: the split's command reads it from the file.
- `path` is `~/Repos/ORG/REPO` or the same absolute host path, exactly two levels under `~/Repos`, each segment `[A-Za-z0-9_][A-Za-z0-9._-]*`, and an existing directory.

A request that fails validation, has no `kind`, or names any other kind, is moved to `spawn/rejected/` and logged to `<state>/broker.log`. Requests `arena-spawn` writes today have no `kind`, so they land there. The broker exits when the sandbox it was started for stops running, and a second broker for the same state directory exits at once while the first one's pid is alive.

## Context

The workflow this serves: a leader agent, Sonnet at low effort, runs in one sandbox per repository. When work is hard it hands a brief to an Opus agent at xhigh effort in a split beside it, which works in the same container and writes its findings to a file the leader reads. The leader sometimes needs another repository, which is a different sandbox.

None of the host tools reach the guest:

- `/opt/homebrew/bin/herdr` is a Mach-O binary and the image ships no Linux build.
- `herdr` talks to `~/.config/herdr/herdr.sock`. A Unix socket cannot be mounted into an Apple container, which is the same limit that rules out the 1Password signer (see `New.gitOverrides`).
- Opening another repository needs a new `container run` with new mounts, and only the host can do that.

The owner wants the guest able to ask for these three things and nothing more: no reading other panes, no prompting arbitrary agents, no closing workspaces, and no opening a repository without a person saying yes.

## Options considered

### Option A — mount Herdr's socket and ship a Linux `herdr`

The `spin-off-agent` skill would work unchanged. It cannot be built: the socket does not cross the VM boundary. Even if it did, it would hand the guest every `herdr` subcommand, including `pane run` in any pane on the host, which is host code execution. Rejected.

### Option B — a TCP listener on the host, reached from the guest by the gateway address

Works across the VM boundary. It costs a port, a bearer token so other processes on the host network cannot open tabs, and a decision about which interface to bind. Rejected for Option C, which needs none of that.

### Option C — a request directory on the existing state mount

`/var/lib/arena` is already mounted read-write for [ADR-006](ADR-006-project-services-run-inside-the-sandbox.md). A file written there is visible to the host with no new mount, no port and no credential. The broker decides what a request may do, so the guest's power is the broker's allow-list and nothing else. It costs a host process per sandbox whose lifetime has to track the container's, and a second of polling latency. Taken.

### Option D — the earlier draft of this ADR: `shared`, `lane` and `prompt` kinds

A `shared` child opened in a new tab rather than a split, a `lane` child cut a new worktree into a new container, and `prompt` let the guest type into any child it had started. Not built. A split keeps the leader and the expert visible side by side, which is the point of the workflow. `prompt` with free text is a wider grant than `report`, which sends one fixed sentence naming one file. `lane` is still wanted for work that collides with the leader's edits, and is not decided here.

## Decision and why

Option C, on judgement rather than measurement. It is the only option that keeps the guest's reach down to an allow-list without adding a credential. `report` is the only kind that types into a pane, and the text it types is fixed by the host. `hop` is the only kind that launches a new container, and it needs a person to click "Open".

Polling at one second rather than FSEvents: nothing measured says FSEvents is needed, and a poll is one `contentsOfDirectory` call. The liveness check runs `container list` every ten polls.

## Consequences

- **What it makes worse.** A split agent and the leader write to one worktree and one git index. Two agents committing at once can interleave. The brief tells the split agent to write findings, not to commit.
- **What it makes worse.** The state directory is per repository, not per sandbox, so two lanes of one repository share one spool. The first broker started answers both, and splits open beside its leader. One sandbox per repository is the intended use.
- **What it makes worse.** `arena new` without `--herdr` starts no broker, so `arena-split` there writes a request nobody handles. `arena new --herdr` sets `ARENA_BROKER=1` in the sandbox, and the sandbox-side scripts refuse to write a request without it.
- **What it makes worse.** `report` types into the leader's pane. If the leader is mid-turn, the sentence queues as the next prompt.
- **What it rules out.** The leader cannot read the split's screen or close it. It sees what the split wrote to `/var/lib/arena/findings`.
- **What stays open.** Whether a split pane is closed when its agent exits. `container exec` processes die with the container. The pane itself is left for the user.
- **What now depends on it.** The request JSON shape, and the sandbox-side `arena-split`, `arena-report` and `arena-tab` scripts described in [DD-001](../designs/DD-001-the-arena-cli.md).

## Evidence

- `herdr pane split --help` on this machine (2026-10-08) lists `[PANE_ID]`, `--direction right|down`, `--cwd`, `--env`, `--focus` and `--no-focus`. `herdr agent prompt --help` takes `<TARGET> <TEXT>`.
- `container exec --help` (2026-10-07) lists `-i`, `-t`, `-w` and `--env`.
- `BrokerProtocolTests` covers the allow-lists, the name pattern, the traversal case and the `hop` path rules.
- Not verified: the JSON `herdr pane split` and `herdr tab create` print. `Herdr.paneID(in:)` looks for the first `pane_id` key anywhere in the result, which works for `workspace create` and is a guess for the other two. That `herdr agent prompt` accepts a pane id as its target. That `claude` accepts `--effort` on the command line. That `container exec -it` inside a Herdr pane gives the agent a working pty. That a detached `arena broker` survives the terminal that ran `arena new --herdr` closing. Nothing in this ADR has been run against a live container or a live Herdr session.

## Notes

The `includeCoAuthoredBy` and `attribution` settings seeded by `SandboxHome.seedPermissionMode` apply to split agents too, since they share the sandbox home.

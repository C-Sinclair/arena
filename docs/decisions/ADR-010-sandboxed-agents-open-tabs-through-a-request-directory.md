# ADR-010 — A sandboxed agent opens Herdr tabs and prompts its own children by writing request files, and can do nothing else to Herdr

**Status:** proposed
**Date:** 2026-10-07
**Deciders:** Conor Sinclair
**Relates to:** `Sources/arena/Commands/New.swift`, `Sources/arena/Commands/TabReader.swift`, `Sources/arena/Host/TabRequests.swift`, `Sources/arena/Guest/ArenaTab.swift`, `Sources/arena/Host/Herdr.swift`, `Sources/arena/Host/SandboxHome.swift`, `Sources/arena/Host/ToolCache.swift`, the `spin-off-agent` skill in the dotfiles repository, [ADR-006](ADR-006-project-services-run-inside-the-sandbox.md)

## The decision

The guest gets one command, `arena-tab`, and no `herdr`. `arena-tab` writes a JSON request into `/var/lib/arena/requests/<sandbox>/`, which is under `SandboxHome.state` on the host. A host-side reader, `arena tab-reader`, started by `arena new --herdr` handles exactly three request kinds, and deletes anything else unread:

- **`shared`**, the default: `herdr tab create --workspace <this sandbox's workspace> --no-focus`, then `herdr pane run` of `container exec -it <sandbox> bash -lc <New.command(agent:) with --model, --effort and the brief>`. The child is a second agent process in the same container and the same worktree.
- **`lane`**, chosen with `arena-tab --lane <branch>`: the host runs `lane <branch>` in the repository root and launches a new sandbox for that worktree into a tab of the same workspace. The child is a separate container with its own worktree.
- **`prompt`**, sent with `arena-tab prompt <name> '<text>'`: the host runs `herdr agent prompt <pane> <text>`, only if `<name>` is a child this reader started. The reader keeps a name-to-pane map in memory, so a name from another sandbox, or a child of a reader that has since exited, is refused. The pane id is the target because a child is never registered with `herdr agent start` and has no name in Herdr.

How a request travels:

- `arena-tab` writes `.<id>.tmp` and renames it to `<id>.json`. It fails at once when `ARENA_HERDR_WORKSPACE` is unset or the inbox directory does not exist.
- The reader deletes `<id>.json` before acting on it. `arena-tab` takes the deletion as proof a reader is alive, and gives up after 15 seconds without one.
- The reader writes `<id>.result`, beginning `ok` or `refused`, once the action has finished. `arena-tab` prints it and exits non-zero on `refused`.
- Each sandbox has its own inbox, `requests/<sandbox>`, because `SandboxHome.state` is per repository and every sandbox of that repository shares it. The subdirectory routes requests. It is not a security boundary: a guest can write to any inbox. What holds is that a reader opens tabs only in its own workspace and prompts only its own children.
- Every field is checked against a pattern in `TabRequest.parse` before it reaches a host command. A name is a path component, a branch may not start with `-`, and model and effort are restricted to `[A-Za-z0-9._[]-]`.
- The reader writes the brief to `agents/<name>/brief.md`, and the child's command reads it with `"$(cat …)"` inside the container. Text the guest wrote is never typed into the host pane's shell.

The reader polls the inbox every half second and checks `container ls` every tenth poll. It waits up to 120 seconds for the sandbox to start, and exits when the sandbox is no longer running. A sandbox relaunched under the same name starts a new reader, and a token in `~/.arena/readers/<sandbox>.token` makes the old one exit. The reader logs to `~/.arena/readers/<sandbox>.log`.

`arena new` sets `ARENA_SANDBOX` on every sandbox and `ARENA_HERDR_WORKSPACE` only on the Herdr path. A `shared` child inherits both, so it can open tabs through its parent's reader. A `lane` child gets no workspace variable and so no reader: `arena-tab` in it refuses. Children are one level deep in `lane` mode.

A child reports back through the same directory. `SandboxHome.seedPermissionMode` seeds `Stop`, `Notification` and `UserPromptSubmit` hooks that run `arena-tab hook <event>`, which writes `/var/lib/arena/agents/<name>/status` (`working`, `waiting`, `done`) and `/var/lib/arena/agents/<name>/last-message.md`. The name comes from `ARENA_AGENT_NAME`, which only a child has, so the hooks do nothing for the sandbox's own agent. The reader also writes `working` when it starts or prompts a child, and clears a former child's `status` and `last-message.md` first, so `wait` never reads a stale `done`. An `idle_prompt` notification does not turn `done` back into `waiting`. `SandboxHome.state` is keyed by repository, not by lane, so a `--lane` child in its own container writes to the same directory as its parent. The parent reads those files directly, or waits on them with `arena-tab wait <name>`. The `spin-off-agent` skill checks `ARENA_SANDBOX` and calls `arena-tab` instead of `lane` and `herdr` when it is set.

## Context

The `spin-off-agent` skill delegates work by running `lane`, `herdr tab create`, `herdr agent start` and `herdr agent prompt`. None of these work inside a sandbox:

- `/opt/homebrew/bin/herdr` is a Mach-O binary and the image ships no Linux build.
- `herdr` talks to `~/.config/herdr/herdr.sock`. A Unix socket cannot be mounted into an Apple container, which is the same limit that rules out the 1Password signer (see `New.gitOverrides`). `HERDR_WORKSPACE_ID` is not passed in either.
- `lane` creates a worktree outside `repository.root`, which the container never mounted, and mounts are fixed at `container run`.

The owner also wants the sandboxed agent able to open a tab and prompt the agents it started, and nothing more: no reading other panes, no prompting agents it did not start, no closing workspaces.

## Options considered

### Option A — mount Herdr's socket and ship a Linux `herdr`

The skill would work unchanged. It cannot be built: the socket does not cross the VM boundary. Even if it did, it would hand the guest every `herdr` subcommand, including `pane run` in any pane on the host, which is host code execution. Rejected.

### Option B — a TCP listener on the host, reached from the guest by the gateway address

Works across the VM boundary. It costs a port, a bearer token so other processes on the host network cannot open tabs, and a decision about which interface to bind. Rejected for Option C, which needs none of that.

### Option C — a request directory on the existing state mount

`/var/lib/arena` is already mounted read-write for [ADR-006](ADR-006-project-services-run-inside-the-sandbox.md). A file written there is visible to the host with no new mount, no port and no credential. The reader decides what a request may do, so the guest's power is the reader's whitelist and nothing else. It costs polling or an `FSEvents` watch on the host, and a reader process whose lifetime has to track the container's. Taken.

### Option D — a `herdr` shim in the guest that accepts only `tab create`

Keeps the skill's commands. It costs a fake binary that answers `herdr tab create` and fails `herdr agent start`, which is the next line of the skill, so the skill has to branch anyway. Rejected in favour of a command named for what it does.

## Decision and why

Option C, on judgement rather than measurement. It is the only option that keeps the guest's reach down to a whitelist of three actions without adding a credential. `shared` is the default because a child in the same container needs no new mount and starts without a second image check. `lane` exists for work that would collide with the parent's edits, and it has to be a new container because a running container cannot gain a mount.

## Consequences

- **What it rules out.** The parent cannot read a child's screen or focus its tab. It sees status and the last message through the hook files, and the full history through the transcript in `~/.claude/projects`.
- **What it makes worse.** In `shared` mode parent and child write to one worktree and one git index. Two agents committing at once can interleave. In `lane` mode the parent cannot see the child's files, because the child's worktree is not mounted in the parent's container.
- **What it makes worse.** `arena new` without `--herdr` starts no reader, so `arena-tab` there writes a request nobody handles. `arena-tab` should fail when `ARENA_HERDR_WORKSPACE` is unset rather than leave a file.
- **What stays open.** Whether `shared` children should be killed when the parent container is removed: `container exec` processes die with the container, which is probably right.
- **What it makes worse.** The reader handles one request at a time. A `lane` request that builds an image holds up every request behind it, and `arena-tab` waits up to 30 minutes for a `lane` answer.
- **What it makes worse.** `last-message.md` needs `jq` or `python3` in the image. The hook reads `last_assistant_message` from the `Stop` input and falls back to the transcript with `jq`. An image with neither gets `status` and no message.
- **What it makes worse.** `prompt` lets the guest type into a host Herdr pane. The pane runs a sandboxed agent, so the text reaches only the container, but the reader's check of the name against its own children is the only thing stopping it reaching any other pane.
- **What now depends on it.** The `spin-off-agent` skill's sandbox branch, and the request JSON shape.

## Evidence

- `container exec --help` (container CLI on this machine, 2026-10-07) lists `-i`, `-t`, `-w` and `--env`, which is what the `shared` launch needs.
- `herdr tab create --help` lists `--workspace`, `--cwd`, `--label`, `--env` and `--focus`.
- `herdr agent prompt --help` and `herdr agent get w3G:p2` (2026-10-07) show a pane id is accepted as the target.
- `herdr tab create` answers with `result.tab.tab_id` and `result.root_pane.pane_id`, the shape the `spin-off-agent` skill already reads.
- Polling rather than `FSEvents` was chosen on judgement. Whether a write from inside the VM raises an `FSEvents` notification on the host was not checked, and polling needs no answer.
- `swift test` covers `TabRequest.parse` on good and hostile input, the reader deleting unknown kinds and stray files, refusing `prompt` for a name it did not start, refusing a duplicate name, and resetting a former child's status. One test runs `arena-tab` under the host's `/bin/bash` 3.2 against a `TabReader` with a recording launcher, and checks a brief with quotes, backslashes, tabs and newlines arrives unchanged. That test found bash 3.2 word-splitting an unquoted `${words[*]}`.
- `arena-tab hook` was run by hand under bash 3.2 and 5.3 with sample hook inputs: `status` moved through `working`, `done` and `waiting`, an `idle_prompt` left `done` alone, and `last-message.md` came from `last_assistant_message`, from the transcript with `jq`, and from `python3` with `jq` off the PATH.
- Not verified: that Claude Code's `Stop` input carries `last_assistant_message`. The transcript fallback covers a version that does not, if the image has `jq`.
- Not verified: that the hooks fire for an agent started under `container exec`, that `container exec -it` inside a Herdr pane gives the agent a working pty, that a `container exec` process inherits the container's environment, and that Herdr's agent detection sees the `exec -a` name through `container exec` as it does through `container run`.
- Not verified: the reader against a real `herdr` and `container`. `arena new --herdr` has not been run with this change, so no tab has been opened, no child started, no `lane` request served and no prompt delivered. The reader outliving the terminal that started it, through `nohup`, is also unrun.

## Notes

The `includeCoAuthoredBy` and `attribution` settings seeded by `SandboxHome.seedPermissionMode` apply to child agents too, since they share the sandbox home.

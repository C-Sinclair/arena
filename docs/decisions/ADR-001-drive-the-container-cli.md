# ADR-001 — Drive the `container` CLI, and do not link `ContainerAPIClient`

**Status:** accepted
**Date:** 2026-09-14
**Deciders:** Conor Sinclair
**Relates to:** `Sources/arena/Runtime/Container.swift`, [ADR-003](ADR-003-write-arena-in-swift.md)

## The decision

arena talks to Apple container by running the `container` binary and decoding
`--format json`. It does not depend on the apple/container Swift package, and it does not
speak XPC to `container-apiserver` directly.

## Context

arena is written in Swift partly because the runtime it drives is Swift, which raises the
obvious question of whether to link the runtime's own client library and skip the subprocess.
The answer changes the dependency story completely, so it had to be settled before the first
commit.

Two facts decided it. Homebrew ships `container` as executables only, with no Swift module to
link against, so using the library means a source dependency on apple/container and building
it locally. And `ContainerAPIClient` does not implement the runtime; it speaks XPC to the
`container-apiserver` that Homebrew installed and launchd runs.

## Options considered

### Option A — depend on the apple/container Swift package

Buys typed calls, no subprocess cost, no output parsing. Costs a from-source build of a large
package, and it puts a second copy of the XPC protocol inside arena. `brew upgrade container`
moves the daemon's copy without moving arena's, and the two skew. That failure arrives at
runtime, on a machine where no arena code changed, which is the worst shape a dependency
failure can have. **Lost.**

### Option B — speak XPC to `container-apiserver` directly

Removes the package dependency and keeps the skew. Strictly worse than Option A, since it
reimplements a protocol with no stability guarantee and no compiler checking it. **Lost.**

### Option C — run the `container` binary and decode its JSON (taken)

Costs roughly 42 ms per call and a decode step. Buys a version-negotiated interface: the
binary and the daemon are installed together by Homebrew and are each other's problem, not
arena's.

## Decision and why

Option C, because the runtime cost is irrelevant at this call rate and the maintenance cost is
the only one that compounds.

`container ls`, `container image ls` and `container inspect` all emit JSON, so this is a
documented machine interface rather than table scraping:

```
container ls --format json          # values: json, table, yaml, toml
container image ls --format json
```

The performance argument does not survive contact with the numbers. A single
`container image ls` call takes 42.1 ms at p50. Nothing arena does in-process is within two
orders of magnitude of that, so moving the call in-process would save nothing a user could
perceive, while the skew risk would be permanent.

## Consequences

- **What it rules out.** Anything the CLI does not expose. If arena ever needs an event
  stream or a runtime hook with no command behind it, this decision is what gets revisited.
- **What it makes worse.** Every query pays process startup, and arena decodes JSON that a
  linked client would hand over as values. `arena ls` is 42 ms of runtime and about 2 ms of
  arena.
- **What stays open.** Whether the JSON shapes are stable across `container` minor releases.
  They are not documented as stable, and arena decodes only the fields it uses specifically to
  limit the blast radius of an upstream addition.
- **What now depends on it.** `ContainerRuntime` in `Sources/arena/Runtime/Container.swift`,
  and the narrow `Decodable` shapes in it.

## Evidence

Measured on this machine, 2026-09-14, container 1.3.1, macOS 25.6.0:

- `container image ls --format json`, 5 runs: min 40.0 ms, p50 42.1 ms.
- `/opt/homebrew/Cellar/container/1.3.1` contains `bin/` and `libexec/` only. A `find` for
  `*.swiftmodule`, `*.swiftinterface` and `*.dylib` returns nothing, so there is no installed
  library to link.
- apple/container `Package.swift` on `main` declares 26 library products. The client product
  is `ContainerAPIClient`; there is no `ContainerClient`.
- Release cadence from `gh api repos/apple/container/releases`: 23 releases between
  2025-06-09 and 2026-09-09, with 1.0.0 on 2026-06-09 and 1.4.1 on 2026-09-09. Roughly monthly
  since 1.0.

Not verified: that a library/daemon version skew actually breaks at runtime. The argument is
structural rather than reproduced, and it is labelled as such.

## Notes

If this is revisited, the thing to check first is whether apple/container has since documented
an API stability policy for its library products. None was found in `CONTRIBUTING.md` at the
time of writing.

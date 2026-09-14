# ADR-005 — Size sandboxes for a browser suite by default

**Status:** accepted
**Date:** 2026-09-14
**Deciders:** Conor Sinclair
**Relates to:** `Sources/arena/Runtime/SandboxSpec.swift`,
[FF-140926](../friction/FF-140926-container-defaults-strand-chromium.md)

## The decision

arena launches every sandbox with 6 CPUs, 8 GB of memory and a 2 GB `/dev/shm`, overridable
with `--cpus`, `--memory` and `--shm-size`. It does not use Apple container's defaults and does
not change them system-wide.

## Context

Apple container's defaults are 4 CPUs, 1 GB of memory and a 64 MB `/dev/shm`. A Playwright
suite could not run under them, and the way it failed is the reason this is an ADR rather than
a constant.

Memory is the visible half. Playwright's config sets `fullyParallel: true` with
`workers: undefined` outside CI, so it spawns one Chromium per core. Five Chromium processes,
the BEAM, esbuild and tailwind do not fit in 1 GB.

`/dev/shm` is the half that does not announce itself. Chromium maps renderer shared memory
into `/dev/shm`, and when 64 MB fills it dies with `Target closed`. That reads as a flaky test,
not as an exhausted mount, so it costs debugging time on every project that meets it.

## Options considered

### Option A — keep the runtime defaults, document the flags

Buys the smallest possible footprint per sandbox. Costs every project discovering
`Target closed` for itself, which is precisely the failure mode that is hardest to attribute.
**Lost.**

### Option B — raise the system-wide defaults

`container system property set container.memory 8gb` is one command and applies everywhere.
Costs correctness: it changes the defaults for every container on the machine, including ones
arena did not launch, and it is invisible host state that a fresh machine will not have.
**Lost.**

### Option C — arena passes explicit resources on every run (taken)

Costs sandboxes that are larger than many of them need, and a host that can run fewer of them
at once.

## Decision and why

Option C, because the defaults should make the expensive case work and the cheap case slightly
wasteful, rather than the other way round. A sandbox that is too large wastes memory the host
reclaims when it exits. A sandbox that is too small produces a test failure that looks like an
application bug.

`--shm-size 2g` is preferred over passing `--disable-dev-shm-usage` to Chromium because the
latter pushes shared memory onto disk and is slower, and because it would require every
project's Playwright config to know it is running in a sandbox.

The host has 24 GB and 10 cores, and Apple container's `[machine]` budget is already 12 GB, so
8 GB for one sandbox leaves room for the machine but not for many concurrent sandboxes. That
is the real cost and it is accepted knowingly.

## Consequences

- **What it rules out.** Running many sandboxes at once on this host. Three at the default
  size exceeds the machine budget.
- **What it makes worse.** A sandbox that only needs to run `mix format` still reserves
  8 GB. The flags exist for that case but nobody will remember to use them.
- **What stays open.** Whether the defaults should come from the repository's
  `.arena/Dockerfile` directory as well, so a project can state its own size rather than
  relying on arena's global choice. That is the obvious follow-up and is not built.
- **What now depends on it.** `Resources` in `SandboxSpec.swift`, and the test asserting the
  defaults are past the runtime's.

## Evidence

Measured inside a running sandbox on 2026-09-14, container 1.3.1.

Before, at the runtime defaults:

```
Mem:            1101 MB total, 737 available
tmpfs             64M  /dev/shm
```

After, at arena's defaults:

```
Mem:            8071 MB total
tmpfs            2.0G  /dev/shm
nproc              7
```

`container system property list` confirms the defaults being overridden are
`[container] cpus = 4, memory = "1gb"`, against `[machine] cpus = 5, memory = "12gb"`.

Chromium was verified to actually launch at the new size:
`chrome --headless --no-sandbox --dump-dom about:blank` returned
`<html><head></head><body></body></html>`.

Not verified: that 8 GB is enough for the full suite. Chromium starting and the suite
completing are different claims, and only the first was tested.

## Notes

`nproc` reports 7 in a sandbox configured for 6 CPUs. Not investigated.

# ADR-002 — Support one runtime, Apple container, and drop sbx

**Status:** accepted
**Date:** 2026-09-14
**Deciders:** Conor Sinclair
**Relates to:** [DD-001](../designs/DD-001-the-arena-cli.md), and the `sand` fish function in my
dotfiles repository, which is private

## The decision

arena targets Apple container only. The sbx and Docker Desktop path that `sand` carried is not
ported, and `sand` is deleted rather than kept alongside.

## Context

My dotfiles repository grew two near-identical fish functions. `sand` drives sbx on Docker
Desktop, `sandc` drives Apple container, and they were kept side by side deliberately so the
two runtimes could be compared under real load. That comparison has now happened, and Apple
container won on the two things that were being compared: one microVM per sandbox costing
about 1 GB while running and nothing when stopped, against Docker Desktop's always-on VM, and
a prebuilt hexpm toolchain image against fifteen minutes of building Erlang from source inside
a live sandbox.

Keeping both was also the main structural argument for leaving fish, because one tool with two
backends is a shape fish cannot express. Dropping sbx removes that argument, which is worth
stating plainly: this decision makes the rewrite less necessary, not more.

## Options considered

### Option A — port both, behind a runtime protocol

Buys the ability to fall back if Apple container regresses, and the abstraction is cheap to
write in Swift. Costs a second implementation of every command, and an abstraction shaped by
two members where the second is not wanted. It also keeps the sbx-specific concepts alive:
the egress policy, the secret store, `sbx skills import`, and mounts being fixed at sandbox
creation time so a rerun silently ignores new ones. **Lost.**

### Option B — port sbx only

Not seriously on the table. Listed because it is the status quo for `sand` and someone will
ask. Apple container is the runtime the per-project image work already targets. **Lost.**

### Option C — Apple container only (taken)

Costs the fallback. If Apple container breaks, the recovery is `git checkout` of the old fish
functions from the dotfiles history, not a flag.

## Decision and why

Option C, because more than half of `sand`'s complexity is sbx-specific plumbing with no
counterpart under Apple container, and an abstraction built to accommodate code that is being
deleted is an abstraction with one real implementation and a hypothetical one.

The concrete saving: `sand` is 218 lines of code to `sandc`'s 178, and the difference is
almost entirely the sbx secret store, `sbx skills import`, the template selection, and the
warning that mounts are fixed at creation time. None of those concepts exist here.

## Consequences

- **What it rules out.** Running arena on a machine without Apple container, which means macOS
  15 and later on Apple silicon. There is no Linux story and no Intel story.
- **What it makes worse.** There is no second runtime to cross-check against when a sandbox
  misbehaves. A bug in Apple container now presents as a bug in arena with nothing to compare
  it to.
- **What stays open.** Whether `SandboxSpec` should become a protocol later. It is a concrete
  struct today. The judgement is that adding the protocol when a second runtime actually
  arrives is cheaper than carrying it unused.
- **What now depends on it.** Every type in `Sources/arena/Runtime/` names `container`
  concepts directly, including the 63-byte container id limit and `--shm-size`.

## Evidence

Line counts on 2026-09-14, from the two fish functions being replaced:

```
sandc   178 lines of code, 94 of comment
sand    218 lines of code, 54 of comment
```

Not verified: the claim that Apple container's per-sandbox memory cost beats Docker Desktop's
always-on VM in practice. That was the premise for running the two side by side, and it is
recorded here as the reason the comparison was set up rather than as a measured result.

## Notes

The old functions remain in that repository's git history, which is where the sbx path is
recovered from if it is ever wanted.

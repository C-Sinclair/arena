# ADR-003 — Write arena in Swift

**Status:** accepted
**Date:** 2026-09-14
**Deciders:** Conor Sinclair
**Relates to:** [ADR-001](ADR-001-drive-the-container-cli.md),
`Sources/arena/Host/Credentials.swift`, `Package.swift`

## The decision

arena is a Swift package built with SwiftPM, using `swift-argument-parser` for the command
line and `swift-testing` for tests. Rust, OCaml and Zig were considered and lost.

## Context

The fish functions reached about 400 lines of code across `sand` and `sandc`, with no tests,
error handling by `or begin ... end` at each call, mounts as untyped strings, and command
lines assembled by concatenation before being handed to `herdr pane run` as a shell string.
That last one is a live bug class rather than a theoretical one: adding `arena-init` to the
launch command meant putting `&&` and `;` into a string that already interpolated paths.

## Options considered

### Option A — stay in fish

Buys zero migration. Costs everything above permanently, and in particular there is no way to
test a 400-line function. Also loses the ability to run the tool from anything other than an
interactive fish shell. **Lost.**

### Option B — Rust

Best-in-class ergonomics for exactly this shape: `clap`, `serde_json` to delete seven `jq`
calls, `anyhow` for the error paths. The only option that stays available if this ever needs
to run on a Linux Herdr host. Costs the Keychain integration, which becomes the
`security-framework` crate or a subprocess again, and there is no `rust_analyzer` configured
in `nvim/lsp/`. **Lost, narrowly.**

### Option C — OCaml

Good process and Unix libraries, and `ocamllsp` is already configured. Costs hand-written C
bindings for Keychain, and nothing in this tool plays to what OCaml is unusually good at.
**Lost.**

### Option D — Zig

`zls` is configured and `zig` is in `brew/packages.brew`, so this is the one with the
strongest preference behind it. Costs manual memory management for a program that is almost
entirely waiting on subprocesses, and a standard library that still moves between releases,
which would mean revisiting working code for no functional gain. **Lost.**

### Option E — Swift (taken)

Costs SwiftPM being slower than cargo at clean builds, and generic error messages that can be
rough. Buys native Keychain, a toolchain already installed, and the same language as the
runtime being driven.

## Decision and why

Option E, on one integration point and the absence of any counterweight.

Reading the agent's OAuth token is the single most fragile step in the launch path. In fish it
is `security find-generic-password -s "Claude Code-credentials" -w`, a subprocess whose failure
modes are a status code and an empty string. In Swift it is `SecItemCopyMatching` with a typed
`OSStatus` that `SecCopyErrorMessageString` turns into a message a user can act on. That is
the one place arena is genuinely better than a shell script rather than merely tidier.

Performance did not decide it, and the numbers are recorded so nobody re-derives them. Swift
starts 0.43 ms slower than Rust at p50, against a workload where one `container` call costs
42 ms and a `container build` costs tens of seconds. The language contributes nothing
measurable to this tool's runtime.

The `ContainerAPIClient` argument, which would have made Swift the only viable choice, does
not apply. [ADR-001](ADR-001-drive-the-container-cli.md) rejects linking it. Swift wins on
Keychain alone, which is a narrow win and is recorded as one.

## Consequences

- **What it rules out.** Running arena anywhere but macOS. Combined with
  [ADR-002](ADR-002-one-runtime-drop-sbx.md) this is now doubly true, so neither decision can
  be reversed alone to gain portability.
- **What it makes worse.** The editor story, until `nvim/lsp/sourcekit.lua` is written.
  `ocamllsp.lua` and `zls.lua` exist and the Swift equivalent does not, so the language with
  the best tooling story here currently has the worst editor story.
- **What stays open.** Whether `swift-argument-parser` is worth a dependency at this size. It
  is the only one, and dropping it would mean hand-rolling flag parsing for four subcommands.
- **What now depends on it.** `Package.swift`, and `Credentials.swift` which imports
  `Security` directly.

## Evidence

Measured on this machine, 2026-09-14, Swift 6.2.3 and rustc 1.93.0-nightly, release builds,
hello-world in each, 200 runs:

| | binary | startup min | p50 | p95 |
|---|---|---|---|---|
| Swift | 57 KB | 1.92 ms | 2.21 ms | 3.01 ms |
| Rust | 433 KB | 1.63 ms | 1.78 ms | 2.51 ms |

For scale, `container image ls --format json` is 42.1 ms at p50, which is about 20 times the
entire language gap. Swift's binary is smaller because it links the runtime from
`/usr/lib/swift` rather than bundling a standard library.

Toolchain availability checked the same day: `swift`, `cargo`, `ocaml` and `zig` are all
installed. `xcrun -f sourcekit-lsp` resolves inside `XcodeDefault.xctoolchain`, so the editor
gap is one configuration file rather than a missing binary.

Not verified: that `SecItemCopyMatching` reads the Claude Code item without a keychain prompt
in every configuration. It works unprompted in the current login session; a locked keychain or
a fresh login has not been tested.

## Notes

Xcode is not part of the workflow. `swift build`, `swift run` and `swift test` are the whole
loop, and the first clean build of this package took 14.51 s.

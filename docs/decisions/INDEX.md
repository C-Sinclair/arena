# Architecture decisions

One file per decision. **Read the relevant ones before changing the runtime interface, the
image resolution, or the sandbox defaults** — each records either a measurement that decided
something or a failure that had already happened once, and re-deriving those is expensive.

**Edit these in place.** An ADR should say what is true now, so a reader never has to work out
which of two files is current. Git is the history — `git log -p docs/decisions/ADR-001-*.md`
shows what a decision used to say. Corrections are the point, not an embarrassment.

Start from [`ADR-000-TEMPLATE.md`](ADR-000-TEMPLATE.md). Design docs for planned features live
in [`../designs/INDEX.md`](../designs/INDEX.md) and reference these.

## Runtime and language

| # | Decision | Status |
|---|---|---|
| [001](ADR-001-drive-the-container-cli.md) | Drive the `container` CLI, and do not link `ContainerAPIClient` | accepted |
| [002](ADR-002-one-runtime-drop-sbx.md) | Support one runtime, Apple container, and drop sbx | accepted |
| [003](ADR-003-write-arena-in-swift.md) | Write arena in Swift | accepted |

## Sandbox shape

| # | Decision | Status |
|---|---|---|
| [004](ADR-004-repositories-declare-their-own-image.md) | A repository declares its own image in `.arena/Dockerfile` | accepted |
| [005](ADR-005-size-sandboxes-for-a-browser-suite.md) | Size sandboxes for a browser suite by default | accepted |
| [006](ADR-006-project-services-run-inside-the-sandbox.md) | Project services run inside the sandbox, on a host-backed state mount | accepted |
| [008](ADR-008-arena-here-runs-without-git.md) | `arena .` runs without git, and no other command does | accepted |
| [009](ADR-009-standing-mounts-live-in-git-config.md) | Standing extra mounts live in git config, as `arena.mount` | accepted |

## Documentation

| # | Decision | Status |
|---|---|---|
| [007](ADR-007-docs-are-four-kinds.md) | Split project documentation into four kinds, and keep them separate | accepted |

## Not yet decided

Open questions, in the order they need answering. Each becomes an ADR when it is settled.

1. **Whether arena is ever distributed as a binary.** Today it is built from source and
   symlinked, which is enough for one Swift package with one dependency. GitHub Releases or a
   Homebrew tap become worth the signing and release plumbing only if someone other than the
   author is installing it.
2. **Who builds the base image.** arena names one through `arena.baseImage` and never builds
   it, so a repository with no `.arena/Dockerfile` needs a base someone else made.
3. **Whether a project can state its own sandbox size**, rather than inheriting arena's
   defaults from [ADR-005](ADR-005-size-sandboxes-for-a-browser-suite.md).
4. **What happens when `arena-init` fails.** Today the agent starts anyway.
5. **Whether old digest-tagged images are pruned**, and by what.

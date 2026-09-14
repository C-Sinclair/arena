# ADR-004 — A repository declares its own image in `.arena/Dockerfile`

**Status:** accepted
**Date:** 2026-09-14
**Deciders:** Conor Sinclair
**Relates to:** `Sources/arena/Runtime/ImageResolver.swift`,
[ADR-006](ADR-006-project-services-run-inside-the-sandbox.md)

## The decision

A repository states the toolchain its sandboxes need by committing `.arena/Dockerfile`, which
is a `FROM` on top of the shared base image. arena builds it with the repository root as the
build context and tags it `arena-<repo>:<digest of the Dockerfile>`. Repositories with no such
file get the base image. The path is overridable per repository with `git config arena.dockerfile`, and per run with
`--dockerfile`.

## Context

The shared base image carries a language toolchain, git and gh, which is what most sandboxes
need. Then one repository needed to run a Playwright suite, which meant node, Chromium and a
Postgres on localhost. Adding those to the base would make every sandbox carry a browser and a
database it will never start.

The forcing question was where that complexity lives. Putting it in the launcher means the
launcher grows a flag per project need. Putting it in the project means the launcher stays
fixed and the project describes itself.

## Options considered

### Option A — add it to the shared base image

Simplest to implement, and no per-repository mechanism to design. Costs image size and build
time for every repository, and it makes the base a union of every project's needs, which only
ever grows. **Lost.**

### Option B — flags on the launcher

`--with-node`, `--with-postgres` and so on, or a `setup` command in git config as `sand` had.
Buys no new files in the project. Costs a launcher that has to know the catalogue of things a
project might want, and a setup command re-runs on every launch rather than being cached in a
layer. **Lost.**

### Option C — a Dockerfile in the repository (taken)

Costs a build the first time, a committed file in every repository that needs one, and a
convention to remember.

## Decision and why

Option C, because it puts the toolchain description next to the code that needs it, and
because Docker layer caching already solves the "do not redo this" problem that a setup
command does not.

Three details are load-bearing, and two of them were learned the hard way.

The Dockerfile is looked up in the worktree first and the repository root second. A branch that
changes its own toolchain should be sandboxed with the image that branch describes, not the
default branch's. The first version looked only at the repository root, which meant a
Dockerfile written into a lane was never found and the sandbox silently ran the base image.

The tag carries a digest of the Dockerfile rather than `latest`. A per-repository `latest`
that already exists is indistinguishable from one built by the Dockerfile currently on disk, so
an edited Dockerfile silently keeps running the old image. Digesting the file makes a changed
Dockerfile a cache miss by construction.

The third is the asymmetry between the conventional path and an explicit `--dockerfile`. An
absent `.arena/Dockerfile` means "this repository has no image of its own", so it falls back to
the base image. An absent `--dockerfile` means the caller asked for something that is not
there, so it is an error. Falling back there would be the same class of silent wrong answer as
the two failures above, in a different costume.

## Consequences

- **What it rules out.** A project whose sandbox needs something that cannot be expressed in a
  Dockerfile, such as a host service or a kernel module.
- **What it makes worse.** First launch in a repository with a new Dockerfile pays a full
  image build, and the Playwright layer alone pulls about 108 MB of Chromium. A digest-tagged
  image is also never garbage collected by arena, so editing a Dockerfile repeatedly leaves
  every intermediate tag behind.
- **What stays open.** Whether arena should ship a base image, rather than requiring one to
  exist. `arena.baseImage` names it and arena fails with an actionable message when it is
  missing, but supplying it is still the reader's problem. This is the main thing standing
  between a stranger and a working sandbox.
- **What now depends on it.** `ImageResolver`, and `.arena/Dockerfile` plus `.arena/arena-init`
  in every repository that has one.

## Evidence

The stale-image failure was reproduced rather than predicted. On 2026-09-14 a container
launched for the `e2e` lane reported the base image while a correctly built per-repository
image existed, because the Dockerfile had been written into the worktree and the resolver
looked only at the repository root.

Build cost measured the same day for a first image carrying node, Chromium and Postgres:
Chromium 147.0.7727.15 is a 107.5 MiB download, and the image export took 33.9 s after the
layers were built.

Not verified: that `container build` reuses layers across digest-tagged builds as effectively
as Docker does. It appeared to, but no measurement was taken of a rebuild after a one-line
Dockerfile change.

## Notes

`.arena/` rather than a top-level `Dockerfile` because most of these repositories already have
a `Dockerfile` that builds the production image, and the two must not be confused.

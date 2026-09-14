# FF-140926 — Ubuntu noble's git 2.43 refuses every command in a modern worktree

**When:** 2026-09-14 (first hit earlier, recorded here when the image was rebuilt)
**Where:** the `elixir-agent` sandbox image, running any git command inside a mounted worktree
**Versions:** git 2.43 (Ubuntu noble), git 2.51 (host, Homebrew),
`hexpm/elixir:1.20.4-erlang-29.0.6-ubuntu-noble-20260810`
**Upstream:** none — the fix is a newer git, which the git-core PPA already provides

## What happened

arena mounts a git worktree into the sandbox and expects git inside the container to work
against it. Every git command failed instead, because the worktree was written by a host git
new enough to set `extensions.relativeWorktrees` and read by a container git too old to know
what that extension is.

The repository sets the extension; git 2.43 does not recognise it; git's rule for an
unrecognised repository extension is to refuse rather than to ignore.

## The signal

```
fatal: unknown repository extension found:
        relativeworktrees
```

Every command, including `git status`. The message is accurate and names the extension, which
is why this entry is short and the previous one is long. It does not say which git version
introduced support, so the fix still takes a search.

## What it cost

Perhaps twenty minutes, nearly all of it typing rather than confusion. The error names the
problem precisely enough that the only open question was which version to install and where to
get it.

## What we did instead

Add the git-core PPA to the image rather than accepting Ubuntu's git:

```dockerfile
RUN add-apt-repository -y ppa:git-core/ppa \
    && apt-get update && apt-get install -y --no-install-recommends git
```

This is also why the image installs `software-properties-common` and then purges it in the
same layer.

## What would fix it

Nothing upstream, which is why this is filed as `none`. Ubuntu noble shipping git 2.43 is
Ubuntu working as intended, and git refusing an unknown extension is git working as intended.

The entry exists because the combination is invisible until it bites: a base image chosen for
its Elixir version silently determines whether git works against the host's worktrees. Anyone
changing the `FROM` line in `.arena/Dockerfile` or the shared base needs to know this, and the
only place that knowledge lives is a comment in a Dockerfile and this file.

**Resolved:** not resolved upstream, and will not be. The PPA is the permanent answer for as
long as the base is Ubuntu noble.

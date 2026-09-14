# Friction log

Obstacles hit while building, where **the fix is somewhere else** — usually in someone else's
repository. That is what distinguishes friction from a bug: the entry stops being true when
that fix lands, and until then it is the cheapest thing in this repository to read.

**This directory is append-only.** Never edit an entry to bring it up to date and never reorder
entries — an entry records a moment and its value is that it can be dated. Add a **Resolved**
line at the bottom when the upstream fix lands. Delete the file when it stops being useful to
anyone.

**Nothing here expires on its own.** Before trusting an entry, check the versions it names
against what is installed today.

Start from [`FF-000-TEMPLATE.md`](FF-000-TEMPLATE.md). Naming is `FF-DDMMYY-kebab-slug.md`.

| Entry | Upstream | What |
|---|---|---|
| [FF-140926](FF-140926-container-defaults-strand-chromium.md) | apple/container, not filed | A 64 MB `/dev/shm` kills Chromium with `Target closed` and no attributable error |
| [FF-140926](FF-140926-noble-git-cannot-read-relative-worktrees.md) | none | Ubuntu noble's git 2.43 refuses every command in a worktree using `extensions.relativeWorktrees` |

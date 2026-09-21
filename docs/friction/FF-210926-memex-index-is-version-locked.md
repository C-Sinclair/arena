# FF-210926 — memex refuses its own index after an upgrade, and searching needs write access

**When:** 2026-09-21
**Where:** giving the sandbox memex, so a lane can search the host's conversation index
**Versions:** memex 0.12.2 then 0.23.1 (nicosuave/tap), Apple container 0.13.1, macOS 25.6.0 arm64, ubuntu:24.04 guest
**Upstream:** reportable against nicosuave/memex, not filed

## What happened

Two separate obstacles, both in memex, hit while working out whether a Linux build in the sandbox could share the index the macOS host had built.

The index turned out to be version-locked in a way nothing advertises. `brew upgrade memex` from 0.12.2 to 0.23.1 left every command failing until the whole index was rebuilt. Nothing warned before the upgrade, and the old binary was already gone by the time the error appeared. Had the Linux build in the sandbox been pinned to `latest` rather than to the host's version, the container would have been the thing that broke the host's index.

Searching also needs write access to the index directory. A read-only mount was the obvious way to let a sandbox search without being able to damage anything, and it does not work. The failure names the filesystem, not the lock file it wanted, so it reads as a broken mount rather than as a deliberate requirement.

## The signal

After the upgrade, on every command including `memex stats`:

```
Error: index at /Users/conor/.memex/index/generations/000000000000000018d74705f1901248-00007fc4 uses term dictionaries this build cannot read; run `memex index rebuild`
```

That one is a good error. It names the path, the cause and the fix.

With `~/.memex` mounted read-only in the guest:

```
Error: all machine searches failed: local: Read-only file system (os error 30)
```

That one is not. It does not say what it tried to write, and `memex stats` against the same read-only mount succeeds, which suggests the mount is fine.

## What it cost

Most of the time went on the read-only failure, and it was confusion rather than typing. `stats` working made the mount look correct, so the first guess was a permissions problem on one subdirectory. Mounting `index` and `vectors` read-only with a writable `state` failed identically, which is what ruled that out.

The rebuild after the upgrade was unattended and took a few minutes for 397,613 records.

## What we did instead

The Linux build is pinned to whatever `memex --version` reports on the host, fetched from the matching GitHub release. The version cannot skew, because it is derived rather than chosen.

`~/.memex` is mounted read-write. A search was measured against a copy first, and it changes nothing that matters: after `memex search`, the only file differing from the original was `state/scan_cache.json`. No index generation, no vector file, no `CURRENT`.

Reproducing the read-only failure:

```
container run --rm -i \
  --volume ~/.memex:/root/.memex:ro \
  --volume <dir holding a linux memex>:/opt/memexbin:ro \
  ubuntu:24.04 /opt/memexbin/memex search anything
```

## What would fix it

`memex search` should open the index read-only when it only reads it. Failing that, the error should name the file it could not open for writing and say that search requires a writable index directory, rather than reporting the filesystem.

`memex --version` should say when the index on disk was written by an incompatible build, so the mismatch is visible before an upgrade rather than after. A formula caveat naming the rebuild would also have been enough.

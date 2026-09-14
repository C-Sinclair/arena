# ADR-006 — Project services run inside the sandbox, on a host-backed state mount

**Status:** accepted
**Date:** 2026-09-14
**Deciders:** Conor Sinclair
**Relates to:** [ADR-004](ADR-004-repositories-declare-their-own-image.md),
`Sources/arena/Host/SandboxHome.swift`

## The decision

A service a project's tests need, such as Postgres, is installed by the project's
`.arena/Dockerfile` and started by an `arena-init` script the image provides at
`/usr/local/bin/arena-init`. arena runs that script inside the sandbox before launching the
agent. Durable state for those services goes in `~/.arena/state/<repo>`, mounted at
`/var/lib/arena`, one directory per repository rather than per lane.

## Context

arena always runs with `--rm`, so the container's root filesystem is destroyed when the agent
exits. A database initialised on that filesystem is re-seeded on every launch, and seeding is
not cheap.

The choice of where the database runs was forced by the project rather than chosen. The
repository that prompted this hardcodes `hostname: "localhost"` with `username: "postgres"` in
its test configuration, so anything other than a Postgres on the sandbox's own loopback
requires changing that repository first. That is a common enough shape in Elixir and Rails
projects to design for rather than to treat as one project's quirk.

## Options considered

### Option A — a sidecar container with its own address

The conventional arrangement, and the one Docker Compose would produce. Costs an upstream
change to every project whose config hardcodes `localhost`, plus container-to-container DNS,
plus a second lifecycle for arena to manage. **Lost on the hardcoded hostname.**

### Option B — reach the host's own Postgres

No container to manage at all. Costs the same config change as Option A, and it puts sandbox
data in the developer's real cluster, which defeats the point of a sandbox. **Lost.**

### Option C — in-sandbox service, ephemeral data

Works with the config as written, and needs no state mount. Costs a full re-seed on every
launch. **Lost on seeding cost.**

### Option D — in-sandbox service, data on a host-backed mount (taken)

Costs a mount arena has to provide and a convention the project has to follow.

## Decision and why

Option D, because it is the only one that needs no change to the projects being sandboxed, and
because the per-repository rather than per-lane granularity turned out to be free.

Sharing one cluster across every lane of a repository would normally be a collision risk.
It is not here, because the projects that want durable state already derive their database
name from the current branch, so each lane gets its own database inside the shared cluster.
That namespacing is what makes one cluster per repository safe, and a project that does not do
it should not opt into the state mount.

The service also runs as the agent user with its data directory on the bind mount, rather than
through Debian's `postgresql-common` cluster tooling. That tooling insists on
`/var/lib/postgresql` owned by the `postgres` user, which fights a bind mount owned by the host
user. Running `initdb` and `pg_ctl` directly sidesteps the uid mismatch entirely.

## Consequences

- **What it rules out.** Two lanes of the same repository running incompatible schema
  migrations at once. They share a cluster, and only the database names are separated.
- **What it makes worse.** State now outlives the sandbox, so a corrupted cluster survives a
  teardown and needs `rm -rf ~/.arena/state/<repo>` by hand. arena has no command for that.
- **What stays open.** Whether `arena-init` failing should abort the launch. Today it runs and
  the agent starts regardless, so a project whose database failed to start gets an agent and a
  confusing test failure.
- **What now depends on it.** `SandboxHome.state`, the `/var/lib/arena` mount, and the
  `arena-init` contract in `New.command(agent:)`.

## Evidence

Verified on 2026-09-14 in a built image:

```
PGPASSWORD=postgres psql -h localhost -U postgres -tAc 'select 1'   →   1
```

The repository this was built against derives its database name from the branch, sanitising it
and prefixing the application name, then suffixing the Mix environment. Two lanes of that
repository therefore never address the same database. That is the basis for the claim that one
cluster per repository is safe, and it is a property of the project rather than of arena.

Not verified: the persistent-mount arrangement itself. The working `psql` above came from an
earlier build that used Debian's cluster tooling and an ephemeral data directory. The
`initdb`-on-a-bind-mount version described here is written but was not built, because the build
was interrupted.

## Notes

`arena-init` is run through `command -v arena-init >/dev/null && arena-init`, so an image that
provides no such script is not an error. That keeps the base image usable unchanged.

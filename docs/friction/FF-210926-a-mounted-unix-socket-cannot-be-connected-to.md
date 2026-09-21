# FF-210926 — A mounted unix socket appears in the guest but refuses every connection

**When:** 2026-09-21
**Where:** trying to give a sandbox the host's 1Password SSH agent, so a lane can sign commits
**Versions:** Apple container 1.3.1, macOS 25.6.0 arm64, ubuntu:24.04 guest, 1Password 8
**Upstream:** reportable against apple/container, not filed

## What happened

Signing a commit in a lane needs the 1Password SSH agent, and `op-ssh-sign` is a Mach-O binary that cannot run in a Linux guest. The alternative is `ssh-keygen -Y sign` against the agent socket, which needs that socket inside the sandbox. `--volume` shares the directory holding it and the socket does appear in the guest, with the right type, so it looks like it worked. Connecting to it fails.

Mounting 1Password's own directory is worse. `~/Library/Group Containers/2BUA8C4S2C.com.1password/t` is a macOS sandboxed path, and mounting it does not fail: `container run` sits at `Starting container` and never proceeds. It ran for 14 minutes 39 seconds before being killed, and left the runtime wedged afterwards — every later `container run`, including one with no mounts at all, hung the same way until `container system stop` and `container system start`.

## The signal

The socket is there, and `ls` shows it as a socket:

```
srwxr-xr-x? 1 root root   0 Sep 21 15:53 t.sock
```

Connecting to it, from the guest, with a listener accepting on the host:

```
nc: /sk/echo.sock: Operation not supported
```

For the 1Password path there is no error at all. The progress line keeps counting:

```
[6/6] Starting container [14m 39s]
```

## What it cost

The wedged runtime is the expensive part, and it is expensive because it is silent and it outlives the command that caused it. Three measurements taken after it were all wrong in the same direction, including a control that was supposed to rule the socket out, and they pointed at the socket being the cause when it was not. Only running a container with no mounts at all showed the runtime itself was gone.

The socket result was quick once the runtime was healthy: two containers, one control and one test.

## What we did instead

Nothing yet. Mounting the agent is a dead end, so the options are a relay on the host bridging the agent socket to something the guest can reach over the network, or a signing key that belongs to the sandbox rather than to 1Password.

To reproduce the connection failure, with a listener on the host:

```
container run --rm -i --volume /private/tmp/sk:/sk ubuntu:24.04 \
  bash -lc 'apt-get update -qq && apt-get install -y -qq netcat-openbsd && nc -U /sk/echo.sock'
```

## What would fix it

`--volume` of a directory containing a socket should either forward the socket, as Docker Desktop does for the ssh-agent, or say plainly that it cannot. A socket that appears with the right type and then refuses `connect` is the worst of both.

Mounting a path the runtime cannot read should fail with that path named, rather than hanging at `Starting container`. Hanging is bad; leaving the API server unusable for every later container is what turns one mistake into an hour.

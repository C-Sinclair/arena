# FF-140926 — Apple container's 64 MB /dev/shm kills Chromium with no attributable error

**When:** 2026-09-14
**Where:** running a Playwright suite inside an Apple container sandbox
**Versions:** container 1.3.1, macOS 25.6.0 (Darwin 25.6.0), Playwright 1.59.1, Chromium
147.0.7727.15
**Upstream:** reportable — apple/container, not filed

## What happened

A Playwright suite that passes on the host could not run in an Apple container sandbox. The
expectation was that more memory would fix it. Memory was half the problem, and the half that
cost the time was `/dev/shm`.

Apple container's defaults are 4 CPUs, 1 GB of memory and a 64 MB `/dev/shm`. Chromium maps
renderer shared memory into `/dev/shm`. When it fills, the browser process dies.

## The signal

The memory half announces itself honestly, via the OOM killer and an obviously small `free`:

```
Mem:            1101        364        419          0        335        737
```

The `/dev/shm` half does not. Chromium reports:

```
Target closed
```

Nothing in that message names shared memory, the mount, or the container runtime. It is
identical to the error a genuinely crashed page produces, so it reads as a flaky test in the
application rather than as an exhausted mount in the sandbox. `df -h /dev/shm` is the only
thing that shows it, and there is no reason to run it unless you already suspect the answer:

```
tmpfs            64M     0   64M   0% /dev/shm
```

## What it cost

Most of an hour, and almost all of it confusion rather than typing. The memory limit was found
in minutes because `free` makes it obvious. The `/dev/shm` limit was found only by checking the
mount on the suspicion that "Target closed" was environmental, which is a guess rather than a
deduction.

## What we did instead

Pass both explicitly on every run, rather than relying on the defaults:

```
container run --cpus 6 --memory 8g --shm-size 2g ...
```

Verified afterwards from inside the sandbox:

```
Mem:            8071 MB total
tmpfs            2.0G  /dev/shm
chrome --headless --no-sandbox --dump-dom about:blank
  → <html><head></head><body></body></html>
```

The alternative workaround is `--disable-dev-shm-usage` in Chromium's launch arguments, which
pushes shared memory to disk. Rejected because it is slower and because it would require every
project's Playwright config to know it is running in a sandbox.

## What would fix it

A larger default `/dev/shm`. Docker defaults to 64 MB too and has the same complaint filed
against it repeatedly, so there is prior art for the argument that the default is wrong for
anything running a browser.

Failing that, a warning. The runtime knows the size of the mount it created, and a container
whose `/dev/shm` is at 64 MB is one `docker run` idiom away from a class of failure that
produces no attributable error. Even a line in `container run --help` next to `--shm-size`
saying what needs raising it would have saved the hour.

# FF-250926 — A `.build` copied into a lane worktree fails `swift build`

**When:** 2026-09-25
**Where:** `swift build` in the `claude-refresh` lane worktree
**Versions:** Apple Swift 6.2.3 (swiftlang-6.2.3.3.21), lane 0.1.0
**Upstream:** reportable against lane or SwiftPM, not filed

## What happened

The new lane worktree already had a `.build` directory, carried over from the main checkout. SwiftPM reused its precompiled headers, which embed the main checkout's absolute module cache path, and the build failed before compiling any arena source.

## The signal

```
<unknown>:0: error: PCH was compiled with module cache path '/Users/conor/Repos/C-Sinclair/arena/.build/arm64-apple-macosx/debug/ModuleCache/4C4IVB1EDHMW', but the path is currently '/Users/conor/Repos/C-Sinclair/arena/.lane/trees/claude-refresh/.build/arm64-apple-macosx/debug/ModuleCache/4C4IVB1EDHMW'
<unknown>:0: error: missing required module 'SwiftShims'
error: fatalError
```

## What it cost

One failed build. The message names both paths, so the cause was readable.

## What we did instead

```sh
rm -rf .build/arm64-apple-macosx/debug/ModuleCache
swift build
```

## What would fix it

lane not copying `.build` into a new worktree, or SwiftPM invalidating a module cache whose recorded path differs from its location.

# CLAUDE.md — arena

**arena runs a coding agent in a disposable sandbox, one per git worktree.** See
[README.md](README.md) for what it is and how it got here.

It **replaces the `sand` and `sandc` fish functions** in my private dotfiles repository. Those
are still live until
[DD-001](docs/designs/DD-001-the-arena-cli.md) stage 3 deletes them, so a change to sandbox
behaviour may need making in both places until then.

## What arena is

arena is an **orchestrator, not a computation**. It spends its time in `container`, `git`,
`gh`, `lane` and `herdr`, and one `container` call costs about 42 ms against roughly 2 ms of
arena. Optimising arena's own code is not a thing worth doing. Reducing the number of
subprocesses might be.

Two consequences for how code here should be written:

- **Never build a shell string.** `Shell.run` takes an argument array. The one place a string
  is unavoidable is `herdr pane run`, and that path quotes every argument through
  `shellQuoted`. String concatenation of command lines is the bug class this rewrite exists to
  kill.
- **Build the sandbox as a value.** `SandboxSpec` is assembled, then turned into an argument
  vector once by `ContainerRuntime.runArguments`. The direct launch and the Herdr launch must
  stay the same sandbox by construction, not by two code paths agreeing.

## Where the reasoning lives

Three directories under `docs/`, with non-overlapping purposes
([ADR-007](docs/decisions/ADR-007-docs-are-four-kinds.md)). Each has an `INDEX.md`. **Put a
document in exactly one place**, by which question it answers:

| Question | Where | Naming |
|---|---|---|
| Why is it this way, and what lost? | [docs/decisions/](docs/decisions/INDEX.md) | `ADR-NNN-kebab-title.md` |
| What are we building, and where does it stop? | [docs/designs/](docs/designs/INDEX.md) | `DD-NNN-feature-name.md` |
| What wasted an hour, and whose fault is it? | [docs/friction/](docs/friction/INDEX.md) | `FF-DDMMYY-kebab-slug.md` |

**Read [ADR-001](docs/decisions/ADR-001-drive-the-container-cli.md) before changing how arena
talks to the runtime**, and [ADR-004](docs/decisions/ADR-004-repositories-declare-their-own-image.md)
before changing image resolution. ADR-004 records two failures that already happened once each;
both are easy to reintroduce.

### Rules that differ per directory

- **ADRs and design docs are edited in place.** They should say what is true *now*, so a reader
  never has to work out which of two files is current. Git carries the history. Set an ADR's
  **Status** to `reversed` and rewrite the body rather than opening a successor file.
- **Friction logs are append-only.** Never edit an entry to bring it up to date and never
  reorder them. Add a **Resolved** line when the upstream fix lands; delete the file when it
  stops being useful.
- **A decision taken *during* design work is an ADR**, not a paragraph inside the design doc.
- **Update the `INDEX.md`** in the same commit as the document. There is no link checker here
  yet, so an index can be silently incomplete and a cross-reference silently broken.
- **Templates** are `ADR-000-TEMPLATE.md`, `DD-000-TEMPLATE.md`, `FF-000-TEMPLATE.md`. Start
  from them and keep the section order; these documents are read by skimming headings.

### Write a friction log when you hit friction

The directory most likely to be skipped and the one with the best return. If a tool did
something surprising, an error pointed the wrong way, or something needed a workaround, **write
the entry before moving on**, while the error text is still to hand. The distinguishing feature
of friction is that **the fix is somewhere else**.

Name the versions. Quote the signal verbatim, or state plainly that there was none — "it
silently did nothing" is the most expensive shape and the hardest to search for. Say what you
did instead; the workaround is the most useful line in the file.

## Sections that carry the weight

When writing or reviewing a design doc, none of these may be dropped: **what this proves**,
**non-goals**, **measurements this must produce**, **where it stops**. For an ADR: **options
considered**, with the cost of each including the ones tried and abandoned, and **evidence**.

## Measurement discipline

This repository has already made one decision on measurement and one on judgement, and both are
labelled as such. Keep that up.

- **Never claim speed without a number.** The language choice in
  [ADR-003](docs/decisions/ADR-003-write-arena-in-swift.md) rests on a 0.43 ms difference that
  turned out not to matter against a 42 ms subprocess. Most performance arguments here go the same way.
- **Name the measurements before doing the work.** It is what stops a convenient subset being
  reported later. A *cliff* needs the parameter that triggers it stated, not just the good
  number.
- **Label an estimate as an estimate.** A decision made on judgement is fine; one that pretends
  to evidence it does not have is not.
- **Say what was not verified.** Every ADR here has such a line. `arena new` has never been run
  end to end, and no document may imply otherwise.

## Swift

Swift 6.2, SwiftPM, `swift-testing`. `swift build`, `swift test`, `swift format` if it is
installed. Xcode is not part of the workflow.

- **One dependency**, `swift-argument-parser`. Adding a second needs a reason in an ADR.
- **Decode narrowly.** `ContainerRuntime`'s `Decodable` types name only the fields arena uses,
  so an upstream addition to `container`'s JSON is not a compile error here. Keep that.
- **Errors are typed and printable.** `CommandFailure` carries the command, the status and
  stderr. A failure that reaches the user should say which subprocess failed and what it said.
- **Comments explain why, never what.** The comments carried over from the fish functions are
  the most valuable thing in this repository: each one records a failure that already happened.
  Do not delete one to tidy up, and do not add one that restates the code.

## Prose conventions

Blunt and specific. State costs as flatly as benefits, name what lost, say where things stop.

- **Lead with the claim**, then the reasoning. A reader who stops after the first paragraph
  should be able to act correctly.
- **Every real decision makes something worse.** If a document does not say what its subject
  costs, it is incomplete.
- **Name the thing.** A module, a function, a flag, a file. If a metaphor is standing in for the
  name, go and find the name.

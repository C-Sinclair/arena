# ADR-007 — Split project documentation into four kinds, and keep them separate

**Status:** accepted
**Date:** 2026-09-14
**Deciders:** Conor Sinclair
**Relates to:** [`../../CLAUDE.md`](../../CLAUDE.md), and the `INDEX.md` in each documentation
directory

## The decision

Project documentation lives in `docs/` under three numbered kinds with non-overlapping
purposes:

- **[`decisions/`](INDEX.md)** — `ADR-NNN`. An architectural decision, with the options that
  lost and the evidence.
- **[`designs/`](../designs/INDEX.md)** — `DD-NNN`. One document per planned or built feature.
- **[`friction/`](../friction/INDEX.md)** — `FF-DDMMYY`. Append-only logs of obstacles hit
  while building.

Each directory has an `INDEX.md` listing its contents. Put a document in exactly one place, by
which question it answers.

## Context

This repository is a rewrite of two shell functions whose entire design rationale lived in
comments inside the functions and in one conversation. That rationale is the expensive part:
the measurements behind the language choice, the reason the container CLI is driven rather than
linked, and the two ways the image resolution failed before it worked. Comments in a source
file cannot hold options that lost.

There is also an agent-specific forcing function. Most work here is done by an agent with a
fresh context window, which will re-derive anything not written down and re-litigate anything
written down ambiguously.

## Options considered

### Option A — comments and a README

The status quo carried over from the shell functions, which ran to 94 lines of comment against
178 of code. A high ratio, and it still could not record a rejected option. **Lost.**

### Option B — five kinds, adding `glossary/` and `sources/`

The arrangement a sibling project of mine uses, where several words mean something narrower
than a reader assumes and where decisions rest on an external benchmark. Neither applies here:
arena's vocabulary is `container`'s vocabulary, and its evidence is measurements taken on one
machine, which belong in the ADR that used them. **Lost, deliberately and with the expectation
of being revisited.**

### Option C — three kinds, with an index each (taken)

Costs ceremony on every document and a judgement call at write time about which directory a
document belongs in.

## Decision and why

Option C, because three kinds answer three different questions and the test for where a
document goes is which question it answers:

| Question | Kind |
|---|---|
| Why is it this way, and what lost? | decision |
| What are we building, and where does it stop? | design |
| What wasted an hour, and whose fault is it? | friction |

The distinguishing feature of friction is that the fix is somewhere else, usually in someone
else's repository, so the entry stops being true when that fix lands. That is why it is
append-only and timestamped while ADRs are edited in place: an ADR should say what is true now,
whereas a friction log is a record of a moment and reordering it would destroy its value.

Adopting an arrangement already in use rather than inventing one is deliberate. The templates
are carried over near-verbatim from a sibling project, so anyone moving between them reads the
same sections in the same order.

## Consequences

- **What it rules out.** A document that is half decision and half plan. Split it. A decision
  taken during design work is an ADR, not a paragraph inside the design doc.
- **What it makes worse.** Three indexes to keep current by hand, and they will drift. There is
  no link checker in this repository yet, so a broken cross-reference is caught by nobody.
- **What stays open.** Whether `glossary/` and `sources/` arrive later. If arena grows terms
  that mean something narrower here than in general use, the glossary comes back.
- **What now depends on it.** [`CLAUDE.md`](../../CLAUDE.md) points at these paths, as does
  every cross-reference under `docs/`.

## Evidence

Prior art in a sibling project, which is the whole basis for this: 5 ADRs, 2 design docs and 1
friction entry under exactly this arrangement, with its own ADR recording the reasoning that
produced it. The friction format originates with
[wevm/frog](https://github.com/wevm/frog); its tooling is not adopted.

Not verified: that three indexes stay current without tooling. They probably will not, and the
sibling project records the same open risk.

## Notes

The sibling project also keeps a `docs/agent-logs/` directory of distilled transcripts. Not
adopted here yet. Worth revisiting once this repository has had more than one session of work
done on it.

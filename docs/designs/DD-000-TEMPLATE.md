# DD-000 — Template

> Copy to `DD-NNN-short-kebab-title.md` and delete this blockquote. Sections marked
> *(optional)* can be dropped when they genuinely do not apply — but drop them, do not leave
> them empty, and do not drop **Non-goals**, **Where it stops**, or **Measurements**, which are
> the three that keep a design doc honest.
>
> One design doc per feature. A decision taken *during* the work is an
> [ADR](../decisions/INDEX.md), not a paragraph in here — link it rather than restating it.

**Status:** draft | building | built | abandoned
**Date:** YYYY-MM-DD
**Decisions:** the ADRs this rests on, as links into [`../decisions/`](../decisions/INDEX.md) —
real files only, a link checker runs here
**Lands in:** the modules, binaries, or services this becomes

## What this is

Two or three sentences. What gets built, and what it is made of.

## What this proves

The claims this feature is *for*. Each one should be checkable — if a claim cannot be tied to a
test, a measurement, or a thing a reader can run, it is a hope rather than a claim. Write them
as a list, most load-bearing first.

## Why it needs a sandbox

The specific reason this needs a disposable container rather than a directory and a shell. If
the honest answer is "it does not, but it keeps the host clean", write that — a design that
overstates the primitive is worse than one that admits what it is standing in for.

State **what crosses the boundary** — which host paths are mounted, which credentials are
copied in, and what the sandbox can reach on the network — and why that set and not a smaller
one.

## Non-goals

What this deliberately does not do. This is the most re-read section of every design doc in
this repo, because it is what stops scope arriving by accident later.

## Threat model *(optional — required for anything touching keys, isolation, or untrusted input)*

A table of adversary → what they get → what stops them. Include the rows where the answer is
"nothing stops them", because those are the rows that matter.

## Data model

What lives in the image, what lives on a host-backed mount, and what is regenerated on every
run. Name anything written into the sandbox from the host — credentials especially — and say
whether it is copied or mounted, and why.

## Trade-offs

The alternatives considered at the *product* level, with their costs. Where a choice was
genuinely architectural it belongs in an ADR instead. Where a measurement decided it, give the
number.

## Measurements this must produce

The numbers this work owes, named in advance, with how the run was parameterised (dataset size, warm or
cold, median of how many). Naming them up front is what stops a convenient subset being
reported later. Note which are *cliffs* rather than slopes — a cliff needs the parameter that
triggers it stated, not just the good number.

## Staging

The order of the work, with what each stage makes checkable. A stage that produces nothing
verifiable is a stage that cannot be reviewed.

## Where it stops

The honest boundary. What a reader might reasonably assume is handled here and is not.

## Open risks

Known-unresolved problems, each with what it would take to close. Do not promote a risk to
"handled" here without evidence somewhere else in the repo.

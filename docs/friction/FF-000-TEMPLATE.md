# FF-000 — Template

> Copy to `FF-DDMMYY-short-kebab-slug.md` and delete this blockquote. `DDMMYY` is the day it
> was hit. If two entries land on one day, the slug distinguishes them.
>
> **This directory is append-only.** Do not edit an entry to bring it up to date and do not
> reorder entries — an entry is a record of a moment, and its value is that it can be dated.
> When the upstream fix lands, add a **Resolved** line at the bottom; when the entry is no
> longer useful to anyone, delete the file.

**When:** YYYY-MM-DD
**Where:** the file, task, or command this happened in
**Versions:** every tool that is part of the story, with its version. Friction is against a
version, not against a project.
**Upstream:** reportable (and a link once filed) | ours | none — nothing to file against

## What happened

What was expected, and what happened instead. Two or three sentences.

## The signal

The error, verbatim, or the absence of one. Quote it — an entry without the actual message
cannot be found by the next person who searches for it. If there was **no** error, say so
explicitly and describe the symptom instead, because "it silently did nothing" is the most
expensive shape and the hardest to search for.

## What it cost

Roughly how long, and whether it was time spent confused or time spent typing. Confusion is the
expensive kind and it is what makes an entry worth filing upstream.

## What we did instead

The workaround, precisely enough to copy.

## What would fix it

The change in the other project, if there is one. Be concrete: a better error message, a
default flipped, a flag that should not be needed, a timeout that should exist.

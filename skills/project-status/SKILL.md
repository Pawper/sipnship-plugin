---
name: project-status
description: Find out where every open issue and pull request really stands, from their bodies and comments, without reading them yourself. Readers summarize only the items that changed since their last summary; you keep one line per item. Use when asked where things stand, before proposing work, or when the session brief says summaries are out of date.
---

# Project status

Titles and labels say what an item is called and what someone last set. The body and the comments say where it
stands: whether the owner answered, why it is blocked, who has the ball. Reading all of that yourself costs
your context on every session. So do not read it. Fetch it to disk, let light readers summarize it, and keep
one line per item. A summary is saved with the item's last-updated time, so an item that has not changed is
never read twice.

## 1. Read what changed

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/board/read.sh"
```

One cheap call lists every open item with its last-updated time. Items whose saved summary is missing or older
get their full text fetched, in one more call, to `.scratch/board/items/`. The script prints counts and
batches of file paths, never the text. If it says every summary is current, skip to step 4.

## 2. Hand the batches to readers

Do not open the item files yourself. Two ways, same result:

**Subagents.** Dispatch one agent per batch line, all in one message so they run together, each with model
`haiku` and this brief: read each listed file in full, and for each return exactly one line,
`NUMBER | BALL | NEXT | BLOCKER | SUMMARY`, where BALL is one of owner, agent, reviewer, service, nobody; NEXT
is the next concrete step in at most twelve words; BLOCKER is what stops it in at most ten words or `-`; and
SUMMARY is one sentence saying what is asked, what was decided, and the latest thing that happened and who said
it. The newest comment outranks the body and the labels. No guessing: "not stated" when the text does not say.

**The workflow.** When the person has asked for a workflow, or there are many batches, run the plugin's
`board-digest` workflow with the batches as its argument, `{batches: [["path", "path"], ["path"]]}`. It runs one
reader per batch and returns the lines.

## 3. Save the lines

Pipe every returned line into the digest, which stamps each with the item's current last-updated time and drops
items that are no longer open:

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/board/digest.sh" save
```

A batch that returned nothing is not an error: its items stay marked as changed and are read next time.

## 4. Use the digest

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/board/digest.sh" show
```

One line per open item, the ones waiting on someone first. This is what you answer from when asked where
things stand. `digest.sh goals` prints what the digest adds to a drive proposal: an issue labeled waiting on
owner that the owner has answered, and an issue labeled ready or in progress with an open question to the
owner.

## Rules

- Never read the item files into your own context, and never fetch issues one at a time in a loop. The reader
  script and the readers exist so you do not have to.
- The digest is a cache, not a record. The issues and pull requests are the record. If a line matters to a
  decision, the reader of that one issue confirms it before anything is changed.
- `read.sh --all` re-reads everything; use it when the summaries look wrong, not routinely.

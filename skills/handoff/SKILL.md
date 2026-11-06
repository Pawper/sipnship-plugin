---
name: handoff
description: Wind a coordinator session down gracefully. Stop starting work, wait for the session's agents (30 minutes at most), write the handoff as one comment on the drive issue, start the next session where the runtime can, then say it is done and stay idle. Use when asked to hand off, wind down, or end the session cleanly.
---

# Handoff

A coordinator's agents belong to its session: closing the session early stops them, and a new session starts cold
except for what GitHub records. This hands the work over so nothing is lost and the person decides nothing.

Run it when asked, or when the session is nearly out of room. Do the five steps in order.

## 1. Stop starting

No new agents, no new merge watchers, no new round. Say so in one line. Work already dispatched keeps going.

The same holds for feedback at any time, not only at the end: a change a person brings up is not dispatched as
it arrives. The coordinator files it as a ready issue and leaves the planning to the drive, which gives it to the
running unit in its area or bundles it in the next round. It starts at once only when the person says to start
it now, when something is broken and blocks work, or when it fixes an open pull request that is red or
conflicts with main. Say this in the handoff's standing rules, so the next coordinator keeps it.

## 2. Wait for what is in flight, bounded

Wait for this session's agents to finish and report. The cap is 30 minutes from now; note the clock when you
begin. Do not poll in a loop: agents report back on their own, so wait for those reports, and when the cap
arrives stop waiting. Anything still running is named with what is left of it: the pull request or branch, the
last thing it reported, and the next step. Record what each had finished.

## 3. Write the handoff

One comment on the drive issue (the open issue labeled `drive`), in plain words, written to `.scratch/handoff.md`.
Its first line must start with the word `Handoff`, with the local day and time, because the next session's brief
finds it by that line:

```
Handoff, Thursday 2026-11-05, 4:10 PM
What landed: ...one line each, by what a person gets
What is open and where it stands: ...each pull request or task, whose turn it is
What waits on the owner: ...each, with the question
Standing rules in force: ...for example a usage limit, a freeze, a hold, until when
Still running: ...each agent, what it is doing, what is left of it
```

Use the pull request's title as its name, with its GitHub number in a secondary place beside it. Say "none" for a
heading with nothing under it rather than leaving it out. Then post it:

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/drive/handoff.sh" post .scratch/handoff.md
```

It prints the comment's link. The next session's brief shows when the last handoff was written and where.

## 4. Start the next session

Where the runtime has a tool that starts a session (the Claude desktop app does), start one with this brief:
"Read the last handoff on the drive issue, then carry on." Give it the project folder. Where there is none, tell
the person in one line: start a new session in this project; its brief shows the handoff and it reads it by itself.

## 5. Wind down

Say it is done, in one or two sentences: what the handoff holds and whether the next session was started. Then
stay idle so the person can archive this session. Never close it yourself, and take no further action.

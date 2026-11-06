'use strict';
// What a session's log says about time and about the issues it touched, entry
// by entry (specs/010-work, "Data"). Kept beside sessions.js, which reads the
// rest of a session.
//
// A session's own time is its log entries' own timestamps, never the log
// file's date: a runtime can rewrite every file's date without writing a word.
//
// A touch is one entry of the log, at that entry's time, that names an issue
// or pull request by its number: a message the person sent (the runtime's own
// reminders and agents' reports inside it are not the person's), or a command
// or an agent task the session ran (its command, prompt or description). What
// the session read back, what it said, and the files it wrote are not touches:
// they name every number on a board or a page, not what it worked.
//
// The one rule for the spans: an issue's span runs from the first entry that
// touches it to the last. The issues the session was given (what its pull
// request body closes, else the number in its branch, else, for an agent, what
// the task it was started with names) are touched by every entry, so theirs
// runs from its start to its last entry.

const SPANS_MAX = 10;

/** A timestamp as epoch ms, or NaN when it is not one. */
const timeOf = (v) => (typeof v === 'string' && v ? Date.parse(v) : NaN);

/** The numbers a text names as an issue or pull request: #12, issues/12, pulls/12, pull/12, gh issue view 12. */
function namedIn(text) {
  const out = [];
  const add = (n) => { const v = Number(n); if (v > 0 && !out.includes(v)) out.push(v); };
  const t = String(text || '');
  for (const m of t.matchAll(/(?:^|[^&\w])#(\d{1,6})\b/g)) add(m[1]);
  for (const m of t.matchAll(/\/(?:issues|pulls?)\/(\d{1,6})\b/g)) add(m[1]);
  for (const m of t.matchAll(/\bgh\s+(?:issue|pr)\s+[a-z-]+\s+(\d{1,6})\b/g)) add(m[1]);
  return out;
}

/** What the person wrote in a message, without the runtime's own blocks in it. */
function personText(content) {
  const raw = typeof content === 'string' ? content
    : Array.isArray(content) ? content.filter((p) => p && p.type === 'text').map((p) => p.text).join('\n') : '';
  return raw.replace(/<(system-reminder|task-notification|local-command-stdout|command-message)>[\s\S]*?<\/\1>/g, ' ');
}

/** The text of an entry that can touch an issue, '' for one that cannot. */
function touchText(e) {
  const m = e && e.message;
  if (!m) return '';
  if (e.type === 'user' && !e.isMeta) return personText(m.content);
  if (e.type === 'assistant' && Array.isArray(m.content)) {
    return m.content.filter((p) => p && p.type === 'tool_use' && p.input && typeof p.input === 'object')
      .map((p) => [p.input.command, p.input.prompt, p.input.description].filter((v) => typeof v === 'string').join('\n')).join('\n');
  }
  return '';
}

/** A tally of the log's latest time and of each number's first and last touch, fed one entry at a time. */
function tally() {
  const touches = new Map();
  let last = NaN;
  return {
    add(e) {
      const at = timeOf(e && e.timestamp);
      if (Number.isNaN(at)) return;
      if (Number.isNaN(last) || at > last) last = at;
      for (const n of namedIn(touchText(e))) {
        const t = touches.get(n);
        if (!t) touches.set(n, { first: at, last: at });
        else { t.first = Math.min(t.first, at); t.last = Math.max(t.last, at); }
      }
    },
    /** The time of the log's latest entry, NaN when none carries one. */
    get last() { return last; },
    touches,
  };
}

/**
 * The spans a session touched each issue in, newest last touch first, at most
 * ten: its own issues from its start to its last entry, the others from
 * their first touch to their last.
 */
function spans(own, touches, startedMs, lastMs) {
  const by = new Map(touches);
  for (const n of own || []) by.set(n, { first: startedMs, last: lastMs });
  return [...by.entries()]
    .filter(([, t]) => !Number.isNaN(t.first) && !Number.isNaN(t.last))
    .sort((a, b) => b[1].last - a[1].last || a[0] - b[0])
    .slice(0, SPANS_MAX)
    .map(([number, t]) => ({ number, first: new Date(t.first).toISOString(), last: new Date(t.last).toISOString() }));
}

module.exports = { namedIn, touchText, tally, spans, timeOf, SPANS_MAX };

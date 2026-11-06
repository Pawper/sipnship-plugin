'use strict';
// A small digest of the session sample last sent for a repository, kept
// beside its throttle mark, so a send after a tool call goes only when some
// session's last line or state changed (specs/010-work, "Data").
//
// It is read on every check, so it is cheap and bounded: the newest twenty
// logs written in the last two hours, and of each only its last 64 KB, read
// from the end until the last thing the session said. The digest is the
// session, its last line (twelve words, as sent) and whether it has ended;
// never the line itself, only its hash, is kept.

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const sessions = require('./sessions');

const TAIL_BYTES = 64 * 1024;

/** The last line a log's tail says, '' when the tail holds none. */
function lastLineIn(text, whole) {
  const rows = String(text).split('\n');
  // A tail cut mid-line starts with part of one: dropped.
  if (!whole) rows.shift();
  for (let i = rows.length - 1; i >= 0; i--) {
    if (!rows[i].includes('"assistant"')) continue;
    let e;
    try { e = JSON.parse(rows[i]); } catch { continue; }
    const m = e && e.type === 'assistant' && e.message;
    if (!m || !Array.isArray(m.content)) continue;
    const said = m.content.filter((p) => p && p.type === 'text').map((p) => p.text).join('\n');
    if (said.trim()) return sessions.lastLine(said);
  }
  return '';
}

function tailOf(file, size) {
  const n = Math.min(size, TAIL_BYTES);
  const buf = Buffer.alloc(n);
  const fd = fs.openSync(file, 'r');
  try { fs.readSync(fd, buf, 0, n, size - n); } finally { fs.closeSync(fd); }
  return { text: buf.toString('utf8'), whole: n === size };
}

/** The digest of what the sessions in these worktrees last said and whether each ended. */
function digest({ worktrees = [], logsDir, endedFile, now = Date.now() } = {}) {
  const dir = logsDir || path.join(os.homedir(), '.claude', 'projects');
  const ended = sessions.endedAgents(endedFile || path.join(require('./tokens').home(), 'brief-send', 'agents-ended.tsv'));
  const logs = [];
  const seen = new Set();
  for (const tree of worktrees) {
    const folder = path.join(dir, sessions.logFolder(tree));
    if (seen.has(folder)) continue;
    seen.add(folder);
    for (const log of sessions.logsIn(folder)) {
      let st;
      try { st = fs.statSync(log.file); } catch { continue; }
      if (now - st.mtimeMs <= sessions.RECENT_MS) logs.push({ log, st });
    }
  }
  const rows = logs.sort((a, b) => b.st.mtimeMs - a.st.mtimeMs).slice(0, sessions.SESSIONS_MAX).map(({ log, st }) => {
    let line = '';
    try { const t = tailOf(log.file, st.size); line = lastLineIn(t.text, t.whole); } catch { /* unreadable: no line */ }
    const at = log.parent ? ended.get(log.name.replace(/^agent-/, '')) : undefined;
    return `${log.name}\t${line}\t${at && st.mtimeMs <= at + sessions.ENDED_SLACK_MS ? 'ended' : ''}`;
  });
  return crypto.createHash('sha1').update(rows.sort().join('\n')).digest('hex');
}

/** The digest kept after the last send, '' when none. */
function last(file) {
  try { return fs.readFileSync(file, 'utf8').trim(); } catch { return ''; }
}

function keep(file, value) {
  try { fs.writeFileSync(file, `${value}\n`); } catch { /* never stops the session */ }
}

module.exports = { digest, last, keep, lastLineIn, TAIL_BYTES };

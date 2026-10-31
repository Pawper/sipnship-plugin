'use strict';
// The session sample: what the agent sessions on this machine are doing, as
// a few facts each, sent with the brief (specs/010-work, "Data"). Read from
// the agent runtime's own session logs for this repository's worktrees; a
// field the logs do not carry is left out, never guessed. A last line is a
// few words, never a transcript: cut to twelve words here, before sending.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const WORDS_MAX = 12;
const SESSIONS_MAX = 20;
const RECENT_MS = 2 * 60 * 60 * 1000;

/** The first line of a message, in at most twelve words. */
function lastLine(text) {
  const first = String(text || '').split(/\r?\n/).map((l) => l.trim()).find((l) => l && !/^[`#>*-]+$/.test(l)) || '';
  const words = first.replace(/[`*_#>]/g, '').split(/\s+/).filter(Boolean);
  if (!words.length) return '';
  return words.slice(0, WORDS_MAX).join(' ') + (words.length > WORDS_MAX ? '…' : '');
}

/** Issue numbers named as #N in a text, first few, in order. */
function issuesIn(text) {
  const seen = [];
  for (const m of String(text || '').matchAll(/#(\d{1,6})\b/g)) {
    const n = Number(m[1]);
    if (!seen.includes(n)) seen.push(n);
    if (seen.length >= 5) break;
  }
  return seen;
}

/**
 * One session from its log's text (one JSON object per line): the start,
 * the model, the branch, the issues its first message names, the last thing
 * it said, and the tokens the runtime counted. Fields it lacks are absent.
 */
function readSession(logText, name) {
  let started; let model; let branch; let cwd; let last = ''; let issues = [];
  let tokens = 0; let counted = false;
  for (const raw of String(logText).split('\n')) {
    if (!raw.trim()) continue;
    let e;
    try { e = JSON.parse(raw); } catch { continue; }
    if (!e || typeof e !== 'object') continue;
    if (!started && e.timestamp) started = e.timestamp;
    if (e.gitBranch) branch = e.gitBranch;
    if (e.cwd) cwd = e.cwd;
    const m = e.message;
    if (e.type === 'user' && !issues.length && m) {
      const c = typeof m.content === 'string' ? m.content : (Array.isArray(m.content) ? m.content.map((p) => p && p.text).filter(Boolean).join(' ') : '');
      issues = issuesIn(c);
    }
    if (e.type === 'assistant' && m) {
      if (m.model && m.model !== '<synthetic>') model = m.model;
      const u = m.usage;
      if (u) {
        counted = true;
        tokens += (u.input_tokens || 0) + (u.output_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.cache_read_input_tokens || 0);
      }
      const text = Array.isArray(m.content) ? m.content.filter((p) => p && p.type === 'text').map((p) => p.text).join('\n') : '';
      if (text.trim()) last = text;
    }
  }
  if (!started) return undefined;
  const s = { session: name, started: new Date(started).toISOString() };
  if (issues.length) s.issues = issues;
  if (branch) s.branch = branch;
  if (cwd) { s.worktree = { name: path.basename(cwd), path: cwd }; }
  if (model) s.model = model;
  const line = lastLine(last);
  if (line) s.lastLine = line;
  if (counted && tokens > 0) s.tokens = tokens;
  return s;
}

/** The runtime's folder name for a working directory: every non-alphanumeric becomes a dash. */
function logFolder(cwd) {
  return String(cwd).replace(/[^A-Za-z0-9]/g, '-');
}

/** The repository's worktree folders, from git; empty when git is not there. */
function worktreesOf(root) {
  try {
    const out = execFileSync('git', ['-C', root, 'worktree', 'list', '--porcelain'], { encoding: 'utf8', timeout: 3000, stdio: ['ignore', 'pipe', 'ignore'] });
    return out.split(/\r?\n/).filter((l) => l.startsWith('worktree ')).map((l) => l.slice(9).trim());
  } catch {
    return [];
  }
}

/** How a session started, when the drive left a note: .scratch/drive/started-with.tsv, WORKTREE-NAME then round, next or hand. */
function startedWith(root, name) {
  try {
    for (const row of fs.readFileSync(path.join(root, '.scratch', 'drive', 'started-with.tsv'), 'utf8').split(/\r?\n/)) {
      const [n, how] = row.split('\t');
      if (n === name && ['round', 'next', 'hand'].includes(how)) return how;
    }
  } catch { /* no note: left out */ }
  return undefined;
}

/**
 * The sample: sessions whose log was written in the last two hours, newest
 * first, for the repository at root. logsDir is the runtime's log folder
 * (default ~/.claude/projects); worktrees may be given for tests.
 */
function readSessions({ root, logsDir, worktrees, now = Date.now() } = {}) {
  const dir = logsDir || path.join(os.homedir(), '.claude', 'projects');
  const trees = worktrees || worktreesOf(root);
  const out = [];
  for (const tree of trees) {
    const folder = path.join(dir, logFolder(tree));
    let files;
    try { files = fs.readdirSync(folder).filter((f) => f.endsWith('.jsonl')); } catch { continue; }
    for (const f of files) {
      let st;
      try { st = fs.statSync(path.join(folder, f)); } catch { continue; }
      if (now - st.mtimeMs > RECENT_MS) continue;
      let text;
      try { text = fs.readFileSync(path.join(folder, f), 'utf8'); } catch { continue; }
      const s = readSession(text, f.replace(/\.jsonl$/, ''));
      if (!s) continue;
      if (!s.worktree) s.worktree = { name: path.basename(tree), path: tree };
      const how = startedWith(root, s.worktree.name);
      if (how) s.startedWith = how;
      out.push({ ...s, _at: st.mtimeMs });
    }
  }
  return out.sort((a, b) => b._at - a._at).slice(0, SESSIONS_MAX).map(({ _at, ...s }) => s);
}

module.exports = { lastLine, readSession, readSessions, logFolder, WORDS_MAX };

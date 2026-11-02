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
const LOCAL_PREFIXES = ['ollama/', 'lmstudio/', 'local/'];
/** The kinds of work a session can be sorted under (specs/011-agent-plans). */
const CATEGORIES = ['building', 'fixing-check', 'merging-main', 'rerunning', 'restarting-queue', 'writing-spec', 'releasing-plugin'];

/**
 * A model id as the brief carries it: a local model's id begins ollama/,
 * lmstudio/ or local/. An id already prefixed stays; one the machine
 * declared in its services file (localModels, bare names) gets local/.
 */
function modelId(model, localModels = []) {
  if (!model) return model;
  if (LOCAL_PREFIXES.some((p) => model.startsWith(p))) return model;
  return localModels.includes(model) ? `local/${model}` : model;
}
const isLocal = (model) => LOCAL_PREFIXES.some((p) => String(model || '').startsWith(p));

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
function readSession(logText, name, { localModels = [] } = {}) {
  let started; let model; let branch; let cwd; let last = ''; let issues = [];
  let tokens = 0; let counted = false; let tIn = 0; let tCached = 0; let tOut = 0;
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
        tIn += (u.input_tokens || 0) + (u.cache_creation_input_tokens || 0);
        tCached += u.cache_read_input_tokens || 0;
        tOut += u.output_tokens || 0;
        tokens += (u.input_tokens || 0) + (u.output_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.cache_read_input_tokens || 0);
      }
      const text = Array.isArray(m.content) ? m.content.filter((p) => p && p.type === 'text').map((p) => p.text).join('\n') : '';
      if (text.trim()) last = text;
    }
  }
  if (!started) return undefined;
  const s = { session: name, started: new Date(started).toISOString() };
  // An agent that never named its issues in its first message may still have named them in its branch or folder: issue-538.
  if (!issues.length) issues = [...String((branch || '') + ' ' + (cwd ? path.basename(cwd) : '')).matchAll(/issue[-_/]?(\d{1,6})\b/gi)].map((m) => Number(m[1])).filter((n, i, a) => a.indexOf(n) === i).slice(0, 5);
  if (issues.length) s.issues = issues;
  if (branch) s.branch = branch;
  if (cwd) { s.worktree = { name: path.basename(cwd), path: cwd }; }
  if (model) s.model = modelId(model, localModels);
  // A local model costs nothing: the figure is stated, not left out.
  if (model && isLocal(s.model)) s.spend = 0;
  const line = lastLine(last);
  if (line) s.lastLine = line;
  if (counted && tokens > 0) {
    s.tokens = tokens;
    s.tokensIn = tIn;
    s.tokensCached = tCached;
    s.tokensOut = tOut;
  }
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

/**
 * How a session started, when the drive left a note: .scratch/drive/started-with.tsv,
 * WORKTREE-NAME, then round, next or hand, then (optionally) the kind of work,
 * one of CATEGORIES. A kind the list does not know is left out.
 */
function startedWith(root, name) {
  try {
    for (const row of fs.readFileSync(path.join(root, '.scratch', 'drive', 'started-with.tsv'), 'utf8').split(/\r?\n/)) {
      const [n, how, kind] = row.split('\t').map((f) => f.trim());
      if (n !== name) continue;
      const out = {};
      if (['round', 'next', 'hand'].includes(how)) out.how = how;
      if (CATEGORIES.includes(kind)) out.category = kind;
      return out;
    }
  } catch { /* no note: left out */ }
  return {};
}

/**
 * The sample: sessions whose log was written in the last two hours, newest
 * first, for the repository at root. logsDir is the runtime's log folder
 * (default ~/.claude/projects); worktrees may be given for tests.
 */
function readSessions({ root, logsDir, worktrees, localModels, now = Date.now() } = {}) {
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
      const s = readSession(text, f.replace(/\.jsonl$/, ''), { localModels });
      if (!s) continue;
      if (!s.worktree) s.worktree = { name: path.basename(tree), path: tree };
      const note = startedWith(root, s.worktree.name);
      if (note.how) s.startedWith = note.how;
      if (note.category) s.category = note.category;
      out.push({ ...s, _at: st.mtimeMs });
    }
  }
  return out.sort((a, b) => b._at - a._at).slice(0, SESSIONS_MAX).map(({ _at, ...s }) => s);
}

module.exports = { lastLine, readSession, readSessions, logFolder, modelId, isLocal, CATEGORIES, WORDS_MAX };

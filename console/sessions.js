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

/** Numbers matched by a pattern's first group, first few, in order, each once. */
function numbersBy(text, re) {
  const seen = [];
  for (const m of String(text || '').matchAll(re)) {
    const n = Number(m[1]);
    if (!seen.includes(n)) seen.push(n);
    if (seen.length >= 5) break;
  }
  return seen;
}

/**
 * The issues a first message gives its session. A task often names other
 * issues beside its own ("another pull request (#9) also touches it"), so the
 * issues its pull request is to close come first ("Closes #12"), then the
 * ones it calls its issue ("Task: issue #12", "Your issue: #12"), and only
 * when it says neither, every #N it names.
 */
function issuesIn(text) {
  const closes = numbersBy(text, /\b(?:closes|fixes|resolves|refs)\s+#(\d{1,6})\b/gi);
  if (closes.length) return closes;
  const own = numbersBy(text, /\bissue:?\s+#(\d{1,6})\b/gi);
  if (own.length) return own;
  return numbersBy(text, /#(\d{1,6})\b/g);
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
/**
 * The logs to read in one worktree's log folder: its sessions' own, and the
 * agents each session started. The runtime keeps an agent's log under the
 * session that started it, in <session>/subagents/agent-<id>.jsonl, with a
 * <id>.meta.json beside it naming the worktree and branch it was given.
 */
function logsIn(folder) {
  let entries;
  try { entries = fs.readdirSync(folder, { withFileTypes: true }); } catch { return []; }
  const out = [];
  for (const e of entries) {
    if (e.isFile() && e.name.endsWith('.jsonl')) out.push({ file: path.join(folder, e.name), name: e.name.replace(/\.jsonl$/, '') });
    if (!e.isDirectory()) continue;
    const sub = path.join(folder, e.name, 'subagents');
    let agents;
    try { agents = fs.readdirSync(sub).filter((f) => f.endsWith('.jsonl')); } catch { continue; }
    for (const f of agents) out.push({ file: path.join(sub, f), name: f.replace(/\.jsonl$/, ''), meta: path.join(sub, f.replace(/\.jsonl$/, '.meta.json')) });
  }
  return out;
}

/** An agent's meta file: the branch it was given, when the runtime wrote one. */
function agentBranch(metaFile) {
  if (!metaFile) return undefined;
  try {
    const m = JSON.parse(fs.readFileSync(metaFile, 'utf8'));
    return m && typeof m.worktreeBranch === 'string' && m.worktreeBranch ? m.worktreeBranch : undefined;
  } catch {
    return undefined;
  }
}

function readSessions({ root, logsDir, worktrees, localModels, now = Date.now() } = {}) {
  const dir = logsDir || path.join(os.homedir(), '.claude', 'projects');
  const trees = worktrees || worktreesOf(root);
  const out = [];
  const seen = new Set();
  for (const tree of trees) {
    const folder = path.join(dir, logFolder(tree));
    if (seen.has(folder)) continue;
    seen.add(folder);
    for (const log of logsIn(folder)) {
      let st;
      try { st = fs.statSync(log.file); } catch { continue; }
      if (now - st.mtimeMs > RECENT_MS) continue;
      let text;
      try { text = fs.readFileSync(log.file, 'utf8'); } catch { continue; }
      const s = readSession(text, log.name, { localModels });
      if (!s) continue;
      // An agent's log carries the branch its parent session was on; the branch it was given is in its meta file.
      const given = agentBranch(log.meta);
      if (given) s.branch = given;
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

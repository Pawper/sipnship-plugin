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
const touches = require('./session-touches');

const WORDS_MAX = 12;
const SESSIONS_MAX = 20;
const RECENT_MS = 2 * 60 * 60 * 1000;
const LOCAL_PREFIXES = ['ollama/', 'lmstudio/', 'local/'];
/** The runtime whose logs this file reads. */
const RUNTIME = 'Claude Code';
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
/** An effort level as the runtime records it ("low", "medium", "high"), lower case; anything else is no level. */
const effortLevel = (v) => (typeof v === 'string' && /^[a-z]{2,12}$/i.test(v.trim()) ? v.trim().toLowerCase() : undefined);

/** The message's first line, cleaned of markdown marks, as its words. */
function firstLineWords(text) {
  const first = String(text || '').split(/\r?\n/).map((l) => l.trim()).find((l) => l && !/^[`#>*-]+$/.test(l)) || '';
  return first.replace(/[`*_#>]/g, '').split(/\s+/).filter(Boolean);
}

/** The first line of a message, in at most twelve words. */
function lastLine(text) {
  const words = firstLineWords(text);
  if (!words.length) return '';
  return words.slice(0, WORDS_MAX).join(' ') + (words.length > WORDS_MAX ? '…' : '');
}

/** How long the full line is kept, in characters: a few sentences, never a transcript. */
const FULL_LINE_MAX_CHARS = 400;

/**
 * The same first line, in full, within the stored limit: kept beside the
 * short one only when the short one was actually cut, so a reader has
 * something to open with "Show all". Undefined when the line was not cut,
 * or there is nothing to keep.
 */
function fullLine(text) {
  const words = firstLineWords(text);
  if (words.length <= WORDS_MAX) return undefined;
  const joined = words.join(' ').slice(0, FULL_LINE_MAX_CHARS);
  return joined || undefined;
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

/** A sentence that tells the agent to keep away from a number: the numbers in it are not its work. */
const LEAVE_ALONE = /\b(?:leave\b[^.\n]{0,40}\balone|do(?:es)?\s*n[o']?t\s+(?:touch|work|change|edit)|don'?t\s+(?:touch|work\s+on)|not\s+yours|hands\s+off|out\s+of\s+scope|only\s+so\s+you)/i;

/** The text without the sentences and lines that name work to leave alone. */
function withoutLeaveAlone(text) {
  return String(text || '').split(/\r?\n/).flatMap((l) => l.split(/(?<=[.;!])\s+/)).filter((s) => !LEAVE_ALONE.test(s)).join('\n');
}

/**
 * The branch an agent pushed and the folder it pushed it from, from its last "git push" command: the folder
 * from "git -C PATH", when the command names one.
 */
function pushedIn(command) {
  let out;
  for (const part of String(command || '').split(/\n|&&|;/)) {
    const m = part.match(/\bgit\s+(?:-C\s+("[^"]+"|'[^']+'|\S+)\s+)?push\b([^|]*)/);
    if (!m) continue;
    const args = m[2].trim().split(/\s+/).filter((a) => a && !a.startsWith('-'));
    const ref = args.length > 1 ? args[args.length - 1] : '';
    const branch = ref.includes(':') ? ref.split(':').pop() : ref;
    if (!branch || branch === 'HEAD' || branch === 'main') continue;
    out = { branch, tree: m[1] ? m[1].replace(/^["']|["']$/g, '') : undefined };
  }
  return out;
}

/**
 * The issues a first message gives its session. A task often names other
 * issues beside its own ("another pull request (#9) also touches it"), so the
 * issues its pull request is to close come first ("Closes #12"), then the
 * ones it calls its issue ("Task: issue #12", "Your issue: #12"), and only
 * when it says neither, every #N it names.
 */
function issuesIn(rawText) {
  const text = withoutLeaveAlone(rawText);
  const closes = numbersBy(text, /\b(?:closes|fixes|resolves|refs)\s+#(\d{1,6})\b/gi);
  if (closes.length) return closes;
  const own = numbersBy(text, /\bissue:?\s+#(\d{1,6})\b/gi);
  if (own.length) return own;
  return numbersBy(text, /#(\d{1,6})\b/g);
}

/**
 * The issue a branch names: "issue-214-watering", "214-watering" or
 * "frost-alerts-208". A runtime's own branch ("worktree-agent-a5e249…") and
 * the queue's dated batch branches name none.
 */
function issuesInBranch(branch) {
  const b = String(branch || '');
  if (!b || /^batch-/.test(b) || /(?:^|\/)worktree-agent-/.test(b)) return [];
  const named = numbersBy(b, /issue[-_/]?(\d{1,6})\b/gi);
  if (named.length) return named;
  const m = b.match(/^(?:.*\/)?(\d{1,6})[-_]/) || b.match(/[-_/](\d{1,6})$/);
  return m ? [Number(m[1])] : [];
}

/** The issues the pull request body in a worktree closes (.scratch/body.md), none when there is no body yet. */
function issuesInBody(tree) {
  try {
    return numbersBy(fs.readFileSync(path.join(tree, '.scratch', 'body.md'), 'utf8'), /\b(?:closes|fixes|resolves)\s+#(\d{1,6})\b/gi);
  } catch {
    return [];
  }
}

/**
 * One session from its log's text (one JSON object per line): the start,
 * the model, the branch, the issues its first message names, the last thing
 * it said, and the tokens the runtime counted. Fields it lacks are absent.
 */
function readSession(logText, name, { localModels = [] } = {}) {
  let started; let model; let effort; let branch; let cwd; let title; let last = ''; let issues = []; let given;
  let tokens = 0; let counted = false; let tIn = 0; let tCached = 0; let tOut = 0;
  const seen = touches.tally();
  let pushed;
  for (const raw of String(logText).split('\n')) {
    if (!raw.trim()) continue;
    let e;
    try { e = JSON.parse(raw); } catch { continue; }
    if (!e || typeof e !== 'object') continue;
    if (!started && e.timestamp) started = e.timestamp;
    seen.add(e);
    if (e.gitBranch) branch = e.gitBranch;
    // The folder it started in is its worktree; a later cd into another folder does not move it.
    if (e.cwd && !cwd) cwd = e.cwd;
    // The title the person gave the session in the runtime, the latest one.
    if (e.type === 'custom-title' && typeof e.customTitle === 'string' && e.customTitle.trim()) title = e.customTitle.trim();
    const m = e.message;
    // What its very first message from the person names: the issues it was given, for its spans.
    if (e.type === 'user' && !given && m && touches.touchText(e).trim()) given = issuesIn(touches.touchText(e));
    if (e.type === 'user' && !issues.length && m) {
      const c = typeof m.content === 'string' ? m.content : (Array.isArray(m.content) ? m.content.map((p) => p && p.text).filter(Boolean).join(' ') : '');
      issues = issuesIn(c);
    }
    if (e.type === 'assistant' && m) {
      if (Array.isArray(m.content)) for (const p of m.content) if (p && p.type === 'tool_use' && p.input && typeof p.input.command === 'string') pushed = pushedIn(p.input.command) || pushed;
      if (m.model && m.model !== '<synthetic>') model = m.model;
      // The effort level the runtime ran this turn at, the latest one.
      const level = effortLevel(e.effort) || effortLevel(e.perTurnEffort);
      if (level) effort = level;
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
  const s = { session: name, runtime: RUNTIME, started: new Date(started).toISOString() };
  if (title) s.title = title.slice(0, 120);
  // An agent that never named its issues in its first message may still have named them in its branch or folder: issue-538.
  const named = [...String((branch || '') + ' ' + (cwd ? path.basename(cwd) : '')).matchAll(/issue[-_/]?(\d{1,6})\b/gi)].map((m) => Number(m[1])).filter((n, i, a) => a.indexOf(n) === i).slice(0, 5);
  if (!issues.length) issues = named;
  if (issues.length) s.issues = issues;
  if (branch) s.branch = branch;
  if (cwd) { s.worktree = { name: path.basename(cwd), path: cwd }; }
  if (model) s.model = modelId(model, localModels);
  if (effort) s.effort = effort;
  // Its last activity is its log's latest entry's own time, never the file's date.
  if (!Number.isNaN(seen.last)) s.lastActiveAt = new Date(seen.last).toISOString();
  // The numbers its entries touched and the ones it was given, for its spans; read by readSessions, never sent as they are.
  if (pushed) Object.defineProperty(s, 'pushed', { value: pushed, enumerable: false });
  Object.defineProperty(s, 'touches', { value: seen.touches, enumerable: false });
  Object.defineProperty(s, 'given', { value: given && given.length ? given : named, enumerable: false });
  // A local model costs nothing: the figure is stated, not left out.
  if (model && isLocal(s.model)) s.spend = 0;
  const line = lastLine(last);
  if (line) s.lastLine = line;
  const full = fullLine(last);
  if (full) s.fullLine = full;
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
    for (const f of agents) out.push({ file: path.join(sub, f), name: f.replace(/\.jsonl$/, ''), parent: e.name, meta: path.join(sub, f.replace(/\.jsonl$/, '.meta.json')) });
  }
  return out;
}

/**
 * An agent's meta file: the branch and worktree it was given, the task it was
 * started with and the effort level it was given, as far as the runtime wrote
 * them, and whether the runtime has marked it finished ("finished": true).
 */
function agentMeta(metaFile) {
  if (!metaFile) return {};
  const str = (v) => (typeof v === 'string' && v.trim() ? v.trim() : undefined);
  try {
    const m = JSON.parse(fs.readFileSync(metaFile, 'utf8')) || {};
    return { branch: str(m.worktreeBranch), worktree: str(m.worktreePath), task: str(m.description), effort: effortLevel(m.effort), finished: m.finished === true };
  } catch {
    return {};
  }
}

/**
 * Which issue a session works, in this order: what its pull request body
 * closes, then the number in its branch, then what its first message named.
 */
function identify(s, agent) {
  const body = s.worktree ? issuesInBody(s.worktree.path) : [];
  const branch = issuesInBranch(s.branch);
  const issues = body.length ? body : branch.length ? branch : s.issues || [];
  if (issues.length) s.issues = issues;
  // The issues it was given, for its spans, the same order; by a first message only for an agent, whose
  // first message is its task: a session the person opened and named issues in is touching them, not given them.
  return body.length ? body : branch.length ? branch : agent ? s.given || [] : [];
}

/**
 * The agents the stop hook saw end, by id, at the time it saw it: the
 * machine's brief-send/agents-ended.tsv, AGENT-ID<TAB>EPOCH SECONDS.
 */
function endedAgents(file) {
  const out = new Map();
  try {
    for (const row of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
      const [id, at] = row.split('\t');
      if (id && Number(at) > 0) out.set(id.trim(), Number(at) * 1000);
    }
  } catch { /* none ended yet */ }
  return out;
}

/** An agent ended when its stop was seen and its log has not moved on since (a resumed agent's has). */
const ENDED_SLACK_MS = 10 * 1000;

/**
 * The sample: sessions whose log's latest entry is from the last two hours,
 * newest first, for the repository at root. logsDir is the runtime's log
 * folder (default ~/.claude/projects); worktrees may be given for tests.
 */
function readSessions({ root, logsDir, worktrees, localModels, now = Date.now(), endedFile, signIn } = {}) {
  // How this machine's agent signed in, said once for every session of a hosted model: a plan, a key or not known.
  const billing = signIn || require('./billing').claudeSignIn();
  const dir = logsDir || path.join(os.homedir(), '.claude', 'projects');
  const trees = worktrees || worktreesOf(root);
  const ended = endedAgents(endedFile || path.join(require('./tokens').home(), 'brief-send', 'agents-ended.tsv'));
  const out = [];
  const seen = new Set();
  for (const tree of trees) {
    const folder = path.join(dir, logFolder(tree));
    if (seen.has(folder)) continue;
    seen.add(folder);
    for (const log of logsIn(folder)) {
      let st;
      // A file not written in two hours holds no newer entry: skipped unread.
      try { st = fs.statSync(log.file); } catch { continue; }
      if (now - st.mtimeMs > RECENT_MS) continue;
      let text;
      try { text = fs.readFileSync(log.file, 'utf8'); } catch { continue; }
      const s = readSession(text, log.name, { localModels });
      if (!s) continue;
      // The two hours are judged by its latest entry's own time: a log whose date was rewritten without a word stays out.
      const at = s.lastActiveAt ? Date.parse(s.lastActiveAt) : NaN;
      if (Number.isNaN(at) || now - at > RECENT_MS) continue;
      // An agent's log carries the branch its parent session was on; the branch and worktree it was given are in its meta file.
      // It counts as a session of its own, under the session that started it.
      const meta = agentMeta(log.meta);
      if (meta.branch) s.branch = meta.branch;
      if (meta.worktree) s.worktree = { name: path.basename(meta.worktree), path: meta.worktree };
      // An agent the runtime gave no worktree is on the branch it pushed, from the folder it pushed it in; never its parent's.
      if (log.parent && !meta.branch && s.pushed) {
        s.branch = s.pushed.branch;
        if (!meta.worktree && s.pushed.tree) s.worktree = { name: path.basename(s.pushed.tree), path: s.pushed.tree };
      }
      if (meta.task && !s.title) s.title = meta.task.slice(0, 120);
      if (meta.effort && !s.effort) s.effort = meta.effort;
      if (log.parent) s.parent = log.parent;
      // Its stop: the runtime's own mark that the agent finished, at its last entry; else the stop the hook saw, unless the log moved on since.
      const endedAt = log.parent ? ended.get(log.name.replace(/^agent-/, '')) : undefined;
      if (meta.finished) s.endedAt = s.lastActiveAt;
      else if (endedAt && at <= endedAt + ENDED_SLACK_MS) s.endedAt = new Date(endedAt).toISOString();
      if (!s.worktree) s.worktree = { name: path.basename(tree), path: tree };
      const given = identify(s, Boolean(log.parent));
      const spans = touches.spans(given, s.touches, Date.parse(s.started), at);
      if (spans.length) s.touched = spans;
      const note = startedWith(root, s.worktree.name);
      if (note.how) s.startedWith = note.how;
      if (note.category) s.category = note.category;
      if (!isLocal(s.model)) Object.assign(s, billing);
      out.push({ ...s, _at: at });
    }
  }
  return out.sort((a, b) => b._at - a._at).slice(0, SESSIONS_MAX).map(({ _at, ...s }) => s);
}

module.exports = { issuesIn, pushedIn, lastLine, fullLine, readSession, readSessions, issuesInBranch, issuesInBody, logFolder, logsIn, agentMeta, worktreesOf, endedAgents, modelId, isLocal, effortLevel, CATEGORIES, WORDS_MAX, SESSIONS_MAX, RECENT_MS, ENDED_SLACK_MS, FULL_LINE_MAX_CHARS };

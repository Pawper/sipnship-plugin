#!/usr/bin/env node
'use strict';
// The session brief's block, sent to SipNShip after the hook prints it.
//
//   printf '%s' "$brief" | node brief-send.js --session ID --repo OWNER/NAME
//
// One request, three seconds at most, only when this machine holds a token
// for the repository. Names and the brief's own sentences only: the last
// handoff (a file's contents) and the plugin's own path are never sent. The
// reply's status says a failure once per session; a reply with a body carries
// the builder's questions for the working agent (questions.js), and an
// agent's answer goes up with the next brief. Nothing the plugin does depends
// on the reply. Prints at most one line, and always exits 0.
//   node brief-send.js --repo OWNER/NAME --answer ID --say "..."   keeps an answer
//   node brief-send.js --repo OWNER/NAME --questions               lists what waits

const fs = require('fs');
const os = require('os');
const path = require('path');
const tokens = require('./tokens');
const sessions = require('./sessions');
const questions = require('./questions');

const SEND_MAX_BYTES = 64 * 1024;
const TIMEOUT_MS = 3000;
const LIST_MAX = 50;
const TEXT_MAX = 600;

function base(env = process.env) {
  return (env.SIPNSHIP_URL || 'https://sipnship.dev').replace(/\/+$/, '');
}

/** One bounded POST; the outcome by status alone: ok, not_connected, too_large, rate_limited or unreachable. */
async function post(url, token, body, timeoutMs = TIMEOUT_MS, onReply) {
  let res;
  try {
    res = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body,
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch {
    return 'unreachable';
  }
  // A reply with a body (200) may carry the builder's questions; anything else is not read.
  if (onReply && res.status === 200) { try { onReply(await res.json()); } catch { /* an unreadable reply says nothing */ } } else { try { await res.body?.cancel(); } catch { /* not read */ } }
  if (res.status >= 200 && res.status < 300) return 'ok';
  if (res.status === 401) return 'not_connected';
  if (res.status === 413) return 'too_large';
  if (res.status === 429) return 'rate_limited';
  return 'unreachable';
}

// Which card a line of the brief belongs to, by how the hook begins it.
// null: never sent. Lines after a heading that ends in ":" follow it.
const RULES = [
  [/^Session brief\./, null],
  [/^Plugin: \//, null],
  [/^Plugin: [A-Za-z]:/, null],
  [/^Today:/, null],
  [/^Waits on the owner/, 'waits'],
  [/^Queued:/, 'failed'],
  [/^Last handoff/, null],
  [/^Main:/, 'landed'],
  [/^The working tree /, 'landed'],
  [/^Open pull requests:/, 'progress'],
  [/^Where things stand/, 'progress'],
  [/^Status digest:/, 'progress'],
  [/^Issues/, 'progress'],
  [/^Proposed next/, 'waits'],
  [/^Permissions?/i, 'waits'],
  [/^Plugin: \d+ unreleased/, 'waits'],
  [/^Workflows:/, 'failed'],
  [/queued (for )?(over|more than)/i, 'failed'],
  [/^Deploy/, 'deployed'],
  [/^Budget:/, 'hour'],
  [/^Runner/, 'hour'],
  [/^Hosted Actions:/, 'hour'],
  [/^Queue:/, 'hour'],
  [/^Leftover|^Branches|^Worktree|^Of those|^Templates:|^Screens not|^Mocks behind/, 'stale'],
];

function classify(line) {
  for (const [re, key] of RULES) if (re.test(line)) return { key, matched: true };
  return { key: undefined, matched: false };
}

const clip = (s) => String(s).trim().slice(0, TEXT_MAX);

/**
 * The brief's printed block as the body the service reads: version, sentAt,
 * the machine's name, one card per kind of line with its sentences as the
 * brief said them, and the runner watch's latest sample when there is one.
 */
function briefBody(text, opts = {}) {
  const cards = new Map();
  let current;
  for (const raw of String(text).replace(/\r/g, '').split('\n')) {
    const line = raw.trim();
    if (!line) continue;
    const c = classify(line);
    if (c.matched) {
      current = c.key;
      if (!current) continue;
      const card = cards.get(current) || { key: current, lines: [] };
      cards.set(current, card);
      // A heading ("Main:", "Open pull requests:") names its card; the lines under it are its items.
      if (!/:$/.test(line)) card.lines.push(line);
      continue;
    }
    // A line under a heading: an item of the current card, or nothing when the heading is never sent.
    if (!current) continue;
    cards.get(current).lines.push(/^[0-9a-f]{7,40} /.test(line) ? line.replace(/^[0-9a-f]{7,40} /, '') : line);
  }
  const out = [];
  for (const card of cards.values()) {
    if (!card.lines.length) continue;
    const items = card.lines.slice(0, LIST_MAX).map((s) => ({ say: clip(s) }));
    out.push({ key: card.key, say: items[0].say, count: items.length, items });
  }
  const body = { version: 1, sentAt: (opts.now || new Date()).toISOString(), machine: opts.machine || os.hostname(), cards: out };
  if (opts.runners) body.runners = opts.runners;
  // The kinds of request this machine's listener carries out, only while the listener is on and running (spec 012).
  if (opts.can && opts.can.length) body.can = opts.can;
  if (opts.ownerSteps && opts.ownerSteps.length) body.ownerSteps = opts.ownerSteps;
  if (opts.localModels && opts.localModels.length) body.localModels = opts.localModels.map((m) => ({ model: m.model, tiers: m.tiers || [] }));
  if (opts.answers && opts.answers.length) body.answers = opts.answers;
  if (opts.sessions && opts.sessions.length) body.sessions = opts.sessions.map((s) => (s.lastLine ? { ...s, lastLine: sessions.lastLine(s.lastLine) } : s));
  return body;
}

/** The runner watch's machine file (epoch, cores, runners, busy, line) as the sample the brief carries. */
function runnerSample(row, timingsText) {
  const f = String(row || '').replace(/\r/g, '').split('\n')[0].split('\t');
  const n = (v) => (/^\d+$/.test(v || '') ? Number(v) : undefined);
  if (f.length < 4 || n(f[1]) === undefined || n(f[2]) === undefined) return undefined;
  const at = n(f[0]) ? new Date(n(f[0]) * 1000).toISOString() : undefined;
  const measures = measuresOf(f.slice(5));
  const timings = timingsOf(timingsText);
  return { cores: n(f[1]), runners: n(f[2]), busy: Math.min(n(f[3]) || 0, n(f[2])), ...(at ? { at } : {}), ...(measures ? { measures } : {}), ...(timings.length ? { timings } : {}) };
}

/**
 * The runner watch's timings file (job, start epoch, seconds, quiet seconds,
 * jobs beside it) as runners.timings. Names and counts only; a bad line is dropped.
 */
function timingsOf(text) {
  const out = [];
  for (const raw of String(text || '').replace(/\r/g, '').split('\n')) {
    const f = raw.split('\t');
    const n = (v) => (/^\d+$/.test(v || '') ? Number(v) : undefined);
    if (f.length < 5 || !f[0].trim() || !n(f[1]) || n(f[2]) === undefined || n(f[3]) === undefined || n(f[4]) === undefined) continue;
    out.push({ job: f[0].trim().slice(0, 120), at: new Date(n(f[1]) * 1000).toISOString(), seconds: n(f[2]), quietSeconds: n(f[3]), beside: n(f[4]) });
    if (out.length >= 20) break;
  }
  return out;
}

// The runner watch's measures, after the machine line, in this order: program
// start time (ms), uptime (hours), paged and non-paged pool (GB), handles,
// processes, the antivirus engine's share of one core (%), shells older than a day.
const MEASURES = ['startMs', 'uptimeHours', 'pagedGb', 'nonPagedGb', 'handles', 'processes', 'avShare', 'oldShells'];
function measuresOf(fields) {
  const out = {};
  MEASURES.forEach((name, i) => {
    const v = String(fields[i] === undefined ? '' : fields[i]).trim();
    if (/^\d+(\.\d+)?$/.test(v)) out[name] = Number(v);
  });
  return Object.keys(out).length ? out : undefined;
}

/**
 * The owner's steps from the project's manual: the marked lines under the
 * "Steps for the owner" heading of SETUP.md, as written. The service reads
 * them into cards; nothing else of the manual is sent.
 */
function ownerSteps(root) {
  let text;
  try { text = fs.readFileSync(path.join(root, 'SETUP.md'), 'utf8'); } catch { return []; }
  const out = [];
  let inside = false;
  for (const raw of text.replace(/\r/g, '').split('\n')) {
    if (/^#{1,6}\s/.test(raw)) { inside = /^##\s+Steps for the owner\s*$/i.test(raw.trim()); continue; }
    if (inside && /^\s*[-*]\s+\[[ xX]\]\s+\S/.test(raw)) out.push(raw.trim().slice(0, 600));
  }
  return out.slice(0, 20);
}

/** The body as text, trimmed item by item until it fits under the limit; undefined when it never does. */
function fit(body) {
  let text = JSON.stringify(body);
  const b = structuredClone(body);
  while (Buffer.byteLength(text) > SEND_MAX_BYTES) {
    const biggest = b.cards.reduce((m, c) => (!m || c.items.length > m.items.length ? c : m), undefined);
    if (!biggest || biggest.items.length <= 1) return undefined;
    biggest.items = biggest.items.slice(0, Math.floor(biggest.items.length / 2));
    text = JSON.stringify(b);
  }
  return text;
}

function clock(ms) {
  return new Date(ms).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
}

/** The one plain line a failed send says, or nothing. */
function failureLine(outcome, lastOk) {
  const since = lastOk ? `the brief from ${clock(lastOk)}` : 'an earlier brief, or none yet';
  if (outcome === 'not_connected') return 'This machine is no longer connected to SipNShip. Reconnect it from the dashboard if you want the brief there.';
  if (outcome === 'unreachable') return `Could not reach SipNShip, so the dashboard shows ${since}. Your session carries on.`;
  if (outcome === 'too_large') return `The brief was too long to send to SipNShip, so the dashboard shows ${since}. Your session carries on.`;
  return '';
}

/** What this session has already said, kept beside the token file. */
function memoryFile(env, repoId) {
  return path.join(tokens.home(env), 'brief-send', `${repoId}.tsv`);
}
function recall(env, repoId) {
  try {
    const [session, said, lastOk] = fs.readFileSync(memoryFile(env, repoId), 'utf8').trim().split('\t');
    return { session, said, lastOk: Number(lastOk) || 0 };
  } catch {
    return { session: '', said: '', lastOk: 0 };
  }
}
function remember(env, repoId, m) {
  try {
    fs.mkdirSync(path.dirname(memoryFile(env, repoId)), { recursive: true });
    fs.writeFileSync(memoryFile(env, repoId), `${m.session}\t${m.said}\t${m.lastOk || 0}\n`);
  } catch { /* never stops the session */ }
}

/** Send the brief; returns the line to print ('' for none). */
async function sendBrief({ text, session = '', repo, env = process.env, now = new Date(), runners, sessions: agents, ownerSteps: steps, localModels }) {
  const entry = tokens.find(repo, env);
  if (!entry || !tokens.looksLikeToken(entry.token)) return '';
  const mem = recall(env, entry.repoId);
  const same = mem.session && mem.session === session;
  // Refused once this session: nothing more is sent until the next one.
  if (same && mem.said === 'not_connected') return '';
  const answers = questions.pendingAnswers(env, entry.repoId);
  const can = require('./listen').briefCan(env, now.getTime());
  const body = fit(briefBody(text, { now, machine: entry.machine, runners, sessions: agents, ownerSteps: steps, localModels, answers, can }));
  let reply;
  const outcome = body === undefined ? 'too_large' : await post(`${base(env)}/v1/repos/${entry.repoId}/brief`, entry.token, body, TIMEOUT_MS, (r) => { reply = r; });
  if (outcome === 'ok') {
    remember(env, entry.repoId, { session, said: same ? mem.said : '', lastOk: now.getTime() });
    questions.clearAnswers(env, entry.repoId, answers);
    questions.receive(env, entry.repoId, reply && reply.questions, agents, now.getTime());
    return questions.lineFor(env, entry.repoId, session, repo, __filename);
  }
  if (outcome === 'rate_limited') return '';
  if (same && mem.said) return '';
  remember(env, entry.repoId, { session, said: outcome, lastOk: mem.lastOk });
  return failureLine(outcome, mem.lastOk);
}

async function main() {
  const argv = process.argv.slice(2);
  const arg = (name) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; };
  const env = process.env;
  const entry = arg('--repo') ? tokens.find(arg('--repo'), env) : undefined;
  // The agent's side of a question: its answer waits for the next brief; or the list of what waits for this session.
  if (argv.includes('--answer') || argv.includes('--questions')) {
    if (!entry) { process.stdout.write('No SipNShip connection is set up for this repository on this machine.\n'); return; }
    if (argv.includes('--questions')) { for (const l of questions.listFor(env, entry.repoId, arg('--session') || '', arg('--repo'), __filename)) process.stdout.write(l + '\n'); return; }
    process.stdout.write(questions.answer(env, entry.repoId, arg('--answer'), arg('--say')) ? 'Kept. It goes to the dashboard with the next brief.\n' : 'No question with that id is waiting, or the answer was empty.\n');
    return;
  }
  const text = fs.readFileSync(0, 'utf8');
  let runners;
  const machineFile = arg('--machine-file');
  if (machineFile) {
    let timingsText = '';
    try { timingsText = fs.readFileSync(path.join(path.dirname(machineFile), 'timings.tsv'), 'utf8'); } catch { /* no timings yet */ }
    try { runners = runnerSample(fs.readFileSync(machineFile, 'utf8'), timingsText); } catch { /* no sample */ }
  }
  let agents;
  let local = [];
  try { local = require('./config').localModels(require('./config').loadConfig(process.cwd())); } catch { /* no services file */ }
  try { agents = sessions.readSessions({ root: process.cwd(), localModels: local.map((m) => m.model) }); } catch { /* no sample */ }
  const line = await sendBrief({ text, session: arg('--session') || '', repo: arg('--repo'), runners, sessions: agents, ownerSteps: ownerSteps(process.cwd()), localModels: local });
  if (line) process.stdout.write(line + '\n');
}

if (require.main === module) main().catch(() => {}).finally(() => { process.exitCode = 0; });

module.exports = { post, briefBody, runnerSample, timingsOf,ownerSteps, measuresOf, fit, failureLine, sendBrief, base, SEND_MAX_BYTES, TIMEOUT_MS };

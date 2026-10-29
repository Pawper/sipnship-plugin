#!/usr/bin/env node
'use strict';
// The session brief's block, sent to SipNShip after the hook prints it.
//
//   printf '%s' "$brief" | node brief-send.js --session ID --repo OWNER/NAME
//
// One request, three seconds at most, only when this machine holds a token
// for the repository. Names and the brief's own sentences only: the last
// handoff (a file's contents) and the plugin's own path are never sent. The
// reply's status is the only thing read, and only to say a failure once per
// session; nothing the plugin does depends on it. Prints at most one line,
// and always exits 0.

const fs = require('fs');
const os = require('os');
const path = require('path');
const tokens = require('./tokens');

const SEND_MAX_BYTES = 64 * 1024;
const TIMEOUT_MS = 3000;
const LIST_MAX = 50;
const TEXT_MAX = 600;

function base(env = process.env) {
  return (env.SIPNSHIP_URL || 'https://sipnship.dev').replace(/\/+$/, '');
}

/** One bounded POST; the outcome by status alone: ok, not_connected, too_large, rate_limited or unreachable. */
async function post(url, token, body, timeoutMs = TIMEOUT_MS) {
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
  try { await res.body?.cancel(); } catch { /* the reply is never read */ }
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
  return body;
}

/** The runner watch's machine file (epoch, cores, runners, busy, line) as the sample the brief carries. */
function runnerSample(row) {
  const f = String(row || '').replace(/\r/g, '').split('\n')[0].split('\t');
  const n = (v) => (/^\d+$/.test(v || '') ? Number(v) : undefined);
  if (f.length < 4 || n(f[1]) === undefined || n(f[2]) === undefined) return undefined;
  const at = n(f[0]) ? new Date(n(f[0]) * 1000).toISOString() : undefined;
  return { cores: n(f[1]), runners: n(f[2]), busy: Math.min(n(f[3]) || 0, n(f[2])), ...(at ? { at } : {}) };
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
async function sendBrief({ text, session = '', repo, env = process.env, now = new Date(), runners }) {
  const entry = tokens.find(repo, env);
  if (!entry || !tokens.looksLikeToken(entry.token)) return '';
  const mem = recall(env, entry.repoId);
  const same = mem.session && mem.session === session;
  // Refused once this session: nothing more is sent until the next one.
  if (same && mem.said === 'not_connected') return '';
  const body = fit(briefBody(text, { now, machine: entry.machine, runners }));
  const outcome = body === undefined ? 'too_large' : await post(`${base(env)}/v1/repos/${entry.repoId}/brief`, entry.token, body);
  if (outcome === 'ok') {
    remember(env, entry.repoId, { session, said: same ? mem.said : '', lastOk: now.getTime() });
    return '';
  }
  if (outcome === 'rate_limited') return '';
  if (same && mem.said) return '';
  remember(env, entry.repoId, { session, said: outcome, lastOk: mem.lastOk });
  return failureLine(outcome, mem.lastOk);
}

async function main() {
  const argv = process.argv.slice(2);
  const arg = (name) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; };
  const text = fs.readFileSync(0, 'utf8');
  let runners;
  const machineFile = arg('--machine-file');
  if (machineFile) { try { runners = runnerSample(fs.readFileSync(machineFile, 'utf8')); } catch { /* no sample */ } }
  const line = await sendBrief({ text, session: arg('--session') || '', repo: arg('--repo'), runners });
  if (line) process.stdout.write(line + '\n');
}

if (require.main === module) main().catch(() => {}).finally(() => { process.exitCode = 0; });

module.exports = { post, briefBody, runnerSample, fit, failureLine, sendBrief, base, SEND_MAX_BYTES, TIMEOUT_MS };

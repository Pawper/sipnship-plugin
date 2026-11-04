#!/usr/bin/env node
'use strict';
// What agents did after a rule stopped them, told to SipNShip once a refusal
// has settled (the hook log and the resolution watch write both logs on this
// machine; see hooks/scripts/refusal-log.sh and watch-resolution.sh).
//
//   node refusal-report.js --repo OWNER/NAME --session ID
//
// A report is names from fixed lists, times and counts, and nothing else: the
// rule's hook name, when it refused, what came next, seconds and tool calls
// taken, the kind of tool behind a possible workaround, the issue numbers
// the session was working on, and a key that groups one session's refusals
// (a hash of the runtime's session id and the repository's id, which cannot
// be turned back). The logs never held a command, so the body has nowhere to
// put one. The cursor .scratch/hooks/sent holds the last report the service
// acknowledged: a failed send leaves it, and the next turn's end or the next
// brief carries the reports again. No retry, no timer. One request, three
// seconds at most, only when this machine holds a token for the repository
// and HOOK_LOG is not 0. Prints at most one plain line, and always exits 0.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const tokens = require('./tokens');

const OUTCOMES = ['followed', 'asked', 'retried', 'moved on', 'stopped', 'workaround', 'off'];
const VIAS = ['shell', 'file edit', 'agent', 'other'];
const MAX_REPORTS = 200;
const KEEP_MS = 30 * 24 * 60 * 60 * 1000;
const TIMEOUT_MS = 3000;
const ID = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ-\d{1,10}$/;
const HOOK = /^[a-z][a-z0-9-]{1,48}$/;
const STAMP = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;

const dir = (root) => path.join(root, '.scratch', 'hooks');
const read = (file) => { try { return fs.readFileSync(file, 'utf8').replace(/\r/g, ''); } catch { return ''; } };
const int = (v, max) => (/^\d+$/.test(v || '') && Number(v) <= max ? Number(v) : undefined);

/** The key that groups one session's refusals without being its id. */
function sessionKey(sessionId, repoId) {
  return crypto.createHash('sha256').update(`${sessionId}:${repoId}`).digest('hex').slice(0, 16);
}

/**
 * The reports the two logs hold, in the order they settled. hooksText is
 * "time hook session id" a line, resolvedText "time id hook session outcome
 * after calls via". Only what both logs agree on is reported; a line that is
 * not in its list is left out, not repaired.
 */
function reportsFrom(hooksText, resolvedText, { repoId, now = Date.now(), issuesBySession = {} } = {}) {
  const began = new Map();
  for (const raw of String(hooksText).replace(/\r/g, '').split('\n')) {
    const f = raw.split('\t');
    if (f.length >= 4 && ID.test(f[3])) began.set(f[3], { at: f[0], hook: f[1] });
  }
  const out = [];
  for (const raw of String(resolvedText).replace(/\r/g, '').split('\n')) {
    const f = raw.split('\t');
    if (f.length < 5) continue;
    const [, id, hook, sess, outcome] = f;
    const start = began.get(id);
    if (!start || !ID.test(id) || !HOOK.test(hook) || !STAMP.test(start.at) || !OUTCOMES.includes(outcome)) continue;
    if (now - Date.parse(start.at) > KEEP_MS || Number.isNaN(Date.parse(start.at))) continue;
    const r = { id, rule: hook, at: start.at, outcome, after: int(f[5], 7 * 24 * 3600) ?? Math.max(0, Math.round((Date.parse(f[0]) - Date.parse(start.at)) / 1000) || 0), calls: Math.min(int(f[6], 99) ?? 0, 5) };
    if (outcome === 'workaround' && VIAS.includes(f[7])) r.via = f[7];
    const issues = (issuesBySession[sess] || []).filter((n) => Number.isInteger(n) && n > 0 && n <= 9999999).slice(0, 20);
    if (issues.length) r.issues = issues;
    r.session = sessionKey(sess, repoId);
    out.push(r);
  }
  return out;
}

/**
 * The reports for what a rule let through while it was off: hooks-off.log
 * lines are "time hook rule session id". The outcome is `off`, with no
 * seconds, calls or kind of tool; the command was never in the log.
 */
function offReportsFrom(offText, { repoId, now = Date.now() } = {}) {
  const out = [];
  for (const raw of String(offText).replace(/\r/g, '').split('\n')) {
    const f = raw.split('\t');
    if (f.length < 5) continue;
    const [at, hook, , sess, id] = f;
    if (!ID.test(id) || !HOOK.test(hook) || !STAMP.test(at) || Number.isNaN(Date.parse(at)) || now - Date.parse(at) > KEEP_MS) continue;
    out.push({ id, rule: hook, at, outcome: 'off', after: 0, calls: 0, session: sessionKey(sess, repoId) });
  }
  return out;
}

/** The last report the service acknowledged, or ''. Off reports keep their own cursor, in sent-off. */
const cursor = (root, file = 'sent') => read(path.join(dir(root), file)).trim();
function moveCursor(root, id, file = 'sent') {
  try {
    fs.mkdirSync(dir(root), { recursive: true });
    fs.writeFileSync(path.join(dir(root), file), `${id}\n`);
  } catch { /* the next send carries them again */ }
}
/** Moves each cursor to the last report of its kind among those sent. */
function moveCursors(root, sent) {
  const last = (want) => { const l = sent.filter((r) => (r.outcome === 'off') === want); return l.length ? l[l.length - 1].id : ''; };
  if (last(false)) moveCursor(root, last(false));
  if (last(true)) moveCursor(root, last(true), 'sent-off');
}

/** The issue numbers each session was on, from the session sample; none when it cannot be read. */
function issuesOf(root, wanted) {
  try {
    const out = {};
    for (const s of require('./sessions').readSessions({ root }) || []) if (wanted.has(s.session) && s.issues) out[s.session] = s.issues;
    return out;
  } catch { return {}; }
}

/** What waits to be sent: after the cursor, oldest first, at most 200, none older than 30 days. */
function pending(root, repoId, now = Date.now()) {
  const hooks = read(path.join(root, '.scratch', 'hooks.log'));
  const resolved = read(path.join(root, '.scratch', 'hooks-resolved.log'));
  const offAll = offReportsFrom(read(path.join(root, '.scratch', 'hooks-off.log')), { repoId, now });
  const offWaiting = offAll.slice(offAll.findIndex((r) => r.id === cursor(root, 'sent-off')) + 1);
  let settled = [];
  if (resolved.trim()) {
    const all = reportsFrom(hooks, resolved, { repoId, now });
    const from = all.findIndex((r) => r.id === cursor(root)) + 1;
    if (from < all.length) {
      // The sample is read only when something waits, and only for the sessions that have something.
      const issues = issuesOf(root, new Set(resolved.split('\n').map((l) => l.split('\t')[3])));
      settled = reportsFrom(hooks, resolved, { repoId, now, issuesBySession: issues }).slice(from);
    }
  }
  return [...settled, ...offWaiting].slice(0, MAX_REPORTS);
}

const enabled = (env) => (env.HOOK_LOG ?? '1') !== '0';

/** One bounded POST; the status, or 0 when nothing answered. */
async function post(url, token, body, timeoutMs = TIMEOUT_MS) {
  try {
    const res = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` }, body, signal: AbortSignal.timeout(timeoutMs) });
    let json;
    if (res.status === 200) { try { json = await res.json(); } catch { /* unreadable: not acknowledged */ } } else { try { await res.body?.cancel(); } catch { /* not read */ } }
    return { status: res.status, json };
  } catch {
    return { status: 0 };
  }
}

const base = (env) => (env.SIPNSHIP_URL || 'https://sipnship.dev').replace(/\/+$/, '');
const LINES = {
  bad: "SipNShip could not read this machine's rule reports. Updating the plugin fixes it.",
  unreachable: 'Could not reach SipNShip to tell it what your agents did after a rule stopped them. The next turn will try again.',
};

/** A failure said once per session: the memory is the session's key. */
function sayOnce(root, key, line) {
  const f = path.join(dir(root), 'said');
  if (read(f).trim() === key) return '';
  try { fs.mkdirSync(dir(root), { recursive: true }); fs.writeFileSync(f, `${key}\n`); } catch { /* said again next time */ }
  return line;
}

/**
 * Sends what waits, at a turn's end. Returns the line to print ('' for none).
 * A good answer moves the cursor; so does a refusal of the reports as unreadable
 * (they are never resent); any other failure leaves it where it was.
 */
async function sendNow({ root, repo, session = '', env = process.env, now = Date.now() }) {
  if (!enabled(env)) return '';
  const entry = tokens.find(repo, env);
  if (!entry || !tokens.looksLikeToken(entry.token)) return '';
  const reports = pending(root, entry.repoId, now);
  if (!reports.length) return '';
  const last = reports[reports.length - 1].id;
  const { status, json } = await post(`${base(env)}/v1/repos/${entry.repoId}/refusals`, entry.token, JSON.stringify({ reports }));
  if (status === 200 && json && Array.isArray(json.ids) && json.ids.includes(last)) { moveCursors(root, reports); return noticeOnce(env, entry.repoId); }
  if (status === 400) { moveCursors(root, reports); return sayOnce(root, sessionKey(session, entry.repoId), LINES.bad); }
  if (status === 401 || status === 429) return '';
  return sayOnce(root, sessionKey(session, entry.repoId), LINES.unreachable);
}

/**
 * The brief's ride-along: puts what waits on the brief's body as `refusals`,
 * fewer when the whole would pass the size limit; returns the reports put on.
 */
function attach(body, { root, repoId, env = process.env, now = Date.now(), maxBytes }) {
  if (!enabled(env)) return [];
  let reports = pending(root, repoId, now);
  const room = maxBytes - Buffer.byteLength(JSON.stringify(body)) - 32;
  while (reports.length && Buffer.byteLength(JSON.stringify(reports)) > room) reports = reports.slice(0, Math.floor(reports.length / 2));
  if (reports.length) body.refusals = reports;
  return reports;
}

/** The brief's reply: ids the service holds, or the list refused as unreadable, move the cursor. */
function acknowledge(root, sent, reply) {
  if (!sent.length || !reply) return;
  const last = sent[sent.length - 1].id;
  if (reply.rejected === true || (Array.isArray(reply.refusals) && reply.refusals.includes(last))) moveCursors(root, sent);
}

/** Said once on a machine connected before reports shipped. */
function noticeOnce(env, repoId) {
  const f = path.join(tokens.home(env), 'brief-send', `${repoId}.refusals-told`);
  if (fs.existsSync(f)) return '';
  try { fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, 'told\n'); } catch { return ''; }
  return 'This machine now also tells SipNShip what agents did after a rule stopped them. Never the command. Turn it off in Settings.';
}

async function main() {
  const argv = process.argv.slice(2);
  const arg = (name) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; };
  const line = await sendNow({ root: process.cwd(), repo: arg('--repo'), session: arg('--session') || '' });
  if (line) process.stdout.write(line + '\n');
}

if (require.main === module) main().catch(() => {}).finally(() => { process.exitCode = 0; });

module.exports = { sessionKey, reportsFrom, offReportsFrom, pending, cursor, sendNow, attach, acknowledge, noticeOnce, OUTCOMES, VIAS, MAX_REPORTS, LINES };

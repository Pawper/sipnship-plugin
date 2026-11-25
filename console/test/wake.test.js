'use strict';
// A press wakes the drive on the builder's machine (specs/030-plugin-wake), on Maya's rooftop-garden app.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const tokens = require('../tokens');
const wake = require('../wake');
const listen = require('../listen');
const { ticker, runTick, verdictOf, takeLock, PROMPT } = require('../wake-tick');

const scratch = path.resolve(__dirname, '..', '..', '..', '.scratch');
const home = () => { fs.mkdirSync(scratch, { recursive: true }); return fs.mkdtempSync(path.join(scratch, 'sns-wake-')); };
const sink = () => { const o = { text: '', write: (s) => { o.text += s; } }; return o; };
const TOKEN = 'sns_repo_' + 'a'.repeat(43);
const REPO = 5150;
const WAKE = JSON.stringify({ wake: 'request-waiting', repo: REPO });

function connected() {
  const env = { SIPNSHIP_HOME: home(), SIPNSHIP_URL: 'https://sipnship.test' };
  tokens.put({ repoId: REPO, fullName: 'maya/rooftop-garden', token: TOKEN, machine: "Maya's laptop", connectedAt: '2026-11-04T18:00:00Z' }, env);
  return env;
}

/** A stand-in socket: the test opens, speaks and closes it; what the plugin sent is kept. */
function sockets() {
  const made = [];
  class Socket {
    constructor(url, opts) { this.url = url; this.opts = opts; this.sent = []; made.push(this); }
    send(t) { this.sent.push(JSON.parse(t)); }
    close() { this.closed = true; }
  }
  return { Socket, made };
}

/** Timers the test turns by hand. */
function timers() {
  const t = { intervals: [], timeouts: [] };
  t.setInterval = (fn) => { t.intervals.push(fn); return t.intervals.length; };
  t.clearInterval = (id) => { t.intervals[id - 1] = null; };
  t.setTimeout = (fn) => { t.timeouts.push(fn); return t.timeouts.length; };
  t.clearTimeout = (id) => { t.timeouts[id - 1] = null; };
  t.beat = async () => { for (const f of t.intervals) if (f) await f(); };
  t.later = () => { const fns = t.timeouts.splice(0); for (const f of fns) if (f) f(); };
  return t;
}

const settle = () => new Promise((r) => setImmediate(r));

test('only the one message, for its own repository, is a wake', () => {
  assert.strictEqual(wake.readWake(WAKE, REPO), true);
  assert.strictEqual(wake.readWake(JSON.stringify({ wake: 'request-waiting', repo: 4242 }), REPO), false);
  assert.strictEqual(wake.readWake(JSON.stringify({ wake: 'request-waiting', repo: REPO, run: 'gh pr merge 12' }), REPO), false);
  assert.strictEqual(wake.readWake(JSON.stringify({ wake: 'start', repo: REPO }), REPO), false);
  assert.strictEqual(wake.readWake('request-waiting', REPO), false);
  assert.strictEqual(wake.readWake(JSON.stringify([WAKE]), REPO), false);
});

test('a wake runs one look; wakes while it runs collapse to exactly one more after it', async () => {
  const facts = [];
  let release;
  let runs = 0;
  const t = ticker({ tick: () => { runs++; return new Promise((r) => { release = () => r({ outcome: 'started', model: true }); }); }, report: (f) => facts.push(Object.keys(f)[0]) });
  const first = t.wake();
  assert.strictEqual(runs, 1);
  t.wake(); t.wake(); t.wake();
  assert.strictEqual(runs, 1);
  release();
  await settle();
  assert.strictEqual(runs, 2);
  release();
  await first;
  assert.strictEqual(runs, 2);
  assert.deepStrictEqual(facts, ['taken', 'pending', 'done', 'taken', 'done']);
});

test('a look with nothing approved ends with no model call', async () => {
  const calls = [];
  const run = async (cmd, args) => { calls.push(cmd); return { status: 0, stdout: cmd === 'sh' ? 'published: the round\nnothing: the latest proposal on issue 90 has no reply yet\n' : '' }; };
  const r = await runTick({ root: home(), plugin: '/plugin', run });
  assert.deepStrictEqual(calls, ['sh']);
  assert.strictEqual(r.model, false);
  assert.match(r.outcome, /no reply yet/);
});

test('an approved round starts one headless look of the drive, with this machine\'s own sign-in', async () => {
  const calls = [];
  const run = async (cmd, args, o) => { calls.push([cmd, args, o.cwd]); return { status: 0, stdout: cmd === 'sh' ? 'start: 2 goals\n' : '' }; };
  const root = home();
  const r = await runTick({ root, plugin: '/plugin', run });
  assert.deepStrictEqual(calls.map((c) => c[0]), ['sh', 'claude']);
  assert.deepStrictEqual(calls[1][1], ['-p', PROMPT]);
  assert.strictEqual(calls[1][2], root);
  assert.strictEqual(r.model, true);
});

test('a wake the timed drive already handled is a no-op: the round is started, and no model runs', async () => {
  const calls = [];
  const run = async (cmd) => { calls.push(cmd); return { status: 0, stdout: 'nothing: the round is already started\n' }; };
  const r = await runTick({ root: home(), plugin: '/plugin', run });
  assert.deepStrictEqual(calls, ['sh']);
  assert.strictEqual(r.model, false);
});

test("with the project's own runner wake already on it, the look leaves it to that run", async () => {
  const root = home();
  fs.mkdirSync(path.join(root, '.github', 'workflows'), { recursive: true });
  fs.writeFileSync(path.join(root, '.github', 'workflows', 'drive-wake.yml'), 'name: Drive wake\n');
  const calls = [];
  const run = async (cmd, args) => { calls.push(cmd); return { status: 0, stdout: cmd === 'gh' ? '1\n' : 'start: 1 goal\n' }; };
  const r = await runTick({ root, plugin: '/plugin', run });
  assert.deepStrictEqual(calls, ['gh']);
  assert.strictEqual(r.model, false);
  assert.match(r.outcome, /own wake/);
});

test('the lock keeps a second process out while a live look holds it, and takes over a stale one', () => {
  const lock = path.join(home(), '.scratch', 'drive', 'wake.lock');
  const now = Date.parse('2026-11-05T06:24:00Z');
  fs.mkdirSync(path.dirname(lock), { recursive: true });
  fs.writeFileSync(lock, JSON.stringify({ pid: 999999, at: new Date(now - 60000).toISOString() }));
  assert.strictEqual(takeLock(lock, now, () => true), false);
  assert.strictEqual(takeLock(lock, now, () => false), true);
});

test('the connection hears a wake for its repository, ignores one for another, and reports what it does', async () => {
  const env = connected();
  const { Socket, made } = sockets();
  const t = timers();
  let looks = 0;
  const root = home();
  const conn = wake.run({ env, repoId: REPO, root, Socket, timers: t, alive: () => true, tick: async () => { looks++; return { outcome: 'started', model: true }; } });
  const ws = made[0];
  assert.strictEqual(ws.url, `wss://sipnship.test/v1/repos/${REPO}/wake`);
  assert.strictEqual(ws.opts.headers.authorization, `Bearer ${TOKEN}`);
  ws.onopen();
  ws.onmessage({ data: JSON.stringify({ wake: 'request-waiting', repo: 4242 }) });
  await settle();
  assert.strictEqual(looks, 0);
  ws.onmessage({ data: WAKE });
  await settle();
  assert.strictEqual(looks, 1);
  assert.deepStrictEqual(ws.sent, [{ beat: true }, { taken: true }, { done: true }]);
  await t.beat();
  assert.deepStrictEqual(ws.sent.at(-1), { beat: true });
  conn.stop();
  assert.strictEqual(await conn, 'stopped');
});

test('a refused token closes the connection, and the next session start says so once', async () => {
  const env = connected();
  const { Socket, made } = sockets();
  const t = timers();
  const conn = wake.run({ env, repoId: REPO, root: home(), Socket, timers: t, alive: () => true, fetchFn: async () => ({ status: 401 }), tick: async () => ({}) });
  await made[0].onclose();
  assert.strictEqual(await conn, 'refused');
  assert.strictEqual(made.length, 1);
  const repoOf = () => 'maya/rooftop-garden';
  const launched = [];
  const first = sink();
  assert.strictEqual(wake.start({ env, out: first, repoOf, rootOf: (d) => d, launch: (x) => launched.push(x), Socket }), 'refused');
  assert.strictEqual(first.text, `${wake.NOT_CONNECTED}\n`);
  const second = sink();
  wake.start({ env, out: second, repoOf, rootOf: (d) => d, launch: (x) => launched.push(x), Socket });
  assert.strictEqual(second.text, '');
  assert.deepStrictEqual(launched, []);
  // Connected again on the dashboard: a new token, so it listens again.
  tokens.put({ repoId: REPO, fullName: 'maya/rooftop-garden', token: TOKEN, machine: "Maya's laptop", connectedAt: '2026-11-05T07:00:00Z' }, env);
  assert.strictEqual(wake.start({ env, out: sink(), repoOf, rootOf: (d) => d, launch: (x) => launched.push(x), Socket }), 'started');
});

test('starts the connection once per repository, and not without a token or a session', () => {
  const env = connected();
  const repoOf = () => 'maya/rooftop-garden';
  const launched = [];
  const { Socket } = sockets();
  assert.strictEqual(wake.start({ env, out: sink(), repoOf, rootOf: (d) => d, launch: (x) => launched.push(x), Socket }), 'started');
  assert.deepStrictEqual(launched.map((x) => x.repoId), [REPO]);
  assert.strictEqual(wake.sessionsAlive(env), true);
  fs.writeFileSync(path.join(env.SIPNSHIP_HOME, 'wake', `${REPO}.pid`), String(process.pid));
  assert.strictEqual(wake.start({ env, out: sink(), repoOf, rootOf: (d) => d, launch: (x) => launched.push(x), Socket }), 'running');
  assert.strictEqual(wake.start({ env: { SIPNSHIP_HOME: home() }, out: sink(), repoOf, launch: (x) => launched.push(x), Socket }), 'none');
  assert.strictEqual(wake.start({ env, out: sink(), repoOf: () => 'maya/another-app', launch: (x) => launched.push(x), Socket }), 'none');
  assert.strictEqual(launched.length, 1);
});

test('nothing connected: no heartbeat goes while the connection is down, and it ends once no session is seen', async () => {
  const env = connected();
  const { Socket, made } = sockets();
  const t = timers();
  let alive = true;
  const conn = wake.run({ env, repoId: REPO, root: home(), Socket, timers: t, alive: () => alive, fetchFn: async () => { throw new Error('offline'); }, tick: async () => ({}) });
  await made[0].onclose();
  await t.beat();
  assert.deepStrictEqual(made[0].sent, []);
  // It tries again, with a growing wait.
  t.later();
  assert.strictEqual(made.length, 2);
  alive = false;
  await t.beat();
  assert.strictEqual(await conn, 'no session');
  assert.deepStrictEqual(made[1].sent, []);
  assert.strictEqual(fs.existsSync(path.join(env.SIPNSHIP_HOME, 'wake', `${REPO}.pid`)), false);
});

test('waits a growing time between tries, at most a minute', () => {
  assert.deepStrictEqual([0, 1, 2, 5, 6, 10].map(wake.retryMs), [1000, 2000, 4000, 32000, 60000, 60000]);
});

test("reads wake-check's verdict from its last line", () => {
  assert.deepStrictEqual(verdictOf('published: x\nstart: 1 request\n'), { start: true, why: '1 request' });
  assert.deepStrictEqual(verdictOf(''), { start: false, why: 'the check said nothing' });
});

// The listener holds the connection for every project the machine is connected to, with no session open anywhere (#2791).
function twoProjects() {
  const env = connected();
  tokens.put({ repoId: 6161, fullName: 'maya/market-stall', token: 'sns_repo_' + 'b'.repeat(43), machine: "Maya's laptop", connectedAt: '2026-11-24T19:10:00Z' }, env);
  const roots = { [String(REPO)]: home(), '6161': home() };
  listen.writeState({ on: true, roots, can: [], aliveAt: new Date().toISOString() }, env);
  return { env, roots };
}

test('a listener holding two projects starts the connection for each, with no session open in either', () => {
  const { env, roots } = twoProjects();
  const launched = [];
  const { Socket } = sockets();
  assert.strictEqual(wake.sessionsAlive(env), false);
  const did = wake.startAll({ env, out: sink(), launch: (x) => launched.push(x), Socket });
  assert.deepStrictEqual(launched.map((x) => x.repoId).sort(), [REPO, 6161]);
  assert.strictEqual(launched.find((x) => x.repoId === 6161).root, wake.mainRoot(roots['6161']));
  assert.deepStrictEqual(did.sort(), ['started', 'started']);
  fs.mkdirSync(path.join(env.SIPNSHIP_HOME, 'wake'), { recursive: true });
  fs.writeFileSync(path.join(env.SIPNSHIP_HOME, 'wake', `${REPO}.pid`), String(process.pid));
  fs.writeFileSync(path.join(env.SIPNSHIP_HOME, 'wake', '6161.pid'), String(process.pid));
  assert.deepStrictEqual(wake.startAll({ env, out: sink(), launch: (x) => launched.push(x), Socket }), ['running', 'running']);
  assert.strictEqual(launched.length, 2);
});

test('a listener turned off starts nothing', () => {
  const { env } = twoProjects();
  listen.writeState({ ...listen.readState(env), on: false }, env);
  const launched = [];
  assert.deepStrictEqual(wake.startAll({ env, out: sink(), launch: (x) => launched.push(x), Socket: class {} }), []);
  assert.strictEqual(launched.length, 0);
});

test('the connection stays while the listener runs, with no session seen, and looks on the usual beat', async () => {
  const { env, roots } = twoProjects();
  const { Socket, made } = sockets();
  const t = timers();
  let looks = 0;
  const conn = wake.run({ env, repoId: 6161, root: roots['6161'], Socket, timers: t, tick: async () => { looks++; return { outcome: 'nothing to start', model: false }; } });
  made[0].onopen();
  for (let i = 0; i < 40; i++) await t.beat();
  await settle();
  assert.strictEqual(looks, 1);
  conn.stop();
  assert.strictEqual(await conn, 'stopped');
});

test('with neither a listener nor a session the connection ends, as before', async () => {
  const env = connected();
  const { Socket } = sockets();
  const t = timers();
  const conn = wake.run({ env, repoId: REPO, root: home(), Socket, timers: t, tick: async () => ({}) });
  await t.beat();
  assert.strictEqual(await conn, 'no session');
});

test('status says what is true when the listener holds the project and the connection is not up yet', () => {
  const { env } = twoProjects();
  const o = sink();
  wake.status({ env, cwd: '.', out: o, repoOf: () => 'maya/market-stall' });
  assert.ok(!/not listening now/.test(o.text));
  assert.ok(/connecting|starts your drive here/.test(o.text));
});

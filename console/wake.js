'use strict';
// sipnship wake [start|run|status]
//
// This machine's own connection to SipNShip (specs/030-plugin-wake), so a press of Start now, Start next or an
// answer on the dashboard, or a round's last change landing, starts the drive here within moments, with the
// sign-ins this machine already has. No runner, no secret, no token to copy.
//
// Held only while something the builder started runs: a Claude session, or the app's timed drive (each of its
// looks is a session). The session hooks start it (`wake start`, which does nothing when it already runs) and
// mark each session's turns; once no session has been seen for a while it closes and ends, so nothing runs in
// the background that the builder did not start. Then the dashboard says it waits for the computer or the timed
// drive. One connection per repository on this machine, kept by the machine's own repository token (spec 006).
//
// It hears one message, {"wake":"request-waiting","repo":ID}, and acts only on that, for its own repository:
// it never runs anything the service sent. What a wake does is the timed drive's look, one at a time
// (./wake-tick). It tells the service four facts only: a heartbeat each half minute, that it took a wake, that
// one waits behind its look, and that the look ended. A token the service refuses ends it, and the next session
// start says so once: "This machine is no longer connected to SipNShip." Nothing here prints or logs a token.

const fs = require('fs');
const path = require('path');
const { spawn, execFileSync } = require('child_process');
const tokens = require('./tokens');
const { base } = require('./brief-send');
const { ticker, runTick } = require('./wake-tick');

const BEAT_MS = 30000;
/** How long after the last sign of a session the connection is kept: a little over the timed drive's twenty minutes. */
const LIVE_MS = 25 * 60000;
/** Heartbeats between two checks that the token still stands: ten minutes. */
const CHECK_EVERY = 20;
const RETRY_FIRST_MS = 1000;
const RETRY_MOST_MS = 60000;
const NOT_CONNECTED = 'This machine is no longer connected to SipNShip.';
const WAKE = 'request-waiting';
/** The other word it hears: Look now was pressed, so the drive looks whether or not anything is approved. */
const LOOK = 'look-now';
const LOG_KEEP = 200;

const dir = (env = process.env) => path.join(tokens.home(env), 'wake');
const file = (env, name) => path.join(dir(env), name);
const ensureDir = (env) => fs.mkdirSync(dir(env), { recursive: true, mode: 0o700 });

/** The mark every session hook touches on this machine; its time is the last sign of a session. */
const SEEN = 'seen';

function touch(env, name, now) {
  ensureDir(env);
  const f = file(env, name);
  try { fs.utimesSync(f, now / 1000, now / 1000); } catch { fs.writeFileSync(f, ''); }
}
const touchSeen = (env = process.env, now = Date.now()) => touch(env, SEEN, now);
/** The mark a running connection touches each half minute; the turn-end hook starts one again when it is old. */
const touchAlive = (env = process.env, now = Date.now()) => touch(env, 'alive', now);

/** How long the listener's last sign of life counts: as listen.js reads it for the brief. */
const LISTENER_ALIVE_MS = 6 * 60000;
/** Heartbeats between two looks the connection makes on its own while the listener holds it: twenty minutes, the timed drive's beat. */
const LOOK_EVERY = 40;

/** The listener's state on this machine: whether the person said Yes to it, and the projects it holds with their folders. */
function listenerState(env = process.env) {
  try { return require('./listen').readState(env); } catch { return { on: false, roots: {} }; }
}

/** Whether the listener the builder turned on is running now: it holds every project it has a folder for, with no session open. */
function listenerAlive(env = process.env, now = Date.now()) {
  const s = listenerState(env);
  const t = Date.parse(s.aliveAt || '');
  return s.on === true && !Number.isNaN(t) && now - t < LISTENER_ALIVE_MS;
}

/** Whether a session was seen recently enough to keep the connection. */
function sessionsAlive(env = process.env, now = Date.now()) {
  try { return now - fs.statSync(file(env, SEEN)).mtimeMs < LIVE_MS; } catch { return false; }
}

/** The wait before the next try: growing from a second to a minute. */
const retryMs = (tries) => Math.min(RETRY_FIRST_MS * 2 ** Math.max(0, tries), RETRY_MOST_MS);

/** True only for the wake message, for this repository. Anything else is dropped unread. */
function readWake(text, repoId) { return readWord(text, repoId) === WAKE; }
/** True only for the look message, for this repository. */
function readLook(text, repoId) { return readWord(text, repoId) === LOOK; }

/** The message's one word when it is exactly one of the two known messages for this repository, else undefined. */
function readWord(text, repoId) {
  if (typeof text !== 'string' || text.length > 200) return undefined;
  let m;
  try { m = JSON.parse(text); } catch { return undefined; }
  if (!m || typeof m !== 'object' || Array.isArray(m)) return undefined;
  if (Object.keys(m).some((k) => k !== 'wake' && k !== 'repo')) return undefined;
  return m.repo === repoId && (m.wake === WAKE || m.wake === LOOK) ? m.wake : undefined;
}

/**
 * What the connection did, one line each, in the plugin's home folder (never a token): connected, a wake received
 * and for which project, a look started or why not, the look ended. `sipnship wake status` prints the last few.
 */
const logFile = (env) => file(env, 'wake.log');
function writeLog(env, line, now = Date.now()) {
  try {
    ensureDir(env);
    const f = logFile(env);
    let lines = [];
    try { lines = fs.readFileSync(f, 'utf8').split('\n').filter(Boolean); } catch { /* none yet */ }
    lines.push(`${new Date(now).toISOString()} ${String(line).replace(/[\r\n]+/g, ' ').slice(0, 300)}`);
    fs.writeFileSync(f, lines.slice(-LOG_KEEP).join('\n') + '\n');
  } catch { /* a log that cannot be written never stops the connection */ }
}
function readLog(env, n = 8) {
  try { return fs.readFileSync(logFile(env), 'utf8').split('\n').filter(Boolean).slice(-n); } catch { return []; }
}

const pidAlive = (pid) => {
  try { process.kill(pid, 0); return true; } catch (e) { return !!e && e.code === 'EPERM'; }
};

function readPid(env, repoId) {
  try { return Number(fs.readFileSync(file(env, `${repoId}.pid`), 'utf8').trim()) || undefined; } catch { return undefined; }
}

/** The refused mark: the token's connectedAt it was refused for, and whether the session start has said so. */
function readRefused(env, repoId) {
  try { return JSON.parse(fs.readFileSync(file(env, `${repoId}.refused`), 'utf8')); } catch { return undefined; }
}
function writeRefused(env, repoId, r) {
  ensureDir(env);
  fs.writeFileSync(file(env, `${repoId}.refused`), JSON.stringify(r) + '\n');
}

/** The main checkout of the project a folder is in (a worktree's too), where the drive looks. */
function mainRoot(cwd) {
  try {
    const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    return path.basename(common) === '.git' ? path.dirname(common) : cwd;
  } catch { return cwd; }
}

/**
 * At a session's start or a turn's end: mark the session, and start the connection for this folder's repository
 * when this machine holds its token and it is not running yet. Prints the one line a refused token owes, once.
 * Returns what it did, for tests: 'started', 'running', 'refused', or 'none'.
 */
function start({ env = process.env, cwd = process.cwd(), out = process.stdout, launch = launchRun, now = Date.now(), repoOf = (d) => require('./connect').remoteRepo(d), rootOf = mainRoot, Socket = globalThis.WebSocket } = {}) {
  if (!fs.existsSync(tokens.file(env))) return 'none';
  touchSeen(env, now);
  const entry = tokens.find(repoOf(cwd), env);
  if (!entry) return 'none';
  return open({ env, entry, root: rootOf(cwd), out, launch, Socket });
}

/** The part of a start both roads share: one connection per repository, said once when its token was refused. */
function open({ env, entry, root, out, launch, Socket }) {
  const refused = readRefused(env, entry.repoId);
  if (refused && refused.connectedAt === entry.connectedAt) {
    if (!refused.said) {
      out.write(`${NOT_CONNECTED}\n`);
      writeRefused(env, entry.repoId, { ...refused, said: true });
    }
    return 'refused';
  }
  // A Node without its own WebSocket (older than 22) has no way to listen: the timed drive starts the round.
  if (typeof Socket !== 'function') return 'none';
  const pid = readPid(env, entry.repoId);
  if (pid && pidAlive(pid)) return 'running';
  launch({ env, repoId: entry.repoId, root });
  return 'started';
}

/**
 * Every project the running listener holds (#2791): the machine keeps one connection for each, in that project's own
 * folder, with no session open in any of them. Returns what it did for each, for tests; nothing when the listener is off.
 */
function startAll({ env = process.env, out = process.stdout, launch = launchRun, Socket = globalThis.WebSocket } = {}) {
  if (!fs.existsSync(tokens.file(env))) return [];
  const s = listenerState(env);
  if (s.on !== true) return [];
  const held = tokens.read(env).repos;
  const did = [];
  for (const [id, root] of Object.entries(s.roots || {})) {
    if (!held[id] || !root || !fs.existsSync(root)) continue;
    did.push(open({ env, entry: { repoId: Number(id), ...held[id] }, root: mainRoot(root), out, launch, Socket }));
  }
  return did;
}

/** Starts `wake run` on its own, out of the session's way, in the plugin's home folder rather than the project. */
function launchRun({ env, repoId, root }) {
  ensureDir(env);
  const child = spawn(process.execPath, [path.join(__dirname, 'cli.js'), 'wake', 'run', '--repo', String(repoId), '--root', root], { cwd: tokens.home(env), env, detached: true, stdio: 'ignore', windowsHide: true });
  child.unref();
}

/**
 * The connection itself. Everything it touches is handed in, so the suite runs it with a stand-in socket, clock
 * and drive look. Resolves when it ends: no session for a while, the token refused, or `stop()`.
 */
function run({ env = process.env, repoId, root, plugin = path.resolve(__dirname, '..'), Socket = globalThis.WebSocket, fetchFn = (u, i) => fetch(u, i), tick, timers = { setTimeout, clearTimeout, setInterval, clearInterval }, now = Date.now, alive = () => sessionsAlive(env, now()) || listenerAlive(env, now()), log = () => {} } = {}) {
  const note = (line) => writeLog(env, `[${repoId}] ${line}`, now());
  const logTick = (r) => { note(`look ended: ${r && r.outcome ? r.outcome : 'no word'}`); log(r); };
  const entry = tokens.find(String(repoId), env);
  if (!entry || typeof Socket !== 'function') return Promise.resolve('none');
  ensureDir(env);
  fs.writeFileSync(file(env, `${repoId}.pid`), String(process.pid));
  touchAlive(env, now());
  const url = `${base(env)}/v1/repos/${repoId}/wake`;
  const headers = { authorization: `Bearer ${entry.token}` };
  let ws = null;
  let open = false;
  let tries = 0;
  let ended = false;
  let again = null;
  let finish;
  const done = new Promise((r) => { finish = r; });
  const say = (fact) => { if (open && ws) { try { ws.send(JSON.stringify(fact)); } catch { /* the next connection says it */ } } };
  const looks = ticker({ tick: tick || ((kind) => runTick({ root, plugin, env, look: kind === 'look' })), report: say, lockPath: path.join(root, '.scratch', 'drive', 'wake.lock'), now, log: logTick, note });

  const end = (why) => {
    if (ended) return;
    ended = true;
    timers.clearInterval(beat);
    if (again) timers.clearTimeout(again);
    if (ws) { try { ws.close(1000); } catch { /* already closed */ } }
    try { if (readPid(env, repoId) === process.pid) fs.rmSync(file(env, `${repoId}.pid`), { force: true }); } catch { /* gone */ }
    finish(why);
  };

  // Before trying again after a connection that never opened: a plain request says whether the token is still good.
  // A refused one ends the connection, and the next session start says so once.
  const refusedNow = async () => {
    let res;
    try { res = await fetchFn(url, { headers, signal: AbortSignal.timeout(15000) }); } catch { return false; }
    if (res.status !== 401 && res.status !== 403 && res.status !== 404) return false;
    writeRefused(env, repoId, { connectedAt: entry.connectedAt, at: new Date(now()).toISOString(), said: false });
    end('refused');
    return true;
  };

  const connect = () => {
    again = null;
    if (ended) return;
    let s;
    try { s = new Socket(url.replace(/^http/, 'ws'), { headers }); } catch { schedule(); return; }
    ws = s;
    let opened = false;
    s.onopen = () => { opened = true; open = true; tries = 0; note('connected'); say({ beat: true }); };
    s.onmessage = (ev) => {
      const word = readWord(typeof ev.data === 'string' ? ev.data : String(ev.data), repoId);
      if (!word) return;
      note(`${word === LOOK ? 'look' : 'wake'} received, for ${repoId}, asked ${new Date(now()).toISOString()}`);
      looks.wake(word === LOOK ? 'look' : 'wake');
    };
    s.onerror = () => {};
    s.onclose = async () => {
      if (ws !== s) return;
      if (open) note('connection closed');
      open = false;
      ws = null;
      if (ended) return;
      if (!opened && (await refusedNow())) return;
      schedule();
    };
  };
  const schedule = () => { if (!ended && !again) again = timers.setTimeout(connect, retryMs(tries++)); };

  // Each half minute: a heartbeat while connected, a held wake tried again, and an end once no session is seen.
  // Every ten minutes the token is checked once, so one rotated or disconnected on the dashboard ends it.
  let beats = 0;
  const beat = timers.setInterval(async () => {
    if (!alive() && !looks.running) { end('no session'); return; }
    touchAlive(env, now());
    say({ beat: true });
    looks.retry();
    // Held by the listener alone (no session), the connection looks on the usual beat, as a timed drive would.
    if (++beats % LOOK_EVERY === 0 && !sessionsAlive(env, now()) && listenerAlive(env, now())) looks.wake();
    if (beats % CHECK_EVERY === 0) await refusedNow();
  }, BEAT_MS);

  connect();
  return Object.assign(done, { stop: () => end('stopped'), looks });
}

/** What this machine's connection is doing, for a person asking. */
function status({ env = process.env, cwd = process.cwd(), out = process.stdout, repoOf = (d) => require('./connect').remoteRepo(d) } = {}) {
  const entry = tokens.find(repoOf(cwd), env);
  if (!entry) { out.write('This machine is not connected to a repository yet. Run npx sipnship connect --repo first.\n'); return 2; }
  const refused = readRefused(env, entry.repoId);
  if (refused && refused.connectedAt === entry.connectedAt) { out.write(`${NOT_CONNECTED}\n`); return 0; }
  const pid = readPid(env, entry.repoId);
  const holds = listenerAlive(env) && !!listenerState(env).roots[String(entry.repoId)];
  const lines = readLog(env, 200).filter((l) => l.includes(`[${entry.repoId}]`)).slice(-8);
  const said = lines.length ? `Last things it did:\n${lines.map((l) => `  ${l}`).join('\n')}\n` : 'It has not done anything yet.\n';
  out.write(pid && pidAlive(pid)
    ? `This machine is listening for ${entry.fullName}: a press on the dashboard starts your drive here.\n`
    : holds
      ? `This machine is connecting for ${entry.fullName}: a press on the dashboard starts your drive here within a minute.\n`
      : `This machine is not listening for ${entry.fullName} now. Turn the listener on here (npx sipnship listen on) and a press starts your drive here, with no session open; until then a press waits for your drive's next look.\n`);
  out.write(said);
  return 0;
}

module.exports = { start, startAll, listenerAlive, run, status, readWake, readLook, writeLog, readLog, retryMs, touchSeen, sessionsAlive, mainRoot, launchRun, BEAT_MS, LIVE_MS, NOT_CONNECTED };

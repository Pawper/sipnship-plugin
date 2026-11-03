'use strict';
// sipnship listen [on|off|status]
//
// The listener (spec 012): a small process for the signed-in user that,
// every two minutes, asks SipNShip for the requests the person approved for
// this machine and carries them out, one at a time, each with its fixed
// script. It is off until the person turns it on, here, on this machine:
// `listen on` (or the question at the end of `connect --repo`). The
// dashboard cannot turn it on; Disconnect ends it at once, since the token
// stops working. Before anything runs, the request is checked again as data,
// never as instructions: a kind it knows, a parameter that passes its rule,
// an approver who is this machine's gh sign-in, younger than 30 minutes, for
// a repository this machine holds a token for. Each step is reported with
// the kind's own facts only; one line per request goes to requests.log.

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const tokens = require('./tokens');
const requestLog = require('./request-log');
const rules = require('./request-rules');
const { perform } = require('./listen-kinds');
const { base } = require('./brief-send');
const { askWindow } = require('./ask-window');

const POLL_MS = 2 * 60000;
const SLOW_POLL_MS = 10 * 60000;
// The brief carries `can` only while the listener has been seen alive this recently.
const ALIVE_MS = 6 * 60000;

const stateFile = (env = process.env) => path.join(tokens.home(env), 'listen.json');

function readState(env = process.env) {
  try {
    const s = JSON.parse(fs.readFileSync(stateFile(env), 'utf8'));
    return { on: s.on === true, roots: s.roots && typeof s.roots === 'object' ? s.roots : {}, can: Array.isArray(s.can) ? s.can : [], aliveAt: s.aliveAt };
  } catch {
    return { on: false, roots: {}, can: [] };
  }
}

function writeState(s, env = process.env) {
  fs.mkdirSync(tokens.home(env), { recursive: true, mode: 0o700 });
  fs.writeFileSync(stateFile(env), JSON.stringify(s, null, 2) + '\n');
}

// What the brief says of the listener: the kinds it carries out while it is on and seen alive, otherwise nothing.
function briefCan(env = process.env, now = Date.now()) {
  const s = readState(env);
  const t = Date.parse(s.aliveAt || '');
  return s.on && !Number.isNaN(t) && now - t < ALIVE_MS && s.can.length ? s.can : undefined;
}

const exec = (cmd, args, { cwd, timeoutMs = 60000 } = {}) => {
  const r = spawnSync(cmd, args, { cwd, encoding: 'utf8', timeout: timeoutMs, stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true });
  return { status: r.status === null ? -1 : r.status, stdout: r.stdout || '' };
};

// Windows' own prompt: a second approval no request can skip. 87 means it was refused, 'timeout' that nobody answered.
function elevated(file, args, timeoutMs) {
  const list = [`"${file}"`, ...args].map((a) => `'${String(a).replace(/'/g, "''")}'`);
  const ps = `try { $p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList '-ExecutionPolicy','Bypass','-File',${list.join(',')}; exit $p.ExitCode } catch { exit 87 }`;
  const r = spawnSync('powershell', ['-NoProfile', '-Command', ps], { timeout: timeoutMs, stdio: 'ignore', windowsHide: true });
  return r.status === null ? 'timeout' : r.status;
}

// What this machine found: Windows or not, who gh is signed in as, admin rights on the repository, the antivirus.
function findFacts(fullName, run = exec, platform = process.platform) {
  const who = run('gh', ['api', 'user', '--jq', '.login']);
  const ghAs = who.status === 0 ? who.stdout.trim() : '';
  const admin = ghAs && run('gh', ['api', `repos/${fullName}`, '--jq', '.permissions.admin']).stdout.trim() === 'true';
  const windows = platform === 'win32';
  const antivirus = windows && run('powershell', ['-NoProfile', '-Command', '(Get-MpComputerStatus).AntivirusEnabled'], { timeoutMs: 20000 }).stdout.trim() === 'True';
  return { windows, ghAs: ghAs || undefined, admin: !!admin, antivirus: !!antivirus };
}

async function call(url, token, init = {}) {
  const res = await fetch(url, { ...init, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, signal: AbortSignal.timeout(15000) });
  return { status: res.status, text: await res.text().catch(() => '') };
}

// One poll for one repository: read what was approved, check each again, carry out one at a time, report each step.
async function serveRepo(entry, io) {
  const { env, say, now = Date.now, ctxFor } = io;
  const url = `${base(env)}/v1/repos/${entry.repoId}/machine/requests`;
  let read;
  try { read = await call(`${url}/open`, entry.token); } catch { return { reached: false }; }
  if (read.status !== 200) return { reached: false };
  const facts = io.facts(entry.fullName);
  const can = rules.canKinds(facts);
  for (const req of rules.parseLines(read.text)) {
    const report = (body) => call(`${url}/${req.id}/step`, entry.token, { method: 'POST', body: JSON.stringify(body) }).catch(() => undefined);
    const bad = rules.refusal(req, { ghAs: facts.ghAs, can, now: now() });
    let result;
    if (bad) {
      result = { outcome: bad, facts: {} };
    } else {
      await report({ step: 'picked-up' });
      const ctx = ctxFor(entry, async (step) => { await report({ step }); });
      result = await perform(req.kind, req.param, ctx);
    }
    await report({ outcome: result.outcome, facts: rules.stepFacts(req.kind, result.facts) });
    requestLog.append({ at: new Date(now()).toISOString(), kind: req.kind, askedBy: req.askedBy, approvedBy: req.approvedBy, outcome: result.outcome }, env);
    say(`${req.kind}: ${result.outcome}`);
  }
  return { reached: true, can };
}

// listen({ env, once }): the loop. With `once`, one poll of every repository and back (tests, and a person checking by hand).
async function listen({ env = process.env, out = process.stdout, once = false, io = {}, sleep = (ms) => new Promise((r) => setTimeout(r, ms)) } = {}) {
  const state = readState(env);
  if (!state.on) { out.write('The listener is off. Turn it on here, on this machine: npx sipnship listen on\n'); return 1; }
  const say = (s) => out.write(`${s}\n`);
  // What this machine found is looked up again every ten minutes, not at every poll.
  const memo = new Map();
  const make = {
    env,
    say,
    facts: (full) => {
      const m = memo.get(full);
      if (m && Date.now() - m.at < 10 * 60000) return m.f;
      const f = findFacts(full);
      memo.set(full, { at: Date.now(), f });
      return f;
    },
    ctxFor: (entry, step) => ({ root: readState(env).roots[String(entry.repoId)] || process.cwd(), fullName: entry.fullName, exec, elevated, step, sleep, now: Date.now, home: tokens.home(env) }),
    ...io,
  };
  let down = false;
  for (;;) {
    const s = readState(env);
    if (!s.on) { say('The listener was turned off, so it stopped.'); return 0; }
    const entries = Object.entries(tokens.read(env).repos).map(([id, e]) => ({ repoId: Number(id), ...e })).filter((e) => s.roots[String(e.repoId)]);
    let reachedAny = !entries.length;
    let can = [];
    for (const e of entries) {
      const r = await serveRepo(e, make);
      if (r.reached) { reachedAny = true; can = r.can; }
    }
    if (entries.length && !reachedAny && !down) { say('Could not reach SipNShip. Nothing runs until it can; it will keep trying every ten minutes.'); }
    down = entries.length > 0 && !reachedAny;
    if (reachedAny) writeState({ ...readState(env), can, aliveAt: new Date().toISOString() }, env);
    if (once) return 0;
    await sleep(down ? SLOW_POLL_MS : POLL_MS);
  }
}

const TASK = 'SipNShip listener';

// A task that starts the listener at sign-in (Windows only; elsewhere the person starts it, and the line says so).
function registerTask(on, cli = path.join(__dirname, 'cli.js'), run = exec, platform = process.platform) {
  if (platform !== 'win32') return false;
  const r = on ? run('schtasks', ['/Create', '/TN', TASK, '/TR', `"${process.execPath}" "${cli}" listen`, '/SC', 'ONLOGON', '/F']) : run('schtasks', ['/Delete', '/TN', TASK, '/F']);
  return r.status === 0;
}

// turn(on, { root, repo }): the person's switch, here on the machine. `on` remembers this folder for the repository.
function turn(on, { env = process.env, out = process.stdout, cwd = process.cwd(), repo, register = registerTask } = {}) {
  const s = readState(env);
  if (on) {
    const { remoteRepo } = require('./connect');
    const entry = tokens.find(repo || remoteRepo(cwd), env);
    if (!entry) { out.write('This machine is not connected to a repository yet. Run npx sipnship connect --repo first.\n'); return 2; }
    s.roots[String(entry.repoId)] = cwd;
    s.on = true;
    writeState(s, env);
    const task = register(true);
    out.write(`This machine now carries out what you ask from the dashboard for ${entry.fullName}, once you approve it there. Windows still asks you before anything runs as administrator.\n`);
    out.write(task ? 'It starts when you sign in. Start it now with: npx sipnship listen\n' : 'Start it with: npx sipnship listen (it could not be set to start at sign-in here).\n');
    return 0;
  }
  s.on = false;
  s.can = [];
  writeState(s, env);
  register(false);
  out.write('The listener is off. This machine carries out nothing from the dashboard.\n');
  return 0;
}

function status({ env = process.env, out = process.stdout } = {}) {
  const s = readState(env);
  out.write(`The listener is ${s.on ? 'on' : 'off'}${s.on && briefCan(env) ? ' and running' : s.on ? ', but not running now' : ''}.\n`);
  out.write('What this machine did for you:\n');
  const rows = requestLog.recent(20, env);
  if (!rows.length) out.write('  Nothing yet.\n');
  for (const r of rows) out.write(`  ${r.at}  ${r.kind}  asked by ${r.askedBy}, approved by ${r.approvedBy}: ${r.outcome}\n`);
  return 0;
}

// offerOn: the one question at the end of `connect --repo` and behind `listen on`, asked in a window on
// the machine's own screen, No by default (spec 012). `ask` and `window` are injected so tests show nothing.
async function offerOn({ env = process.env, out = process.stdout, cwd = process.cwd(), repo, ask, register, window: show = askWindow } = {}) {
  const entry = tokens.find(repo || require('./connect').remoteRepo(cwd), env);
  const answer = ask ? await ask() : show({ machine: entry && entry.machine, env }) ? 'yes' : 'no';
  if (!/^y/i.test(String(answer).trim())) return false;
  return turn(true, { env, out, cwd, repo, register }) === 0;
}

module.exports = { listen, serveRepo, turn, status, offerOn, briefCan, findFacts, readState, writeState, registerTask, elevated, exec, POLL_MS, SLOW_POLL_MS };

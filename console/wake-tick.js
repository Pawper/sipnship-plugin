'use strict';
// One drive look at a time, started by a wake (specs/030-plugin-wake, "One tick at a time per repository").
//
// A wake while a look runs is remembered as one pending wake: any number of them collapse to one, and it runs
// after the look ends. The look itself is what the timed drive does, with this machine's own sign-ins: the plan
// and the approval with plain scripts and no model (wake-check.sh), and only when something is approved, one
// headless look of the drive. A wake the timed drive already handled finds the round started and ends there.
// The service learns three facts on the way, through `report`: the wake was taken, one waits behind the look,
// and the look ended. Nothing the service sent is ever run: a wake carries no instruction.

const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

/** The longest a look may run, as the runner wake allows: its agents work for up to ninety minutes. */
const TICK_MAX_MS = 100 * 60000;
/** A lock older than this is from a look that did not end cleanly, and is taken over. */
const LOCK_STALE_MS = TICK_MAX_MS + 10 * 60000;
const PROMPT = '/sipnship:project-drive';

/** Runs a command without holding up the connection: the heartbeat goes on while a look runs. */
const exec = (cmd, args, { cwd, timeoutMs = 5 * 60000, env, shell = false } = {}) => new Promise((resolve) => {
  let out = '';
  let child;
  try {
    child = spawn(cmd, args, { cwd, env, shell, stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true });
  } catch {
    resolve({ status: -1, stdout: '' });
    return;
  }
  const timer = setTimeout(() => { try { child.kill(); } catch { /* already ended */ } }, timeoutMs);
  child.stdout.on('data', (d) => { if (out.length < 1e6) out += d; });
  child.on('error', () => { clearTimeout(timer); resolve({ status: -1, stdout: out }); });
  child.on('close', (code) => { clearTimeout(timer); resolve({ status: code === null ? -1 : code, stdout: out }); });
});

const alivePid = (pid) => {
  try { process.kill(pid, 0); return true; } catch (e) { return e && e.code === 'EPERM'; }
};

/** Takes the project's lock (.scratch/drive/wake.lock); false while another live look holds it. */
function takeLock(lock, now = Date.now(), alive = alivePid) {
  fs.mkdirSync(path.dirname(lock), { recursive: true });
  const body = JSON.stringify({ pid: process.pid, at: new Date(now).toISOString() });
  try {
    fs.writeFileSync(lock, body, { flag: 'wx' });
    return true;
  } catch {
    let held = {};
    try { held = JSON.parse(fs.readFileSync(lock, 'utf8')); } catch { /* unreadable: taken over */ }
    const at = Date.parse(held.at || '');
    if (held.pid && held.pid !== process.pid && alive(held.pid) && !Number.isNaN(at) && now - at < LOCK_STALE_MS) return false;
    fs.writeFileSync(lock, body);
    return true;
  }
}

function freeLock(lock) {
  try {
    const held = JSON.parse(fs.readFileSync(lock, 'utf8'));
    if (held.pid === process.pid) fs.rmSync(lock, { force: true });
  } catch { /* already gone */ }
}

/** The repository's own runner wake (specs/025-drive-wake) has a run going or waiting: that run takes the press. */
async function runnerWakeBusy(root, run = exec) {
  if (!fs.existsSync(path.join(root, '.github', 'workflows', 'drive-wake.yml'))) return false;
  for (const status of ['in_progress', 'queued']) {
    const r = await run('gh', ['api', `repos/{owner}/{repo}/actions/workflows/drive-wake.yml/runs?status=${status}&per_page=1`, '--jq', '.total_count'], { cwd: root, timeoutMs: 20000 });
    if (r.status === 0 && Number(r.stdout.trim()) > 0) return true;
  }
  return false;
}

/** wake-check.sh's verdict: its last "start:" or "nothing:" line. */
function verdictOf(text) {
  const lines = String(text || '').split(/\r?\n/).filter((l) => /^(start|nothing): /.test(l));
  const last = lines[lines.length - 1];
  return last ? { start: last.startsWith('start: '), why: last.replace(/^(start|nothing): /, '') } : { start: false, why: 'the check said nothing' };
}

/**
 * One look, in the project's main checkout. Returns { outcome, model } where model says whether Claude ran.
 * `run` stands in for spawnSync in tests; `plugin` is the plugin's root, where wake-check.sh lives.
 */
async function runTick({ root, plugin, run = exec, env = process.env, platform = process.platform, look = false }) {
  if (!look && await runnerWakeBusy(root, run)) return { outcome: "the project's own wake is already on it", model: false };
  // Look now asks the drive to look whether or not anything is approved, so the approval check is not asked.
  let v = { start: true, why: 'a look was asked for' };
  if (!look) {
    const check = await run('sh', [path.join(plugin, 'scripts', 'drive', 'wake-check.sh')], { cwd: root, timeoutMs: 5 * 60000 });
    v = verdictOf(check.stdout);
    if (check.status === -1 && !v.start) return { outcome: 'the check could not run on this computer', model: false, failed: true };
    if (!v.start) return { outcome: `nothing to start: ${v.why}`, model: false };
  }
  // The agents the look starts outlive its own turn, as on the runner; the hundred minutes still bound it.
  // On Windows the shell finds claude whether it is installed as a program or as an npm command; the arguments are fixed.
  const r = await run('claude', ['-p', PROMPT], { cwd: root, timeoutMs: TICK_MAX_MS, shell: platform === 'win32', env: { ...env, CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS: '0' } });
  // The program could not be found or started at all (not a look that began and ended badly): the band says so.
  if (r.status === -1 && !r.stdout) return { outcome: 'the coding agent could not be started in the project folder; the timed drive takes it next', model: false, failed: true };
  return { outcome: r.status === 0 ? `started: ${v.why}` : 'the drive did not finish its look; the timed drive takes it next', model: true };
}

/**
 * The one-at-a-time rule. `tick()` runs one look (async, resolving to its result); `report(fact)` tells the
 * service; `lockPath` is the project's lock. wake() is called for each wake heard.
 */
function ticker({ tick, report = () => {}, lockPath, now = Date.now, log = () => {}, note = () => {} }) {
  const t = { running: false, pending: false, looks: 0, kind: 'wake' };
  async function go() {
    if (lockPath && !takeLock(lockPath, now())) {
      // Another look on this machine holds the project: this one waits behind it, and is tried again at the next heartbeat.
      t.pending = true;
      note('a look is already running on this computer; waiting for it');
      report({ pending: true });
      return;
    }
    t.running = true;
    t.pending = false;
    t.looks += 1;
    const kind = t.kind;
    t.kind = 'wake';
    report({ taken: true });
    note(`${kind === 'look' ? 'look' : 'wake'} taken; starting a look`);
    let result;
    try { result = await tick(kind); } catch { result = { outcome: 'the look could not run; the timed drive takes it next', model: false, failed: true }; }
    if (lockPath) freeLock(lockPath);
    t.running = false;
    // A look that could not start is said apart from one that ended: the band tells the builder within the minute.
    report(result && result.failed ? { failed: true } : { done: true });
    log(result);
    if (t.pending) await go();
  }
  t.wake = (kind) => {
    if (kind === 'look') t.kind = 'look';
    if (t.running) {
      if (!t.pending) report({ pending: true });
      t.pending = true;
      return Promise.resolve();
    }
    return go();
  };
  /** At a heartbeat: a wake held behind another process's look runs once that look has ended. */
  t.retry = () => (!t.running && t.pending ? go() : Promise.resolve());
  return t;
}

module.exports = { ticker, runTick, runnerWakeBusy, verdictOf, takeLock, freeLock, exec, PROMPT, TICK_MAX_MS, LOCK_STALE_MS };

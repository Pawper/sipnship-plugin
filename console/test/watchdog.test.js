'use strict';
// Tests for the watchdog's decision rule and its tick, on fixture process
// lists (one file per case; nothing here starts a process that holds memory).
// Run with: node --test console/test/watchdog.test.js

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const dir = path.join(__dirname, 'fixtures', 'watchdog');
const file = path.join(__dirname, '..', '..', 'templates', 'scripts', 'ci', 'watchdog.mjs');
const load = () => import('file://' + file.replace(/\\/g, '/'));
const GB = 1024 ** 3;

for (const name of fs.readdirSync(dir).filter((n) => n.endsWith('.json'))) {
  test(`case: ${name.replace(/\.json$/, '').replace(/-/g, ' ')}`, async () => {
    const w = await load();
    const f = JSON.parse(fs.readFileSync(path.join(dir, name), 'utf8'));
    const r = w.decide(f.processes, f.now, f.memory, {}, 0);
    assert.deepEqual(r.end.map((e) => e.process.pid), f.end);
    if (f.why) assert.ok(r.end.every((e) => e.why === f.why));
    if (f.warnTop === null) assert.equal(r.warn, null);
    if (Array.isArray(f.warnTop)) assert.deepEqual(r.warn.top.map((p) => p.pid), f.warnTop);
  });
}

const scratch = () => fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-'));
const load1 = (n) => JSON.parse(fs.readFileSync(path.join(dir, n + '.json'), 'utf8'));

test('a process that grows past the limit is recorded first, ended, and said once', async () => {
  const w = await load();
  const f = load1('git-over-limit-under-session');
  const home = scratch();
  const env = { SIPNSHIP_HOME: home };
  const calls = [];
  const grown = f.processes.map((p) => (p.pid === 12 ? { ...p, bytes: 5 * GB } : p));
  // First minute: under the limit, nothing happens.
  const first = w.tick({ env, now: f.now, machine: { processes: grown, memory: null }, folder: () => 'C:/w', end: (pid) => calls.push(pid), selfPid: 1 });
  assert.deepEqual([first.said, calls], [[], []]);
  // Next minute: over it.
  const order = [];
  const second = w.tick({
    env, now: f.now + 60000, machine: { processes: f.processes, memory: null }, folder: () => 'C:/w/rooftop',
    end: (pid) => { order.push(['end', pid, fs.existsSync(path.join(home, 'runner-watch', 'watchdog.log'))]); }, selfPid: 1,
  });
  assert.deepEqual(order, [['end', 12, true]], 'the record exists before the process is ended');
  const log = fs.readFileSync(path.join(home, 'runner-watch', 'watchdog.log'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.equal(log[0].program, 'git.exe');
  assert.equal(log[0].command, 'git gc');
  assert.equal(log[0].folder, 'C:/w/rooftop');
  assert.deepEqual(log[0].parents.map((p) => p.pid), [11, 10, 9]);
  assert.equal(log[0].parentEnded, null);
  assert.equal(log[0].bytes, Math.round(107.5 * GB));
  assert.equal(log[0].ranMinutes, 22 * 60 + 1);
  assert.equal(log[1].outcome, 'ended');
  assert.match(second.said[0], /ended a git process holding 107\.5 GB that had run for 22 hours/);
  const said = fs.readFileSync(path.join(home, 'runner-watch', 'watchdog-said.txt'), 'utf8').trim().split('\n');
  assert.equal(said.length, 1);
  // The same process gone, a third minute says nothing more.
  const third = w.tick({ env, now: f.now + 120000, machine: { processes: f.processes.filter((p) => p.pid !== 12), memory: null }, end: () => assert.fail('nothing to end'), selfPid: 1 });
  assert.deepEqual(third.said, []);
  assert.equal(fs.readFileSync(path.join(home, 'runner-watch', 'watchdog-said.txt'), 'utf8').trim().split('\n').length, 1);
});

test('a process Windows will not let it end is recorded and said so, not claimed ended', async () => {
  const w = await load();
  const f = load1('orphan-over-three-hours');
  const home = scratch();
  const r = w.tick({ env: { SIPNSHIP_HOME: home }, now: f.now, machine: { processes: f.processes, memory: null }, folder: () => null, end: () => { throw new Error('denied'); }, selfPid: 1 });
  assert.match(r.said[0], /tried to end a bash process.*would not let it/);
  assert.match(fs.readFileSync(path.join(home, 'runner-watch', 'watchdog.log'), 'utf8'), /"outcome":"refused"/);
});

test('a process gone before it is ended is left alone', async () => {
  const w = await load();
  const f = load1('orphan-over-three-hours');
  const home = scratch();
  const r = w.tick({ env: { SIPNSHIP_HOME: home }, now: f.now, machine: { processes: f.processes, memory: null }, reread: () => ({ processes: [] }), end: () => assert.fail('gone'), selfPid: 1 });
  assert.deepEqual(r.said, []);
});

test('the left-alone cases end nothing and write nothing in a tick', async () => {
  const w = await load();
  const home = scratch();
  for (const n of fs.readdirSync(dir).filter((x) => x.includes('left-alone'))) {
    const f = JSON.parse(fs.readFileSync(path.join(dir, n), 'utf8'));
    w.tick({ env: { SIPNSHIP_HOME: home }, now: f.now, machine: { processes: f.processes, memory: f.memory }, end: () => assert.fail(n), selfPid: 1 });
  }
  assert.equal(fs.existsSync(path.join(home, 'runner-watch', 'watchdog.log')), false);
});

test('print reads and decides but ends and writes nothing', async () => {
  const w = await load();
  const f = load1('git-over-limit-under-session');
  const home = scratch();
  const r = w.tick({ env: { SIPNSHIP_HOME: home }, now: f.now, machine: { processes: f.processes, memory: null }, print: true, end: () => assert.fail('print'), selfPid: 1 });
  assert.match(r.said[0], /would end a git process/);
  assert.equal(fs.existsSync(path.join(home, 'runner-watch')), false);
});

test('the limits are settings with the defaults', async () => {
  const w = await load();
  assert.deepEqual(w.DEFAULTS, { limitGb: 20, hours: 3, warnPercent: 85 });
  const f = load1('just-under-the-limit-left-alone');
  assert.deepEqual(w.decide(f.processes, f.now, null, { limitGb: 10 }, 0).end.map((e) => e.process.pid), [95]);
  const o = load1('orphan-under-three-hours-left-alone');
  assert.deepEqual(w.decide(o.processes, o.now, null, { hours: 1 }, 0).end.map((e) => e.process.pid), [31]);
  const home = scratch();
  fs.writeFileSync(path.join(home, 'watchdog.json'), JSON.stringify({ limitGb: 7 }));
  assert.equal(w.readSettings({ SIPNSHIP_HOME: home }).limitGb, 7);
  assert.deepEqual(w.readSettings({ SIPNSHIP_HOME: scratch() }), {});
});

test('past 85% of the commit limit the line names the five largest; under it the line clears', async () => {
  const w = await load();
  const home = scratch();
  const f = load1('warn-names-five-largest');
  const r = w.tick({ env: { SIPNSHIP_HOME: home }, now: f.now, machine: { processes: f.processes, memory: f.memory }, end: () => assert.fail('warn only'), selfPid: 1 });
  assert.match(r.warn, /Memory is 88% full\. The five largest: chrome 9\.0 GB, chrome 8\.0 GB, chrome 7\.0 GB, chrome 6\.0 GB, chrome 5\.0 GB/);
  const wf = path.join(home, 'runner-watch', 'watchdog-warn.txt');
  assert.match(fs.readFileSync(wf, 'utf8'), /^\d+\tMemory is 88% full/);
  const g = load1('memory-under-85-no-warning');
  w.tick({ env: { SIPNSHIP_HOME: home }, now: g.now, machine: { processes: g.processes, memory: g.memory }, selfPid: 1 });
  assert.equal(fs.readFileSync(wf, 'utf8'), '');
});

test('the task is made once: found, it is left; missing, it is created every minute', async () => {
  const w = await load();
  const seen = [];
  assert.equal(w.ensureTask('x.mjs', (c, a) => { seen.push(a[0]); return { status: 0 }; }, 'win32'), 'present');
  assert.deepEqual(seen, ['/Query']);
  const made = [];
  assert.equal(w.ensureTask('x.mjs', (c, a) => { made.push(a); return { status: a[0] === '/Query' ? 1 : 0 }; }, 'win32'), 'created');
  assert.ok(made[1].includes('MINUTE') && made[1].includes('1'));
  assert.equal(w.ensureTask('x.mjs', () => assert.fail('no'), 'linux'), 'not-windows');
});

test('on Windows the working folder of a live process is read (this very process)', { skip: process.platform !== 'win32' }, async () => {
  const w = await load();
  const got = w.folderOf(process.pid);
  assert.equal(String(got).replace(/\\$/, '').toLowerCase(), process.cwd().replace(/\\$/, '').toLowerCase());
});

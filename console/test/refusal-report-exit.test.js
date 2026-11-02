'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const { envFor, fake, keep, TOKEN } = require('./refusal-helpers');

const SCRIPTS = path.join(__dirname, '..', '..', 'hooks', 'scripts');

/** A git project that points at acme/garden, with a refusal by the delete hook already waiting for session S. */
function repo(session = 'sess-maya-1') {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-exit-'));
  spawnSync('git', ['init', '-q'], { cwd: root });
  spawnSync('git', ['remote', 'add', 'origin', 'https://github.com/acme/garden.git'], { cwd: root });
  fs.mkdirSync(path.join(root, '.scratch', 'hooks'), { recursive: true });
  const id = '2026-11-02T16:10:00Z-4121';
  fs.writeFileSync(path.join(root, '.scratch', 'hooks.log'), `2026-11-02T16:10:00Z\tblock-delete\t${session}\t${id}\n`);
  fs.writeFileSync(path.join(root, '.scratch', 'hooks', 'pending'), `${id}\tblock-delete\t${session}\t0\n`);
  return { root, id };
}

/** Runs a hook script with stdin; resolves with its exit code and what it printed. */
function hook(script, input, env, cwd, scripts = SCRIPTS) {
  return new Promise((resolve) => {
    const p = spawn('sh', [path.join(scripts, script)], { cwd, env: { ...process.env, ...env }, stdio: ['pipe', 'pipe', 'pipe'] });
    let out = ''; let err = '';
    p.stdout.on('data', (d) => (out += d));
    p.stderr.on('data', (d) => (err += d));
    p.on('close', (code) => resolve({ code, out, err }));
    p.stdin.end(JSON.stringify(input));
  });
}

const refused = { tool_name: 'Bash', session_id: 'sess-maya-1', tool_input: { command: 'rm frost-alerts.txt' }, command: 'rm frost-alerts.txt' };
const stop = (session = 'sess-maya-1') => ({ hook_event_name: 'Stop', session_id: session });

test('no refusing hook changes its exit code or its words with the sender present, failing or off', async () => {
  const dead = envFor('http://127.0.0.1:9');
  const none = { SIPNSHIP_HOME: fs.mkdtempSync(path.join(os.tmpdir(), 'sns-exit-home-')) };
  const results = [];
  for (const env of [none, dead, { ...dead, HOOK_LOG: '0' }]) {
    const { root } = repo();
    const r = await hook('block-delete.sh', refused, { ...env, CLAUDE_PROJECT_DIR: root }, root);
    results.push([r.code, r.out, r.err]);
    const ok = await hook('block-delete.sh', { tool_name: 'Bash', command: 'ls' }, { ...env, CLAUDE_PROJECT_DIR: root }, root);
    assert.deepStrictEqual([ok.code, ok.out, ok.err], [0, '', '']);
  }
  assert.strictEqual(results[0][0], 2);
  assert.match(results[0][2], /^Blocked `/);
  assert.deepStrictEqual(results[1], results[0]);
  assert.deepStrictEqual(results[2], results[0]);
});

test('settling a tool call prints nothing and exits 0 whatever the sender does', async () => {
  const dead = envFor('http://127.0.0.1:9');
  const { root } = repo();
  const r = await hook('watch-resolution.sh', { hook_event_name: 'PostToolUse', session_id: 'sess-maya-1', tool_name: 'Bash', command: 'git mv frost-alerts.txt aside/frost-alerts.txt' }, { ...dead, CLAUDE_PROJECT_DIR: root }, root);
  assert.deepStrictEqual([r.code, r.out], [0, '']);
  const settled = fs.readFileSync(path.join(root, '.scratch', 'hooks-resolved.log'), 'utf8').trim().split('\t');
  // time, id, hook, session, outcome, seconds, calls, via
  assert.deepStrictEqual(settled.slice(1, 5), ['2026-11-02T16:10:00Z-4121', 'block-delete', 'sess-maya-1', 'followed']);
  assert.match(settled[5], /^\d+$/);
  assert.strictEqual(settled[6], '1');
});

test('at a turn\'s end it settles first and sends after: the open refusal goes as "stopped", once', async () => {
  const f = await fake([keep(['2026-11-02T16:10:00Z-4121'])]);
  const env = envFor(f.url);
  const { root } = repo();
  const r = await hook('watch-resolution.sh', stop(), { ...env, CLAUDE_PROJECT_DIR: root }, root);
  assert.strictEqual(r.code, 0);
  assert.match(r.out, /^This machine now also tells SipNShip/);
  assert.strictEqual(f.seen.length, 1);
  assert.strictEqual(f.seen[0].auth, `Bearer ${TOKEN}`);
  assert.deepStrictEqual(JSON.parse(f.seen[0].body).reports.map((x) => [x.rule, x.outcome, x.calls]), [['block-delete', 'stopped', 0]]);
  // a later turn with nothing new sends nothing
  const again = await hook('watch-resolution.sh', stop(), { ...env, CLAUDE_PROJECT_DIR: root }, root);
  assert.deepStrictEqual([again.code, again.out], [0, '']);
  assert.strictEqual(f.seen.length, 1);
  f.server.close();
});

test('a failing service is said once in a session and the turn still ends with exit 0', async () => {
  const dead = envFor('http://127.0.0.1:9');
  const { root } = repo();
  const first = await hook('watch-resolution.sh', stop(), { ...dead, CLAUDE_PROJECT_DIR: root }, root);
  assert.strictEqual(first.code, 0);
  assert.strictEqual(first.out.trim().split('\n').length, 1);
  assert.match(first.out, /^Could not reach SipNShip/);
  const second = await hook('watch-resolution.sh', stop(), { ...dead, CLAUDE_PROJECT_DIR: root }, root);
  assert.deepStrictEqual([second.code, second.out], [0, '']);
});

test('without the sender script, the watcher still exits 0 and prints nothing', async () => {
  const copy = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-exit-scripts-'));
  for (const f of fs.readdirSync(SCRIPTS)) if (f !== 'send-refusals.sh') fs.copyFileSync(path.join(SCRIPTS, f), path.join(copy, f));
  const { root } = repo();
  const r = await hook('watch-resolution.sh', stop(), { ...envFor('http://127.0.0.1:9'), CLAUDE_PROJECT_DIR: root }, root, copy);
  assert.deepStrictEqual([r.code, r.out], [0, '']);
});

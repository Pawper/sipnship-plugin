'use strict';
// The session sample's hook sends at every session start, and at most once a
// minute when an agent starts or stops or a turn ends, so an agent started
// later reaches its card without waiting for the next session.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const hook = path.join(__dirname, '..', '..', 'hooks', 'scripts', 'session-sample.sh');

/** Runs the hook for an event in a folder with no remote, so it stops before any request; returns the minute mark it left. */
function run(home, event) {
  const project = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-hook-proj-'));
  const input = JSON.stringify({ session_id: 'x', hook_event_name: event, cwd: project });
  execFileSync('sh', [hook], { input, env: { ...process.env, SIPNSHIP_HOME: home, CLAUDE_PROJECT_DIR: project }, stdio: ['pipe', 'pipe', 'ignore'] });
  try { return fs.readFileSync(path.join(home, 'brief-send', 'sample-at'), 'utf8').trim(); } catch { return ''; }
}

function connectedHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-hook-home-'));
  fs.writeFileSync(path.join(home, 'tokens.json'), '{}');
  return home;
}

test('an agent starting sends when the last send was over a minute ago, and not again within the minute', () => {
  const home = connectedHome();
  fs.mkdirSync(path.join(home, 'brief-send'));
  fs.writeFileSync(path.join(home, 'brief-send', 'sample-at'), '1000\n');
  const first = run(home, 'SubagentStart');
  assert.notStrictEqual(first, '1000', 'a send over a minute after the last goes ahead');
  fs.writeFileSync(path.join(home, 'brief-send', 'sample-at'), `${first}\n`);
  assert.strictEqual(run(home, 'Stop'), first, 'a second within the minute waits');
});

test('a session starting always sends', () => {
  const home = connectedHome();
  fs.mkdirSync(path.join(home, 'brief-send'));
  const soon = String(Math.floor(Date.now() / 1000) + 5);
  fs.writeFileSync(path.join(home, 'brief-send', 'sample-at'), `${soon}\n`);
  assert.notStrictEqual(run(home, 'SessionStart'), soon);
});

test('a machine with no connection sends nothing and keeps no mark', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-hook-none-'));
  assert.strictEqual(run(home, 'Stop'), '');
});

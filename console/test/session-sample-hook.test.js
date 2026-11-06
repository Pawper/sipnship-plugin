'use strict';
// The session sample's hook sends at every session start, and when a turn
// ends at most once a minute; each repository keeps its own mark. An agent
// starting or stopping is in session-sample-events.test.js.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const hook = path.join(__dirname, '..', '..', 'hooks', 'scripts', 'session-sample.sh');

/** A project whose remote is acme/shop; the service is unreachable, so a send ends at once. */
function project() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-hook-proj-'));
  execFileSync('git', ['init', '-q', dir]);
  execFileSync('git', ['-C', dir, 'remote', 'add', 'origin', 'git@github.com:acme/shop.git']);
  return dir;
}

/** Runs the hook for an event; returns the repository's mark it left. */
function run(home, event, dir = project()) {
  const input = JSON.stringify({ session_id: 'x', hook_event_name: event, cwd: dir });
  execFileSync('sh', [hook], { input, env: { ...process.env, SIPNSHIP_HOME: home, SIPNSHIP_URL: 'http://127.0.0.1:9', CLAUDE_PROJECT_DIR: dir }, stdio: ['pipe', 'pipe', 'ignore'] });
  try { return fs.readFileSync(path.join(home, 'brief-send', 'sample-at-acme-shop'), 'utf8').trim(); } catch { return ''; }
}

function connectedHome(mark) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-hook-home-'));
  fs.writeFileSync(path.join(home, 'tokens.json'), '{}');
  if (mark !== undefined) {
    fs.mkdirSync(path.join(home, 'brief-send'));
    fs.writeFileSync(path.join(home, 'brief-send', 'sample-at-acme-shop'), `${mark}\n`);
  }
  return home;
}

test('a turn ending sends when the last send was over a minute ago, and within the minute only behind the spacing', () => {
  const home = connectedHome(1000);
  const first = run(home, 'Stop');
  assert.notStrictEqual(first, '1000', 'a send over a minute after the last goes ahead');
  // Within the minute it reads the logs six seconds after the last and sends only a changed line (session-sample-events.test.js).
  assert.ok(Number(run(home, 'Stop')) >= Number(first) + 6, 'a second within the minute is set behind the first');
  const set = Math.floor(Date.now() / 1000) + 30;
  fs.writeFileSync(path.join(home, 'brief-send', 'sample-at-acme-shop'), `${set}\n`);
  assert.strictEqual(Number(run(home, 'Stop')), set, 'and one while a send is set is covered by it');
});

test('a session starting always sends', () => {
  const now = Math.floor(Date.now() / 1000);
  const home = connectedHome(now - 120);
  assert.ok(Number(run(home, 'SessionStart')) >= now);
});

test('a machine with no connection sends nothing and keeps no mark', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-hook-none-'));
  assert.strictEqual(run(home, 'Stop'), '');
});

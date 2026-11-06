'use strict';
// A session reports its model's full id as the runtime records it, and the
// effort level where the runtime records one; when either is not known it is
// left out, never guessed. Fixtures are sessions of Maya's rooftop-garden app.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const sessions = require('../sessions');
const { freshLog } = require('./fresh-log');

const fxDir = path.join(__dirname, '..', '..', 'tests', 'fixtures', 'sessions');
const read = (f) => sessions.readSession(fs.readFileSync(path.join(fxDir, f), 'utf8'), 'x');

test('a full model id with an effort level: both reported, the latest effort the session ran at', () => {
  const s = read('effort-session.jsonl');
  assert.strictEqual(s.model, 'claude-fable-5-1');
  assert.strictEqual(s.effort, 'low');
});

test('a model id with no effort recorded: the id, and no effort', () => {
  const s = read('model-only-session.jsonl');
  assert.strictEqual(s.model, 'claude-opus-5-5');
  assert.ok(!('effort' in s));
});

test('neither recorded: no model and no effort, never a guess', () => {
  const s = read('no-model-session.jsonl');
  assert.ok(!('model' in s), 'a synthetic reply names no model');
  assert.ok(!('effort' in s));
});

test('an agent whose log records no effort takes the level it was given in its meta file; its meta\'s short model name is never used', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-model-'));
  const sub = path.join(home, sessions.logFolder('/work/rooftop-garden'), '7c1e9a20-3b4d-4e5f-8a6b-1c2d3e4f5a6b', 'subagents');
  fs.mkdirSync(sub, { recursive: true });
  freshLog(path.join(fxDir, 'agent-running.jsonl'), path.join(sub, 'agent-e5f6a7b8c9d0e1f2a.jsonl'));
  fs.copyFileSync(path.join(fxDir, 'agent-running.meta.json'), path.join(sub, 'agent-e5f6a7b8c9d0e1f2a.meta.json'));
  const [s] = sessions.readSessions({ root: home, logsDir: home, worktrees: ['/work/rooftop-garden'], endedFile: path.join(home, 'none.tsv') });
  assert.strictEqual(s.effort, 'low');
  assert.strictEqual(s.model, 'claude-sonnet-5-5', 'the full id from its log, not "sonnet" from its meta');
});

test('an effort level is a short word only; anything else is no level', () => {
  assert.strictEqual(sessions.effortLevel('High'), 'high');
  assert.strictEqual(sessions.effortLevel('as much as it takes'), undefined);
  assert.strictEqual(sessions.effortLevel(3), undefined);
});

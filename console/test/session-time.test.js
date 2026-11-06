'use strict';
// A session's last activity and an agent's stop come from its log's own
// entries and the runtime's own record, never the log file's date: a runtime
// can rewrite every log's date at once without writing a word. Fixtures are
// agents of Maya's rooftop-garden app, one per case.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const sessions = require('../sessions');
const { freshLog } = require('./fresh-log');

const fxDir = path.join(__dirname, '..', '..', 'tests', 'fixtures', 'sessions');
const MAIN = '/work/rooftop-garden';
const PARENT = '7c1e9a20-3b4d-4e5f-8a6b-1c2d3e4f5a6b';

/** A log folder with one agent under the session that started it; returns its subagents folder. */
function agent(id, meta) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-time-'));
  const sub = path.join(home, sessions.logFolder(MAIN), PARENT, 'subagents');
  fs.mkdirSync(sub, { recursive: true });
  if (meta) fs.copyFileSync(path.join(fxDir, meta), path.join(sub, `agent-${id}.meta.json`));
  return { home, sub, file: path.join(sub, `agent-${id}.jsonl`) };
}
const sample = (a, now) => sessions.readSessions({ root: a.home, logsDir: a.home, worktrees: [MAIN], endedFile: path.join(a.home, 'none.tsv'), now });

test('a finished agent whose log date was rewritten just now, its last entry days old, is not in the sample', () => {
  const a = agent('c3d4e5f6a7b8c9d0e');
  fs.copyFileSync(path.join(fxDir, 'agent-finished-long-ago.jsonl'), a.file);
  fs.utimesSync(a.file, new Date(), new Date());
  assert.deepStrictEqual(sample(a), [], 'its file date is new, its last entry is from twelve days before');
  // Read on its own, its last activity is its last entry's time, never the file's.
  assert.strictEqual(sessions.readSession(fs.readFileSync(a.file, 'utf8'), 'x').lastActiveAt, '2026-10-24T16:45:00.000Z');
});

test('an agent the runtime marks finished carries endedAt, its last entry\'s time', () => {
  const a = agent('d4e5f6a7b8c9d0e1f', 'agent-finished.meta.json');
  const last = Date.now() - 20 * 60000;
  freshLog(path.join(fxDir, 'agent-finished.jsonl'), a.file, last);
  const [s] = sample(a);
  assert.strictEqual(s.session, 'agent-d4e5f6a7b8c9d0e1f');
  assert.strictEqual(s.lastActiveAt, new Date(last).toISOString());
  assert.strictEqual(s.endedAt, s.lastActiveAt, 'no stop hook saw it; the runtime\'s own mark says it finished');
});

test('an agent still running, no finished mark and a recent last entry, carries no endedAt', () => {
  const a = agent('e5f6a7b8c9d0e1f2a', 'agent-running.meta.json');
  const last = Date.now() - 2 * 60000;
  freshLog(path.join(fxDir, 'agent-running.jsonl'), a.file, last);
  const [s] = sample(a);
  assert.strictEqual(s.session, 'agent-e5f6a7b8c9d0e1f2a');
  assert.strictEqual(s.endedAt, undefined);
  assert.strictEqual(s.lastActiveAt, new Date(last).toISOString());
});

test('the two hours are judged by the last entry: an hour and fifty minutes is in, two hours and ten is out', () => {
  const a = agent('e5f6a7b8c9d0e1f2a', 'agent-running.meta.json');
  const last = Date.parse('2026-11-05T20:10:00.000Z');
  fs.copyFileSync(path.join(fxDir, 'agent-running.jsonl'), a.file);
  // Its file date is later than its last entry, as after a rewrite: only the entry decides.
  fs.utimesSync(a.file, new Date(last + 125 * 60000), new Date(last + 125 * 60000));
  assert.strictEqual(sample(a, last + 110 * 60000).length, 1);
  assert.strictEqual(sample(a, last + 130 * 60000).length, 0);
});

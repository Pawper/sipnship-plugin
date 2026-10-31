'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const sessions = require('../sessions');
const send = require('../brief-send');

const fx = path.join(__dirname, '..', '..', 'tests', 'fixtures', 'sessions', 'watering-session.jsonl');
const log = fs.readFileSync(fx, 'utf8');

test('a last line over twelve words is cut at twelve', () => {
  const long = 'one two three four five six seven eight nine ten eleven twelve thirteen fourteen';
  const cut = sessions.lastLine(long);
  assert.strictEqual(cut.replace('…', '').split(' ').length, 12);
  assert.ok(cut.endsWith('twelve…'));
  assert.strictEqual(sessions.lastLine('Reading the schedule screen first.'), 'Reading the schedule screen first.');
  assert.strictEqual(sessions.lastLine(''), '');
});

test('a session is read from its log: issues, model, start, branch, last line, tokens', () => {
  const s = sessions.readSession(log, 'abc');
  assert.deepStrictEqual(s.issues, [12, 14]);
  assert.strictEqual(s.model, 'claude-sonnet-5-5');
  assert.strictEqual(s.started, '2026-10-30T22:04:11.000Z');
  assert.strictEqual(s.branch, 'watering-schedule');
  assert.deepStrictEqual(s.worktree, { name: 'watering', path: '/work/rooftop-garden/worktrees/watering' });
  assert.strictEqual(s.lastLine.replace('…', '').split(' ').length, 12);
  assert.strictEqual(s.tokens, 1500 + 6600);
  assert.strictEqual(s.spend, undefined, 'spend is left out when the runtime does not report it');
  assert.strictEqual(s.startedWith, undefined);
});

test('a log with nothing in it is no session', () => {
  assert.strictEqual(sessions.readSession('not json\n', 'x'), undefined);
});

test('recent sessions of the repository\'s worktrees are sampled, with how they started', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-sess-'));
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-root-'));
  const tree = '/work/rooftop-garden/worktrees/watering';
  const folder = path.join(home, sessions.logFolder(tree));
  fs.mkdirSync(folder, { recursive: true });
  fs.writeFileSync(path.join(folder, 'abc.jsonl'), log);
  fs.mkdirSync(path.join(root, '.scratch', 'drive'), { recursive: true });
  fs.writeFileSync(path.join(root, '.scratch', 'drive', 'started-with.tsv'), 'watering\tround\n');
  const got = sessions.readSessions({ root, logsDir: home, worktrees: [tree] });
  assert.strictEqual(got.length, 1);
  assert.strictEqual(got[0].session, 'abc');
  assert.strictEqual(got[0].startedWith, 'round');
  // An old log is gone from the sample.
  const none = sessions.readSessions({ root, logsDir: home, worktrees: [tree], now: Date.now() + 3 * 3600 * 1000 });
  assert.deepStrictEqual(none, []);
});

test('the brief carries the sessions, each last line cut, and none when there are none', () => {
  const long = { session: 's', started: '2026-10-30T22:04:11.000Z', lastLine: 'a b c d e f g h i j k l m n o' };
  const b = send.briefBody('Main: ok', { now: new Date('2026-10-31T01:00:00Z'), machine: 'desk', sessions: [long] });
  assert.strictEqual(b.sessions.length, 1);
  assert.strictEqual(b.sessions[0].lastLine.replace('…', '').split(' ').length, 12);
  assert.strictEqual(send.briefBody('Main: ok', { machine: 'desk', sessions: [] }).sessions, undefined);
});

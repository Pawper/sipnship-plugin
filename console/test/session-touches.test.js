'use strict';
// Each issue or pull request a session touched, with the first and last time
// it touched it. A touch is an entry naming the number: a message from the
// person, or a command or agent task the session ran. Its own issues are
// touched by every entry. Fixtures are sessions of Maya's rooftop-garden app.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const sessions = require('../sessions');
const touches = require('../session-touches');

const fxDir = path.join(__dirname, '..', '..', 'tests', 'fixtures', 'sessions');

/** The sample of one log, read at a time just after its last entry. */
function sampleOf(fixture, { tree, sub, name, now }) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-touch-'));
  const folder = path.join(home, sessions.logFolder(tree), ...(sub ? [sub, 'subagents'] : []));
  fs.mkdirSync(folder, { recursive: true });
  const file = path.join(folder, `${name}.jsonl`);
  fs.writeFileSync(file, fixture.endsWith('.jsonl') ? fs.readFileSync(path.join(fxDir, fixture), 'utf8') : fixture);
  fs.utimesSync(file, new Date(now), new Date(now));
  return sessions.readSessions({ root: home, logsDir: home, worktrees: [tree], endedFile: path.join(home, 'none.tsv'), now });
}

test('a one-issue agent touched its own issue from its start to its last entry', () => {
  const [s] = sampleOf('one-issue-agent.jsonl', { tree: '/work/rooftop-garden', sub: '7c1e9a20-3b4d-4e5f-8a6b-1c2d3e4f5a6b', name: 'agent-b2c3d4e5f6a7b8c9d', now: Date.parse('2026-11-05T17:45:00.000Z') });
  assert.deepStrictEqual(s.issues, [214]);
  assert.deepStrictEqual(s.touched, [{ number: 214, first: '2026-11-05T17:00:00.000Z', last: '2026-11-05T17:40:00.000Z' }]);
});

test('a session that touched three issues an hour apart: one span each, newest first', () => {
  const [s] = sampleOf('three-issues-session.jsonl', { tree: '/work/rooftop-garden', name: '7c1e9a20-3b4d-4e5f-8a6b-1c2d3e4f5a6b', now: Date.parse('2026-11-05T18:15:00.000Z') });
  assert.deepStrictEqual(s.touched, [
    { number: 33, first: '2026-11-05T18:05:00.000Z', last: '2026-11-05T18:05:00.000Z' },
    { number: 32, first: '2026-11-05T17:05:00.000Z', last: '2026-11-05T17:05:00.000Z' },
    { number: 31, first: '2026-11-05T16:05:00.000Z', last: '2026-11-05T16:20:00.000Z' },
  ], 'what it read back (#40), what it said (#41), a reminder in a message (#42) and a file it wrote are not touches');
  assert.strictEqual(s.lastActiveAt, '2026-11-05T18:10:00.000Z');
  assert.strictEqual(s.effort, 'medium');
});

test('an issue named only by its branch is its own: touched from its start to its last entry', () => {
  const [s] = sampleOf('model-only-session.jsonl', { tree: '/work/rooftop-garden/worktrees/seeds', name: 'seeds', now: Date.parse('2026-11-05T19:10:00.000Z') });
  assert.deepStrictEqual(s.touched, [{ number: 33, first: '2026-11-05T19:00:00.000Z', last: '2026-11-05T19:05:00.000Z' }]);
});

test('a session the person opened is not given the issues its first message names: that message touches them once', () => {
  const log = [
    { type: 'user', timestamp: '2026-11-05T16:00:00.000Z', cwd: '/work/rooftop-garden', gitBranch: 'main', message: { content: 'Rounds today: #31 first, then #32.' } },
    { type: 'assistant', timestamp: '2026-11-05T17:00:00.000Z', cwd: '/work/rooftop-garden', gitBranch: 'main', message: { model: 'claude-opus-5-5', content: [{ type: 'text', text: 'Both are moving.' }] } },
  ].map((e) => JSON.stringify(e)).join('\n');
  const [s] = sampleOf(log, { tree: '/work/rooftop-garden', name: 'rounds', now: Date.parse('2026-11-05T17:05:00.000Z') });
  assert.deepStrictEqual(s.issues, [31, 32], 'the issues it names, as before');
  assert.deepStrictEqual(s.touched.map((t) => [t.number, t.first, t.last]), [[31, '2026-11-05T16:00:00.000Z', '2026-11-05T16:00:00.000Z'], [32, '2026-11-05T16:00:00.000Z', '2026-11-05T16:00:00.000Z']]);
});

test('a session that touched nothing carries no spans', () => {
  const quiet = JSON.stringify({ type: 'user', timestamp: '2026-11-05T19:00:00.000Z', cwd: '/work/rooftop-garden', gitBranch: 'main', message: { content: 'Tidy the plant names.' } });
  const [s] = sampleOf(quiet, { tree: '/work/rooftop-garden', name: 'tidy', now: Date.parse('2026-11-05T19:10:00.000Z') });
  assert.strictEqual(s.session, 'tidy');
  assert.ok(!('touched' in s));
});

test('the numbers a command or message names', () => {
  assert.deepStrictEqual(touches.namedIn('gh api repos/maya/rooftop-garden/issues/31/comments'), [31]);
  assert.deepStrictEqual(touches.namedIn('gh pr view 33 --json title; see #32'), [32, 33]);
  assert.deepStrictEqual(touches.namedIn('gh api repos/maya/rooftop-garden/pulls/7/files'), [7]);
  assert.deepStrictEqual(touches.namedIn('a colour &#38; c#12'), []);
});

test('at most ten spans, the most recently touched kept', () => {
  const m = new Map();
  for (let n = 1; n <= 15; n++) m.set(n, { first: n * 1000, last: n * 1000 });
  const got = touches.spans([], m, 0, 0);
  assert.strictEqual(got.length, touches.SPANS_MAX);
  assert.strictEqual(got[0].number, 15);
});

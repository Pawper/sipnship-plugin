'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const http = require('http');
const path = require('path');
const tokens = require('../tokens');
const send = require('../brief-send');
const questions = require('../questions');

const scratch = () => { const d = path.join(__dirname, '..', '..', '..', '.scratch'); fs.mkdirSync(d, { recursive: true }); return d; };
const T = 'sns_repo_' + 'B'.repeat(43);
const now = new Date();
const asked = { id: 'q1', card: 'pull:187', name: 'Reminders for each bed', words: 'why did you choose this?', askedAt: new Date(now.getTime() - 72 * 60 * 1000).toISOString() };

function fake(replies) {
  const seen = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (d) => (body += d)).on('end', () => {
      seen.push({ url: req.url, body });
      const r = replies[Math.min(seen.length - 1, replies.length - 1)];
      res.writeHead(r.status, { 'content-type': 'application/json' });
      res.end(r.body || '');
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, seen, url: `http://127.0.0.1:${server.address().port}` })));
}
function envWith(url) {
  const env = { SIPNSHIP_HOME: fs.mkdtempSync(path.join(scratch(), 'sns-questions-')), SIPNSHIP_URL: url };
  tokens.put({ repoId: 42, fullName: 'maya/rooftop-garden', token: T, machine: 'desk' }, env);
  return env;
}

test('a question goes to the session that worked on its card, by the issue or branch that names it', () => {
  const sample = [{ session: 's-other', issues: [12] }, { session: 's-work', issues: [187], branch: 'reminders' }, { session: 's-branch', branch: 'worktree-pull-188' }];
  assert.strictEqual(questions.workedOn('pull:187', sample), 's-work');
  assert.strictEqual(questions.workedOn('pull:188', sample), 's-branch');
  assert.strictEqual(questions.workedOn('pull:1870', sample), undefined);
  assert.strictEqual(questions.workedOn('card:failed', sample), undefined);
});

test('a brief\'s reply hands the question to the session that worked on it, and to the next session when that one is gone', async () => {
  const f = await fake([{ status: 200, body: JSON.stringify({ questions: [asked] }) }, { status: 204 }, { status: 204 }]);
  try {
    const env = envWith(f.url);
    const live = [{ session: 's-work', issues: [187] }];
    // A session that did not work on it hears nothing while the one that did is still around.
    assert.strictEqual(await send.sendBrief({ text: 'Main: green', session: 's-new', repo: 'maya/rooftop-garden', env, now, sessions: live }), '');
    const mine = await send.sendBrief({ text: 'Main: green', session: 's-work', repo: 'maya/rooftop-garden', env, now, sessions: live });
    assert.match(mine, /Reminders for each bed/);
    assert.match(mine, /why did you choose this\?/);
    assert.match(mine, /--answer q1/);
    // It is said to that session once.
    assert.strictEqual(await send.sendBrief({ text: 'Main: green', session: 's-work', repo: 'maya/rooftop-garden', env, now, sessions: live }), '');
    // With nobody left who worked on the card, the next session to start hears it.
    const env2 = envWith(f.url);
    questions.receive(env2, 42, [asked], [], now.getTime());
    const next = await send.sendBrief({ text: 'Main: green', session: 's-later', repo: 'maya/rooftop-garden', env: env2, now, sessions: [] });
    assert.match(next, /Reminders for each bed/);
  } finally { f.server.close(); }
});

test('an answer waits for the next brief, goes up with it once, and the question is not asked again', async () => {
  const f = await fake([{ status: 204 }]);
  try {
    const env = envWith(f.url);
    questions.receive(env, 42, [asked], [], now.getTime());
    assert.strictEqual(questions.answer(env, 42, 'nope', 'x'), false);
    assert.strictEqual(questions.answer(env, 42, 'q1', '  The snooze rule needed a database step first. '), true);
    await send.sendBrief({ text: 'Main: green', session: 's1', repo: 'maya/rooftop-garden', env, now });
    const sent = JSON.parse(f.seen[0].body);
    assert.deepStrictEqual(sent.answers, [{ id: 'q1', say: 'The snooze rule needed a database step first.' }]);
    assert.deepStrictEqual(questions.pendingAnswers(env, 42), []);
    // The service may hand the same question again before it has closed it; it is not asked twice.
    questions.receive(env, 42, [asked], [], now.getTime());
    assert.deepStrictEqual(questions.load(env, 42, now.getTime()).questions, []);
  } finally { f.server.close(); }
});

test('a question older than a day is let go quietly', () => {
  const env = envWith('http://127.0.0.1:1');
  const s = questions.receive(env, 42, [{ ...asked, askedAt: '2026-11-01T10:00:00Z' }], [], now.getTime());
  assert.deepStrictEqual(s.questions, []);
});

test('a reply that is not readable says nothing and the brief still counts as sent', async () => {
  const f = await fake([{ status: 200, body: 'not json' }]);
  try {
    const env = envWith(f.url);
    assert.strictEqual(await send.sendBrief({ text: 'Main: green', session: 's1', repo: 'maya/rooftop-garden', env, now }), '');
  } finally { f.server.close(); }
});

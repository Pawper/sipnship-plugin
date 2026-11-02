'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const report = require('../refusal-report');
const send = require('../brief-send');
const { project, envFor, fake, keep, NOW, TOKEN } = require('./refusal-helpers');

const IDS = ['2026-11-02T16:10:00Z-4121', '2026-11-02T16:40:00Z-4377', '2026-11-02T16:50:00Z-4390'];
const sent = (root) => { try { return fs.readFileSync(path.join(root, '.scratch', 'hooks', 'sent'), 'utf8').trim(); } catch { return ''; } };
const run = (root, env, session = 'sess-maya-1') => report.sendNow({ root, repo: 'acme/garden', session, env, now: NOW });

test('at a turn\'s end with something settled, one request carries it, and the cursor moves', async () => {
  const f = await fake([keep(IDS)]);
  const root = project();
  const line = await run(root, envFor(f.url));
  f.server.close();
  assert.strictEqual(f.seen.length, 1);
  assert.strictEqual(f.seen[0].url, '/v1/repos/42/refusals');
  assert.strictEqual(f.seen[0].method, 'POST');
  assert.strictEqual(f.seen[0].auth, `Bearer ${TOKEN}`);
  assert.deepStrictEqual(JSON.parse(f.seen[0].body).reports.map((r) => r.id), IDS);
  assert.strictEqual(sent(root), IDS[2]);
  assert.match(line, /^This machine now also tells SipNShip/);
});

test('with nothing new, none; with no token or reports off, none', async () => {
  const f = await fake([keep(IDS)]);
  const root = project();
  fs.mkdirSync(path.join(root, '.scratch', 'hooks'));
  fs.writeFileSync(path.join(root, '.scratch', 'hooks', 'sent'), `${IDS[2]}\n`);
  assert.strictEqual(await run(root, envFor(f.url)), '');
  assert.strictEqual(await run(project(), envFor(f.url, false)), '');
  assert.strictEqual(await run(project(), envFor(f.url, true, { HOOK_LOG: '0' })), '');
  assert.strictEqual(f.seen.length, 0);
  f.server.close();
});

test('a failure leaves the cursor and is said once per session; the next send carries the reports again', async () => {
  const f = await fake([{ status: 503 }, { status: 503 }, keep(IDS)]);
  const root = project();
  const env = envFor(f.url);
  assert.match(await run(root, env), /^Could not reach SipNShip/);
  assert.strictEqual(sent(root), '');
  assert.strictEqual(await run(root, env), '');
  assert.strictEqual(sent(root), '');
  // another session says it again; this one's request is answered
  await run(root, env, 'sess-maya-2');
  assert.strictEqual(sent(root), IDS[2]);
  assert.deepStrictEqual(JSON.parse(f.seen[2].body).reports.map((r) => r.id), IDS);
  f.server.close();
});

test('a send nobody answers within three seconds is a failure, not a wait', async () => {
  const f = await fake([{ status: 200, body: { ids: IDS }, delay: 5000 }]);
  const root = project();
  const t = Date.now();
  assert.match(await run(root, envFor(f.url)), /^Could not reach/);
  assert.ok(Date.now() - t < 4500);
  assert.strictEqual(sent(root), '');
  f.server.close();
});

test('a refusal as unreadable is said once and never resent', async () => {
  const f = await fake([{ status: 400, body: { code: 'bad_report' } }]);
  const root = project();
  assert.strictEqual(await run(root, envFor(f.url)), report.LINES.bad);
  assert.strictEqual(sent(root), IDS[2]);
  assert.strictEqual(await run(root, envFor(f.url)), '');
  assert.strictEqual(f.seen.length, 1);
  f.server.close();
});

test('the next brief carries what was not acknowledged, and its reply moves the cursor', async () => {
  const f = await fake([{ status: 503 }, { status: 200, body: { refusals: IDS } }]);
  const root = project();
  const env = envFor(f.url);
  await run(root, env);
  assert.strictEqual(sent(root), '');
  const line = await send.sendBrief({ text: 'Session brief.\nMain: ok\n', session: 'next', repo: 'acme/garden', env, now: new Date(NOW), root });
  const body = JSON.parse(f.seen[1].body);
  assert.strictEqual(f.seen[1].url, '/v1/repos/42/brief');
  assert.deepStrictEqual(body.refusals.map((r) => r.id), IDS);
  assert.strictEqual(sent(root), IDS[2]);
  assert.match(line, /^This machine now also tells SipNShip/);
  // acknowledged: the following brief carries none
  const again = await send.sendBrief({ text: 'Session brief.\nMain: ok\n', session: 'later', repo: 'acme/garden', env, now: new Date(NOW + 10000), root });
  assert.strictEqual(JSON.parse(f.seen[2].body).refusals, undefined);
  assert.strictEqual(again, '');
  f.server.close();
});

test('a brief never grows past its limit for the reports it carries', async () => {
  const root = project();
  const hooks = []; const resolved = [];
  for (let i = 0; i < 200; i++) {
    const t = `2026-11-02T16:${String(10 + Math.floor(i / 60)).padStart(2, '0')}:${String(i % 60).padStart(2, '0')}Z`;
    hooks.push(`${t}\tblock-delete\tsess-maya-1\t${t}-${1000 + i}`);
    resolved.push(`${t}\t${t}-${1000 + i}\tblock-delete\tsess-maya-1\tworkaround\t10\t5\tfile edit`);
  }
  fs.writeFileSync(path.join(root, '.scratch', 'hooks.log'), hooks.join('\n') + '\n');
  fs.writeFileSync(path.join(root, '.scratch', 'hooks-resolved.log'), resolved.join('\n') + '\n');
  const body = { cards: [{ say: 'x'.repeat(30000) }] };
  const put = report.attach(body, { root, repoId: 42, env: {}, now: NOW, maxBytes: send.SEND_MAX_BYTES });
  assert.ok(put.length > 0 && put.length <= 200);
  assert.ok(Buffer.byteLength(JSON.stringify(body)) <= send.SEND_MAX_BYTES);
  assert.deepStrictEqual(put.map((r) => r.id), body.refusals.map((r) => r.id));
});

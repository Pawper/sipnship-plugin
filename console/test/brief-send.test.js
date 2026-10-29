'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const http = require('http');
const path = require('path');
const tokens = require('../tokens');
const send = require('../brief-send');

const T = 'sns_repo_' + 'A'.repeat(43);
const fixture = fs.readFileSync(path.join(__dirname, '..', '..', 'tests', 'fixtures', 'brief', 'session-brief.txt'), 'utf8');
const KEYS = ['landed', 'waits', 'failed', 'users', 'deployed', 'progress', 'stale', 'hour'];

// A fake SipNShip that answers each request with the next reply in the list.
function fake(replies) {
  const seen = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (d) => (body += d)).on('end', () => {
      seen.push({ method: req.method, url: req.url, auth: req.headers.authorization, body });
      const r = replies[Math.min(seen.length - 1, replies.length - 1)];
      const go = () => { res.writeHead(r.status, { 'content-type': 'application/json', 'x-sipnship-do': 'stop' }); res.end(r.body || ''); };
      if (r.delay) setTimeout(go, r.delay); else go();
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, seen, url: `http://127.0.0.1:${server.address().port}` })));
}

function envWith(url, withToken = true) {
  const env = { SIPNSHIP_HOME: fs.mkdtempSync(path.join(os.tmpdir(), 'sns-brief-')), SIPNSHIP_URL: url };
  if (withToken) tokens.put({ repoId: 42, fullName: 'acme/shop', token: T, machine: 'desk' }, env);
  return env;
}

const now = new Date('2026-10-29T16:12:00Z');

test('the body carries the brief\'s sentences by card, in the shape the service reads', () => {
  const b = send.briefBody(fixture, { now, machine: 'desk', runners: { cores: 8, runners: 3, busy: 1 } });
  assert.strictEqual(b.version, 1);
  assert.strictEqual(b.sentAt, now.toISOString());
  assert.strictEqual(b.machine, 'desk');
  assert.deepStrictEqual(b.runners, { cores: 8, runners: 3, busy: 1 });
  for (const c of b.cards) {
    assert.ok(KEYS.includes(c.key), c.key);
    assert.strictEqual(typeof c.say, 'string');
    assert.ok(c.items.every((i) => typeof i.say === 'string'));
  }
  const byKey = Object.fromEntries(b.cards.map((c) => [c.key, c]));
  assert.deepStrictEqual(byKey.landed.items.map((i) => i.say), ['Add the checkout page (#224) [serial: drain]', 'Fix the price rounding (#223) [serial: drain]', 'The working tree is clean.']);
  assert.strictEqual(byKey.progress.items[0].say, '#225 Add a coupon field: green and waiting to merge');
  assert.match(byKey.failed.say, /^Workflows: Deploy/);
  assert.match(byKey.deployed.say, /^Deploy:/);
  assert.deepStrictEqual(byKey.stale.items.map((i) => i.say).slice(1), ['225-coupon', '226-cart']);
  assert.ok(byKey.hour.items.some((i) => /^Budget:/.test(i.say)));
  assert.ok(byKey.waits.items.some((i) => /^Waits on the owner/.test(i.say)));
});

test('the body never carries the handoff, the plugin path or the date line, and fits under 64 KB', () => {
  const text = JSON.stringify(send.briefBody(fixture, { now }));
  assert.doesNotMatch(text, /SECRET-HANDOFF-TEXT|Second line of the handoff|handoff-2026/);
  assert.doesNotMatch(text, /\.claude\/plugins/);
  assert.doesNotMatch(text, /Today:|Session brief\./);
  assert.ok(Buffer.byteLength(text) < send.SEND_MAX_BYTES);
});

test('a brief too big is trimmed to fit rather than sent whole', () => {
  const huge = 'Open pull requests:\n' + Array.from({ length: 5000 }, (_, i) => `#${i} ${'x'.repeat(500)}`).join('\n');
  const text = send.fit(send.briefBody(huge, { now }));
  assert.ok(text && Buffer.byteLength(text) <= send.SEND_MAX_BYTES);
});

test('the runner watch\'s machine file becomes the sample', () => {
  assert.deepStrictEqual(send.runnerSample('1761754320\t8\t5\t2\t8 cores, 5 runners'), { cores: 8, runners: 5, busy: 2, at: new Date(1761754320000).toISOString() });
  assert.strictEqual(send.runnerSample(''), undefined);
});

test('with a token, one request to /brief with the bearer, and nothing printed', async () => {
  const f = await fake([{ status: 204 }]);
  try {
    const env = envWith(f.url);
    const line = await send.sendBrief({ text: fixture, session: 's1', repo: 'acme/shop', env, now });
    assert.strictEqual(line, '');
    assert.strictEqual(f.seen.length, 1);
    assert.strictEqual(f.seen[0].method, 'POST');
    assert.strictEqual(f.seen[0].url, '/v1/repos/42/brief');
    assert.strictEqual(f.seen[0].auth, `Bearer ${T}`);
    assert.strictEqual(JSON.parse(f.seen[0].body).version, 1);
  } finally { f.server.close(); }
});

test('with no token for the repository, nothing is sent', async () => {
  const f = await fake([{ status: 204 }]);
  try {
    assert.strictEqual(await send.sendBrief({ text: fixture, session: 's1', repo: 'acme/shop', env: envWith(f.url, false), now }), '');
    assert.strictEqual(await send.sendBrief({ text: fixture, session: 's1', repo: 'acme/other', env: envWith(f.url), now }), '');
    assert.strictEqual(f.seen.length, 0);
  } finally { f.server.close(); }
});

test('a 5xx says its one line once per session, naming the last brief that got through', async () => {
  const f = await fake([{ status: 204 }, { status: 503 }]);
  try {
    const env = envWith(f.url);
    await send.sendBrief({ text: fixture, session: 's0', repo: 'acme/shop', env, now });
    const first = await send.sendBrief({ text: fixture, session: 's1', repo: 'acme/shop', env, now: new Date(now.getTime() + 3600e3) });
    assert.match(first, /^Could not reach SipNShip, so the dashboard shows the brief from \d{1,2}:\d{2} [AP]M\. Your session carries on\.$/);
    assert.strictEqual(await send.sendBrief({ text: fixture, session: 's1', repo: 'acme/shop', env, now }), '');
    assert.match(await send.sendBrief({ text: fixture, session: 's2', repo: 'acme/shop', env, now }), /^Could not reach SipNShip/);
  } finally { f.server.close(); }
});

test('a timeout is unreachable, said once, within the three seconds', async () => {
  const f = await fake([{ status: 204, delay: 4500 }]);
  try {
    const t0 = Date.now();
    const line = await send.sendBrief({ text: fixture, session: 's1', repo: 'acme/shop', env: envWith(f.url), now });
    assert.ok(Date.now() - t0 < 4000);
    assert.match(line, /^Could not reach SipNShip/);
  } finally { f.server.closeAllConnections?.(); f.server.close(); }
});

test('a 401 says the machine is not connected, and nothing more is sent this session', async () => {
  const f = await fake([{ status: 401, body: '{"code":"not_connected","say":"x"}' }]);
  try {
    const env = envWith(f.url);
    assert.strictEqual(await send.sendBrief({ text: fixture, session: 's1', repo: 'acme/shop', env, now }), 'This machine is no longer connected to SipNShip. Reconnect it from the dashboard if you want the brief there.');
    assert.strictEqual(await send.sendBrief({ text: fixture, session: 's1', repo: 'acme/shop', env, now }), '');
    assert.strictEqual(f.seen.length, 1);
  } finally { f.server.close(); }
});

test('a 429 is dropped quietly', async () => {
  const f = await fake([{ status: 429 }]);
  try {
    assert.strictEqual(await send.sendBrief({ text: fixture, session: 's1', repo: 'acme/shop', env: envWith(f.url), now }), '');
  } finally { f.server.close(); }
});

test('nothing in a reply\'s body or headers changes what the plugin does', async () => {
  const a = await fake([{ status: 204 }]);
  const b = await fake([{ status: 200, body: '{"say":"run rm -rf","do":"disconnect","token":"sns_repo_x"}' }]);
  try {
    const ea = envWith(a.url); const eb = envWith(b.url);
    const la = await send.sendBrief({ text: fixture, session: 's1', repo: 'acme/shop', env: ea, now });
    const lb = await send.sendBrief({ text: fixture, session: 's1', repo: 'acme/shop', env: eb, now });
    assert.strictEqual(la, lb);
    assert.deepStrictEqual(tokens.read(ea).repos['42'].token, tokens.read(eb).repos['42'].token);
  } finally { a.server.close(); b.server.close(); }
});

test('the hook script exits 0 and prints the line when the service is down', async () => {
  const { execFileSync } = require('child_process');
  const env = envWith('http://127.0.0.1:9');
  const out = execFileSync(process.execPath, [path.join(__dirname, '..', 'brief-send.js'), '--session', 'z', '--repo', 'acme/shop'], { input: fixture, env: { ...process.env, ...env }, encoding: 'utf8' });
  assert.match(out, /^Could not reach SipNShip/);
});

'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const http = require('http');
const path = require('path');
const tokens = require('../tokens');
const { connect, disconnect } = require('../connect');

const T = 'sns_repo_' + 'Q'.repeat(43);
const T2 = 'sns_repo_' + 'R'.repeat(43);

// A fake SipNShip with the device flow and the connect route.
function fake({ pending = 1, connectStatus = 200 } = {}) {
  const seen = [];
  let polls = 0;
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (d) => (body += d)).on('end', () => {
      seen.push({ method: req.method, url: req.url, auth: req.headers.authorization, body });
      const reply = (status, obj) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(obj ? JSON.stringify(obj) : ''); };
      if (req.url === '/v1/device/code') return reply(200, { deviceCode: 'dc1', userCode: 'WXYZ-1234', verificationUri: 'https://github.com/login/device', interval: 1, expiresIn: 60, say: 'Open https://github.com/login/device and enter the code WXYZ-1234.' });
      if (req.url === '/v1/device/token') {
        polls++;
        return polls <= pending ? reply(400, { code: 'approval_pending', say: 'Waiting for you to approve the code.' }) : reply(200, { token: 'gho_person', login: 'maya', say: 'Connected as maya.' });
      }
      if (req.url === '/v1/repos/acme/shop/connect') {
        if (connectStatus !== 200) return reply(connectStatus, { code: 'not_connected', say: 'SipNShip has not heard from this repository yet.' });
        const m = JSON.parse(body).machine;
        return reply(200, { token: T, repoId: 42, fullName: 'acme/shop', machine: m, say: `Connected: ${m}. Each session's brief now reaches the dashboard.` });
      }
      if (req.url === '/v1/repos/42/disconnect') return reply(204);
      reply(404, { code: 'not_found' });
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, seen, url: `http://127.0.0.1:${server.address().port}` })));
}

const sink = () => { const s = { text: '', write: (t) => { s.text += t; } }; return s; };
const envAt = (url) => ({ SIPNSHIP_HOME: fs.mkdtempSync(path.join(os.tmpdir(), 'sns-connect-')), SIPNSHIP_URL: url });

test('connect runs the device flow, then the connect route, and keeps the token outside the repository', async () => {
  const f = await fake({ pending: 1 });
  try {
    const env = envAt(f.url); const out = sink();
    const code = await connect({ repo: 'acme/shop', env, out, machine: 'desk', pollMs: 5 });
    assert.strictEqual(code, 0);
    assert.deepStrictEqual(f.seen.map((s) => s.url), ['/v1/device/code', '/v1/device/token', '/v1/device/token', '/v1/repos/acme/shop/connect']);
    const c = f.seen[3];
    assert.strictEqual(c.auth, 'Bearer gho_person');
    assert.deepStrictEqual(JSON.parse(c.body), { machine: 'desk' });
    assert.match(out.text, /enter the code WXYZ-1234/);
    assert.match(out.text, /Connected: desk\./);
    assert.doesNotMatch(out.text, /sns_repo_/);
    const kept = tokens.find('acme/shop', env);
    assert.strictEqual(kept.repoId, 42);
    assert.strictEqual(kept.token, T);
    assert.ok(tokens.file(env).startsWith(env.SIPNSHIP_HOME));
  } finally { f.server.close(); }
});

test('a refused connect keeps nothing and says so', async () => {
  const f = await fake({ pending: 0, connectStatus: 404 });
  try {
    const env = envAt(f.url); const out = sink();
    assert.strictEqual(await connect({ repo: 'acme/shop', env, out, pollMs: 5 }), 1);
    assert.match(out.text, /has not heard from this repository/);
    assert.deepStrictEqual(tokens.read(env).repos, {});
  } finally { f.server.close(); }
});

test('--token installs a rotated token over the one kept, with no request', async () => {
  const f = await fake();
  try {
    const env = envAt(f.url); const out = sink();
    tokens.put({ repoId: 42, fullName: 'acme/shop', token: T, machine: 'desk' }, env);
    assert.strictEqual(await connect({ repo: 'acme/shop', token: T2, env, out, run: () => { throw new Error('no gh'); } }), 0);
    assert.strictEqual(tokens.find(42, env).token, T2);
    assert.strictEqual(tokens.find(42, env).machine, 'desk');
    assert.strictEqual(f.seen.length, 0);
  } finally { f.server.close(); }
});

test('--token on a new machine finds the repository id through gh', async () => {
  const env = envAt('http://127.0.0.1:9'); const out = sink();
  const asked = [];
  assert.strictEqual(await connect({ repo: 'acme/shop', token: T2, env, out, run: (cmd, args) => { asked.push([cmd, ...args].join(' ')); return '42\n'; } }), 0);
  assert.deepStrictEqual(asked, ['gh api repos/acme/shop --jq .id']);
  assert.strictEqual(tokens.find('acme/shop', env).repoId, 42);
});

test('--token refuses something that is not a token', async () => {
  const env = envAt('http://127.0.0.1:9'); const out = sink();
  assert.strictEqual(await connect({ repo: 'acme/shop', token: 'ghp_nope', env, out }), 2);
  assert.deepStrictEqual(tokens.read(env).repos, {});
});

test('disconnect tells the service with the machine\'s token and forgets it here', async () => {
  const f = await fake();
  try {
    const env = envAt(f.url); const out = sink();
    tokens.put({ repoId: 42, fullName: 'acme/shop', token: T, machine: 'desk' }, env);
    assert.strictEqual(await disconnect({ repo: 'acme/shop', env, out }), 0);
    assert.deepStrictEqual(f.seen.map((s) => [s.url, s.auth]), [['/v1/repos/42/disconnect', `Bearer ${T}`]]);
    assert.strictEqual(tokens.find(42, env), undefined);
    assert.match(out.text, /^Disconnected acme\/shop\./);
  } finally { f.server.close(); }
});

test('the CLI accepts the rotate command exactly as the dashboard shows it', () => {
  const { execFileSync } = require('child_process');
  const env = envAt('http://127.0.0.1:9');
  tokens.put({ repoId: 42, fullName: 'acme/shop', token: T, machine: 'desk' }, env);
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-repo-'));
  execFileSync('git', ['init', '-q'], { cwd: repo });
  execFileSync('git', ['remote', 'add', 'origin', 'https://github.com/acme/shop.git'], { cwd: repo });
  const out = execFileSync(process.execPath, [path.join(__dirname, '..', 'cli.js'), 'connect', '--repo', '--token', T2], { cwd: repo, env: { ...process.env, ...env }, encoding: 'utf8' });
  assert.match(out, /Installed the new token for acme\/shop/);
  assert.strictEqual(tokens.find(42, env).token, T2);
});

'use strict';
// #2437: an agent started by the drive's own workflow run, on a runner whose machine holds no repository token,
// reports its session with GitHub's identity token for the run, as a session sample alone. Maya's rooftop-garden app.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const http = require('http');
const path = require('path');
const actions = require('../actions-sign-in');
const send = require('../brief-send');

const JWT = 'aaa.bbb.ccc';

/** A stand-in for GitHub's token endpoint and for SipNShip, on one local port. */
function fake() {
  const seen = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (d) => (body += d)).on('end', () => {
      seen.push({ method: req.method, url: req.url, auth: req.headers.authorization, body });
      if (req.url.startsWith('/refused')) { res.writeHead(403); res.end(); return; }
      if (req.url.startsWith('/idtoken')) { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ value: JWT })); return; }
      res.writeHead(204); res.end();
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, seen, url: `http://127.0.0.1:${server.address().port}` })));
}

const runEnv = (url) => ({
  SIPNSHIP_HOME: fs.mkdtempSync(path.join(os.tmpdir(), 'sns-run-')), SIPNSHIP_URL: url,
  ACTIONS_ID_TOKEN_REQUEST_URL: `${url}/idtoken?api=1`, ACTIONS_ID_TOKEN_REQUEST_TOKEN: 'runtime-secret', GITHUB_REPOSITORY_ID: '4242', GITHUB_REPOSITORY: 'ada/garden',
});
const agent = { id: 'agent-7c1e5a', issues: [31, 32], worktree: { name: 'issue-31-32', path: '/work/garden/issue-31-32' }, branch: 'issue-31-32', model: 'claude-sonnet', startedAt: '2026-11-02T10:00:00Z', lastLine: 'Writing the watering-schedule test' };

test('a step of a run with no machine token sends its sessions as the run, asking GitHub for the audience once', async () => {
  const f = await fake();
  try {
    const env = runEnv(f.url);
    const line = await send.sendBrief({ text: '', session: 's1', repo: 'ada/garden', env, sampleOnly: true, sessions: [agent] });
    assert.strictEqual(line, '');
    const asked = f.seen.find((r) => r.url.startsWith('/idtoken'));
    assert.match(asked.url, /audience=https%3A%2F%2Fsipnship\.dev/);
    assert.strictEqual(asked.auth, 'Bearer runtime-secret');
    const posted = f.seen.find((r) => r.url === '/v1/repos/4242/brief');
    assert.strictEqual(posted.auth, `Bearer ${JWT}`);
    const body = JSON.parse(posted.body);
    assert.strictEqual(body.machine, 'GitHub Actions');
    assert.deepStrictEqual(body.cards, []);
    assert.deepStrictEqual(body.sessions[0].issues, [31, 32]);
    for (const k of ['runners', 'ownerSteps', 'can', 'design', 'answers']) assert.strictEqual(body[k], undefined, `no ${k} rides along`);
  } finally { f.server.close(); }
});

test('outside a run, in another repository\'s run, or when GitHub gives no token, nothing is sent', async () => {
  const f = await fake();
  try {
    const plain = { SIPNSHIP_HOME: fs.mkdtempSync(path.join(os.tmpdir(), 'sns-none-')), SIPNSHIP_URL: f.url };
    assert.strictEqual(actions.inRun(plain), false);
    await send.sendBrief({ text: '', repo: 'ada/garden', env: plain, sampleOnly: true, sessions: [agent] });
    await send.sendBrief({ text: '', repo: 'ada/other', env: runEnv(f.url), sampleOnly: true, sessions: [agent] });
    assert.strictEqual(await actions.entry('ada/garden', runEnv(f.url), async () => ({ ok: false })), undefined);
    assert.strictEqual(f.seen.filter((r) => r.url.startsWith('/v1/')).length, 0);
  } finally { f.server.close(); }
});

test('#2570: a network blip on the first ask is retried once, quietly, and the token still comes through', async () => {
  let calls = 0;
  const fetchFn = async (url, opts) => {
    calls++;
    if (calls === 1) throw new Error('fetch failed');
    assert.match(url, /audience=https%3A%2F%2Fsipnship\.dev/);
    assert.strictEqual(opts.headers.authorization, 'Bearer runtime-secret');
    return { ok: true, json: async () => ({ value: JWT }) };
  };
  const why = {};
  const got = await actions.entry('ada/garden', { ACTIONS_ID_TOKEN_REQUEST_URL: 'http://x/idtoken', ACTIONS_ID_TOKEN_REQUEST_TOKEN: 'runtime-secret', GITHUB_REPOSITORY_ID: '4242', GITHUB_REPOSITORY: 'ada/garden' }, fetchFn, why);
  assert.strictEqual(calls, 2);
  assert.strictEqual(got.token, JWT);
  assert.strictEqual(why.line, undefined);
});

test('#2570: GitHub not answering twice running is said once, naming that it was tried twice', async () => {
  const fetchFn = async () => { throw new Error('fetch failed'); };
  const why = {};
  const got = await actions.entry('ada/garden', { ACTIONS_ID_TOKEN_REQUEST_URL: 'http://x/idtoken', ACTIONS_ID_TOKEN_REQUEST_TOKEN: 'runtime-secret', GITHUB_REPOSITORY_ID: '4242', GITHUB_REPOSITORY: 'ada/garden' }, fetchFn, why);
  assert.strictEqual(got, undefined);
  assert.match(why.line, /did not answer.*twice/);
});

test('#2570: GitHub actually refusing the request (a non-OK status) is said once, never retried', async () => {
  let calls = 0;
  const fetchFn = async () => { calls++; return { ok: false, status: 403 }; };
  const why = {};
  const got = await actions.entry('ada/garden', { ACTIONS_ID_TOKEN_REQUEST_URL: 'http://x/idtoken', ACTIONS_ID_TOKEN_REQUEST_TOKEN: 'runtime-secret', GITHUB_REPOSITORY_ID: '4242', GITHUB_REPOSITORY: 'ada/garden' }, fetchFn, why);
  assert.strictEqual(got, undefined);
  assert.strictEqual(calls, 1);
  assert.match(why.line, /answered 403/);
});

test('a full brief is never sent as a run: only a sample', async () => {
  const f = await fake();
  try {
    await send.sendBrief({ text: 'Main: moved\n', repo: 'ada/garden', env: runEnv(f.url), sampleOnly: false, sessions: [agent] });
    assert.strictEqual(f.seen.filter((r) => r.url.startsWith('/v1/')).length, 0);
  } finally { f.server.close(); }
});

test('a run whose identity token is refused says why in its summary, in one line', async () => {
  const f = await fake();
  try {
    const env = { ...runEnv(f.url), GITHUB_STEP_SUMMARY: path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'sns-sum-')), 'summary.md') };
    env.ACTIONS_ID_TOKEN_REQUEST_URL = `${f.url}/refused`;
    const line = await send.sendBrief({ text: '', session: 's1', repo: 'ada/garden', env, sampleOnly: true, sessions: [agent] });
    assert.strictEqual(line, '');
    const said = fs.readFileSync(env.GITHUB_STEP_SUMMARY, 'utf8');
    assert.match(said, /^Its agent could not report to SipNShip: .*identity token/);
    assert.strictEqual(said.trim().split('\n').length, 1);
    assert.doesNotMatch(said, /runtime-secret|aaa\.bbb/);
    assert.match(fs.readFileSync(path.join(env.SIPNSHIP_HOME, 'brief-send', 'sample-trouble.txt'), 'utf8'), /could not report/);
  } finally { f.server.close(); }
});

test('#2624: a report SipNShip refuses puts SipNShip\'s own reason in the run\'s summary, once however often it is tried', async () => {
  const say = 'this run\'s identity token is for another repository than the one it reported to';
  const server = http.createServer((req, res) => {
    req.resume().on('end', () => {
      if (req.url.startsWith('/idtoken')) { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ value: JWT })); return; }
      res.writeHead(401, { 'content-type': 'application/json' }); res.end(JSON.stringify({ code: 'not_connected', why: 'other_repository', say }));
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  try {
    const url = `http://127.0.0.1:${server.address().port}`;
    const env = { ...runEnv(url), GITHUB_STEP_SUMMARY: path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'sns-sum-')), 'summary.md') };
    for (let i = 0; i < 2; i++) await send.sendBrief({ text: '', session: 's1', repo: 'ada/garden', env, sampleOnly: true, sessions: [agent] });
    const said = fs.readFileSync(env.GITHUB_STEP_SUMMARY, 'utf8');
    assert.strictEqual(said, `Its agent could not report to SipNShip: SipNShip refused it: ${say}.\n`);
    assert.doesNotMatch(said, /aaa\.bbb/);
  } finally { server.close(); }
});

test('#2624: a run with no session to name sends nothing, so no refusal blames its identity', async () => {
  const f = await fake();
  try {
    const env = { ...runEnv(f.url), GITHUB_STEP_SUMMARY: path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'sns-sum-')), 'summary.md') };
    await send.sendBrief({ text: '', session: 's1', repo: 'ada/garden', env, sampleOnly: true, sessions: [] });
    assert.strictEqual(f.seen.filter((r) => r.url.startsWith('/v1/')).length, 0);
    assert.strictEqual(fs.existsSync(env.GITHUB_STEP_SUMMARY), false);
  } finally { f.server.close(); }
});

test('a run with no identity token at all says so, naming the job setting', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-run-'));
  const env = { SIPNSHIP_HOME: home, GITHUB_ACTIONS: 'true', GITHUB_STEP_SUMMARY: path.join(home, 'summary.md') };
  await send.sendBrief({ text: '', session: 's1', repo: 'ada/garden', env, sampleOnly: true, sessions: [agent] });
  assert.match(fs.readFileSync(env.GITHUB_STEP_SUMMARY, 'utf8'), /id-token: write/);
});

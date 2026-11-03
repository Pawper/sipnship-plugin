'use strict';
// Tests for the Live check's helper (templates/scripts/ci/live-report.mjs) and
// its workflow template. Written as Maya's rooftop-garden app: her plant-photo
// service refused by Google, and her watering reminders failing now and then.
// Cloudflare's answers are fixtures passed in as a fake fetch.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const { pathToFileURL } = require('node:url');

const tpl = path.join(__dirname, '..', '..', 'templates');
const load = () => import(pathToFileURL(path.join(tpl, 'scripts', 'ci', 'live-report.mjs')).href);

const NOW = Date.parse('2026-11-03T17:00:00Z');
const MIN = 60_000;
const line = (n, extra = '') => `sipnship live/1 service=vision feature=plant-photos status=403 reason=SERVICE_DISABLED account=492817306255 count=${n}${extra}`;
const logEvent = (minAgo, text) => ({ timestamp: NOW - minAgo * MIN, $metadata: { message: text } });

function fakeFetch({ events = [], logsStatus = 200, rows = [], sendStatus = 200, sendThrows = false } = {}) {
  const calls = [];
  const fn = async (url, init = {}) => {
    calls.push({ url: String(url), init });
    const u = String(url);
    const json = (status, body) => ({ ok: status < 300, status, json: async () => body });
    if (u.includes('/telemetry/query')) return json(logsStatus, { result: { events: { events } } });
    if (u.endsWith('/graphql')) return json(200, { data: { viewer: { accounts: [{ workersInvocationsAdaptive: rows }] } } });
    if (u.includes('/v1/repos/')) { if (sendThrows) throw new Error('down'); return json(sendStatus, {}); }
    return json(404, {});
  };
  fn.calls = calls;
  return fn;
}
const env = { CLOUDFLARE_API_TOKEN: 't', CLOUDFLARE_ACCOUNT_ID: 'a', LIVE_SERVICE_TOKEN: 'repo-token', LIVE_REPO_ID: '77', SIPNSHIP_URL: 'https://sipnship.test' };
const row = (status, requests, subrequests = 0) => ({ dimensions: { status }, sum: { requests, subrequests } });

test('three lasting refusals spread over minutes count, and only the findings are sent', async () => {
  const h = await load();
  const f = fakeFetch({ events: [logEvent(50, line(100)), logEvent(30, line(60)), logEvent(5, line(52))] });
  const r = await h.look({ env, fetchFn: f, now: NOW, workers: ['plants'] });
  assert.equal(r.findings.length, 1);
  assert.deepEqual(r.findings[0], { kind: 'refusal', service: 'vision', feature: 'plant-photos', status: '403', reason: 'SERVICE_DISABLED', account: '492817306255', first: '2026-11-03T16:10:00Z', last: '2026-11-03T16:55:00Z', failures: 212 });
  const send = f.calls.find((c) => c.url === 'https://sipnship.test/v1/repos/77/live');
  assert.equal(send.init.headers.authorization, 'Bearer repo-token');
  const body = JSON.parse(send.init.body);
  assert.deepEqual(Object.keys(body).sort(), ['at', 'findings', 'logsReadable']);
  assert.equal(body.logsReadable, true);
  assert.ok(r.sent);
  assert.match(r.lines[0], /vision\) refused plant-photos 212 times/);
});

test('the logs are asked for by their mark alone', async () => {
  const h = await load();
  const f = fakeFetch();
  await h.look({ env, fetchFn: f, now: NOW, workers: [] });
  const q = JSON.parse(f.calls.find((c) => c.url.includes('/telemetry/query')).init.body);
  assert.deepEqual(q.parameters.filters, [{ key: '$metadata.message', operation: 'includes', type: 'string', value: 'sipnship live/1' }]);
});

test('a blip, a refusal inside a deploy, and a line off its pattern never leave', async () => {
  const h = await load();
  const blip = fakeFetch({ events: [logEvent(10, line(2)), logEvent(9, 'sipnship live/1 service=vision feature=Bad_Slug status=403 count=9')] });
  assert.equal((await h.look({ env, fetchFn: blip, now: NOW, workers: [] })).findings.length, 0);
  const deployAt = NOW - 30 * MIN;
  const inDeploy = fakeFetch({ events: [logEvent(30, line(2)), logEvent(29, line(2)), logEvent(29, line(2))] });
  const r = await h.look({ env, fetchFn: inDeploy, now: NOW, workers: [], deploys: [deployAt - MIN] });
  assert.equal(r.findings.length, 0);
  assert.match(r.lines[0], /Your app is working/);
});

test('the app\'s own errors count over a share, and a user\'s own 4xx and early exits do not', async () => {
  const h = await load();
  const bad = fakeFetch({ rows: [row('success', 1000), row('scriptThrewException', 90), row('clientDisconnected', 500)] });
  const r = await h.look({ env, fetchFn: bad, now: NOW, workers: ['reminders'] });
  assert.equal(r.findings.length, 1);
  assert.equal(r.findings[0].kind, 'own');
  assert.equal(r.findings[0].worker, 'reminders');
  assert.equal(r.findings[0].failures, 90);
  const fine = fakeFetch({ rows: [row('success', 1000), row('clientDisconnected', 900), row('scriptThrewException', 5)] });
  assert.equal((await h.look({ env, fetchFn: fine, now: NOW, workers: ['reminders'] })).findings.length, 0);
});

test('a token that cannot read logs sends logsReadable false and still reads analytics', async () => {
  const h = await load();
  const f = fakeFetch({ logsStatus: 403, rows: [row('success', 100), row('internalError', 30)] });
  const r = await h.look({ env, fetchFn: f, now: NOW, workers: ['reminders'] });
  assert.equal(r.logsReadable, false);
  assert.equal(r.findings.length, 1);
  assert.equal(JSON.parse(f.calls.find((c) => c.url.includes('/v1/repos/')).init.body).logsReadable, false);
  assert.ok(r.lines.some((l) => /cannot read the app's logs/.test(l)));
});

test('a failed send is said once, the look still ends well', async () => {
  const h = await load();
  const said = [];
  const r = await h.look({ env, fetchFn: fakeFetch({ events: [logEvent(50, line(5)), logEvent(5, line(5))], sendThrows: true }), now: NOW, workers: [], log: (s) => said.push(s) });
  assert.equal(r.sent, false);
  assert.equal(said.filter((s) => /could not be reached/.test(s)).length, 1);
  assert.equal(r.findings.length, 1);
});

test('the sentences go to the writer once and carry no log text', async () => {
  const h = await load();
  const wrote = [];
  await h.look({ env, fetchFn: fakeFetch(), now: NOW, workers: [], write: (l) => wrote.push(l) });
  assert.equal(wrote.length, 1);
  assert.match(wrote[0][0], /Your app is working/);
});

test('the plan: on the hour, ten to twenty minutes after a deploy, by hand, otherwise skip', async () => {
  const h = await load();
  const at = (iso) => Date.parse(iso);
  assert.equal(h.livePlan({ now: at('2026-11-03T17:03:00Z') }), 'hourly');
  assert.equal(h.livePlan({ now: at('2026-11-03T17:23:00Z') }), 'skip');
  assert.equal(h.livePlan({ now: at('2026-11-03T17:23:00Z'), deployedAt: at('2026-11-03T17:08:00Z') }), 'after-deploy');
  assert.equal(h.livePlan({ now: at('2026-11-03T17:33:00Z'), deployedAt: at('2026-11-03T17:08:00Z') }), 'skip');
  assert.equal(h.livePlan({ now: at('2026-11-03T17:33:00Z'), manual: true }), 'hourly');
});

test('Worker names come from each folder\'s wrangler.toml, in deploy order', async () => {
  const h = await load();
  const names = h.workerNames('{"workers":["packages/api","packages/web"]}', (p) => { if (p.startsWith('packages/api')) return 'name = "garden-api"\n'; throw new Error('none'); });
  assert.deepEqual(names, ['garden-api', 'web']);
});

test('the workflow runs on the builder\'s own runner, always succeeds, and never waits', () => {
  const y = fs.readFileSync(path.join(tpl, '.github', 'workflows', 'live.yml'), 'utf8');
  const live = y.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');
  assert.match(live, /runs-on: RUNS_ON/);
  assert.doesNotMatch(live, /ubuntu-latest|macos-latest/);
  assert.match(live, /continue-on-error: true/);
  assert.doesNotMatch(live, /\bsleep\b/);
  assert.match(live, /cron: "3,13,23,33,43,53 \* \* \* \*"/);
  assert.match(live, /CLOUDFLARE_API_TOKEN: \$\{\{ secrets\.CLOUDFLARE_API_TOKEN \}\}/);
  assert.match(live, /SIPNSHIP_REPO_TOKEN: \$\{\{ secrets\.SIPNSHIP_REPO_TOKEN \}\}/);
});

test('Workers Logs are on with request logs off in the Cloudflare block', () => {
  const t = fs.readFileSync(path.join(tpl, 'live', 'wrangler-logs.toml'), 'utf8');
  assert.match(t, /\[observability\]\s*\nenabled = true/);
  assert.match(t, /invocation_logs = false/);
});

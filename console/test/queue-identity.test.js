'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { queueIdentity, manifest } = require('../queue-identity');

// Only fake values: a fake key, a fake code, a fake GitHub answer.
const FAKE_PEM = '-----BEGIN FAKE KEY-----\nnot-a-real-key\n-----END FAKE KEY-----';
const sink = () => { const lines = []; return { lines, write: (s) => lines.push(s) }; };
const get = (url) => fetch(url);

function setup({ convert = { id: 4242, slug: 'rooftop-queue', pem: FAKE_PEM }, convertOk = true, setFails = false } = {}) {
  const calls = { secrets: [], converted: [], opened: [] };
  let base;
  const out = sink();
  const run = queueIdentity({
    repo: 'maya/rooftop-garden',
    out,
    timeoutMs: 5000,
    onListening: (b) => { base = b; },
    open: (u) => calls.opened.push(u),
    setSecret: (repo, name, value) => { if (setFails) throw new Error('no'); calls.secrets.push({ repo, name, value }); },
    fetchFn: async (url) => { calls.converted.push(url); return { ok: convertOk, json: async () => convert }; },
  });
  return { calls, out, run, base: () => base };
}

test('the start page sends GitHub the manifest and the return address stays on localhost', async () => {
  const s = setup();
  await new Promise((r) => setTimeout(r, 50));
  const html = await (await get(s.base() + '/')).text();
  assert.match(html, /https:\/\/github\.com\/settings\/apps\/new\?state=/);
  assert.match(html, /name="manifest"/);
  assert.ok(html.includes(encodeURIComponent('x') && '127.0.0.1'), 'redirect is on localhost');
  const m = manifest('maya/rooftop-garden', 'http://127.0.0.1:1/done');
  assert.equal(m.default_permissions.contents, 'write');
  assert.equal(m.default_permissions.workflows, 'write');
  assert.equal(m.public, false);
  const state = /state=([0-9a-f]+)/.exec(html)[1];
  await get(`${s.base()}/done?code=c1&state=${state}`);
  await s.run;
});

test('GitHub returning with the right state sets both secrets, opens the install page and prints no key', async () => {
  const s = setup();
  await new Promise((r) => setTimeout(r, 50));
  const html = await (await get(s.base() + '/')).text();
  const state = /state=([0-9a-f]+)/.exec(html)[1];
  const res = await get(`${s.base()}/done?code=abc&state=${state}`);
  const page = await res.text();
  assert.equal(res.status, 200);
  assert.equal(await s.run, 0);
  assert.deepEqual(s.calls.secrets.map((x) => [x.repo, x.name]), [['maya/rooftop-garden', 'QUEUE_APP_ID'], ['maya/rooftop-garden', 'QUEUE_APP_KEY']]);
  assert.equal(s.calls.secrets[0].value, '4242');
  assert.equal(s.calls.secrets[1].value, FAKE_PEM);
  assert.ok(s.calls.converted[0].endsWith('/app-manifests/abc/conversions'));
  assert.ok(s.calls.opened.includes('https://github.com/apps/rooftop-queue/installations/new'));
  const everything = s.out.lines.join('') + page;
  assert.ok(!everything.includes('not-a-real-key'), 'the key is shown nowhere');
});

test('a return with another state is refused and nothing is set', async () => {
  const s = setup();
  await new Promise((r) => setTimeout(r, 50));
  const res = await get(`${s.base()}/done?code=abc&state=wrong`);
  assert.equal(res.status, 400);
  assert.equal(s.calls.secrets.length, 0);
  assert.equal(s.calls.converted.length, 0);
  const html = await (await get(s.base() + '/')).text();
  await get(`${s.base()}/done?code=abc&state=${/state=([0-9a-f]+)/.exec(html)[1]}`);
  await s.run;
});

test('when gh cannot set the secrets it says so and keeps nothing', async () => {
  const s = setup({ setFails: true });
  await new Promise((r) => setTimeout(r, 50));
  const html = await (await get(s.base() + '/')).text();
  await get(`${s.base()}/done?code=abc&state=${/state=([0-9a-f]+)/.exec(html)[1]}`);
  assert.equal(await s.run, 1);
  assert.match(s.out.lines.join(''), /secrets could not be set/);
  assert.ok(!s.out.lines.join('').includes('not-a-real-key'));
});

test('an organization owner posts to the organization page', async () => {
  const out = sink();
  let base;
  const run = queueIdentity({ repo: 'acme/shop', org: 'acme', out, timeoutMs: 300, onListening: (b) => { base = b; }, open: () => {}, setSecret: () => {}, fetchFn: async () => ({ ok: false }) });
  await new Promise((r) => setTimeout(r, 50));
  const html = await (await get(base + '/')).text();
  assert.match(html, /github\.com\/organizations\/acme\/settings\/apps\/new/);
  assert.equal(await run, 1);
});

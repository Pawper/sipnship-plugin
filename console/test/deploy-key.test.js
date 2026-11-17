'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { deployKey, deployKeyPage } = require('../deploy-key');

const get = (url) => fetch(url);
const post = (url, body) => fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });

const FAKE_KEY = 'fake-hosting-key-for-tests-only';
const sink = () => { const lines = []; return { lines, write: (s) => lines.push(s) }; };
const reply = (body, ok = true) => ({ ok, json: async () => body });
function folder(target) {
  const dir = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'dk-'));
  if (target) { fs.mkdirSync(path.join(dir, '.claude')); fs.writeFileSync(path.join(dir, '.claude', 'deploy.json'), JSON.stringify({ target })); }
  return dir;
}

test('a Cloudflare key finds its one account and sets both secrets', async () => {
  const set = []; const out = sink(); const asked = [];
  const code = await deployKey({
    repo: 'maya/rooftop-garden', cwd: folder('cloudflare'), out,
    prompt: async (q) => { asked.push(q); return FAKE_KEY; },
    fetchFn: async (url, init) => { assert.equal(init.headers.authorization, `Bearer ${FAKE_KEY}`); return reply({ result: [{ id: 'acct1' }] }); },
    setSecret: (repo, name, value) => set.push([repo, name, value]),
  });
  assert.equal(code, 0);
  assert.deepEqual(set, [['maya/rooftop-garden', 'CLOUDFLARE_API_TOKEN', FAKE_KEY], ['maya/rooftop-garden', 'CLOUDFLARE_ACCOUNT_ID', 'acct1']]);
  assert.match(asked[0], /not shown/);
  assert.ok(!out.lines.join('').includes(FAKE_KEY), 'the key is never printed');
});

test('a Vercel key finds the team and the project by name', async () => {
  const set = []; const out = sink();
  const code = await deployKey({
    repo: 'maya/rooftop-garden', cwd: folder('vercel'), out,
    prompt: async () => FAKE_KEY,
    fetchFn: async (url) => {
      if (url.endsWith('/v2/user')) return reply({ user: { id: 'u1' } });
      if (url.endsWith('/v2/teams')) return reply({ teams: [{ id: 'team1' }] });
      return reply({ projects: [{ id: 'p0', name: 'other' }, { id: 'prj1', name: 'rooftop-garden' }] });
    },
    setSecret: (repo, name, value) => set.push([name, value]),
  });
  assert.equal(code, 0);
  assert.deepEqual(set, [['VERCEL_TOKEN', FAKE_KEY], ['VERCEL_ORG_ID', 'team1'], ['VERCEL_PROJECT_ID', 'prj1']]);
  assert.ok(!out.lines.join('').includes(FAKE_KEY));
});

test('a key the host refuses changes nothing', async () => {
  const set = []; const out = sink();
  const code = await deployKey({ repo: 'maya/rooftop-garden', host: 'cloudflare', cwd: folder(), out, prompt: async () => FAKE_KEY, fetchFn: async () => reply({}, false), setSecret: (...a) => set.push(a) });
  assert.equal(code, 1);
  assert.equal(set.length, 0);
  assert.match(out.lines.join(''), /Nothing was changed/);
});

test('two Cloudflare accounts are not guessed between', async () => {
  const set = []; const out = sink();
  const code = await deployKey({ repo: 'maya/rooftop-garden', host: 'cloudflare', cwd: folder(), out, prompt: async () => FAKE_KEY, fetchFn: async () => reply({ result: [{ id: 'a' }, { id: 'b' }] }), setSecret: (...a) => set.push(a) });
  assert.equal(code, 1);
  assert.equal(set.length, 0);
});

test('an empty answer sets nothing', async () => {
  const out = sink();
  assert.equal(await deployKey({ repo: 'maya/rooftop-garden', host: 'vercel', cwd: folder(), out, prompt: async () => '', fetchFn: async () => { throw new Error('no'); }, setSecret: () => { throw new Error('no'); } }), 2);
});

// deployKeyPage: the same lookup and secrets, served on a localhost page with one field, the way queue-identity serves its own.
function pageSetup({ host = 'cloudflare', fetchFn, setFails = false } = {}) {
  const calls = { secrets: [], opened: [] };
  let base;
  const out = sink();
  const run = deployKeyPage({
    repo: 'maya/rooftop-garden', host, cwd: folder(), out, timeoutMs: 5000,
    onListening: (b) => { base = b; },
    open: (u) => calls.opened.push(u),
    setSecret: (repo, name, value) => { if (setFails) throw new Error('no'); calls.secrets.push({ repo, name, value }); },
    fetchFn,
  });
  return { calls, out, run, base: () => base };
}

test('the page shows one hidden field and a link to make the key, never the key itself', async () => {
  const s = pageSetup({ fetchFn: async () => reply({ result: [{ id: 'acct1' }] }) });
  await new Promise((r) => setTimeout(r, 50));
  const html = await (await get(s.base() + '/')).text();
  assert.match(html, /type="password"/);
  assert.match(html, /dash\.cloudflare\.com\/profile\/api-tokens/);
  await post(s.base() + '/key', { key: FAKE_KEY });
  assert.equal(await s.run, 0);
});

test('pasting the key on the page finds the ids and sets the secrets, printing none of it', async () => {
  const s = pageSetup({ fetchFn: async (url, init) => { assert.equal(init.headers.authorization, `Bearer ${FAKE_KEY}`); return reply({ result: [{ id: 'acct1' }] }); } });
  await new Promise((r) => setTimeout(r, 50));
  const res = await post(s.base() + '/key', { key: FAKE_KEY });
  const page = await res.text();
  assert.equal(res.status, 200);
  assert.equal(await s.run, 0);
  assert.deepEqual(s.calls.secrets.map((x) => [x.repo, x.name, x.value]), [['maya/rooftop-garden', 'CLOUDFLARE_API_TOKEN', FAKE_KEY], ['maya/rooftop-garden', 'CLOUDFLARE_ACCOUNT_ID', 'acct1']]);
  const everything = s.out.lines.join('') + page;
  assert.ok(!everything.includes(FAKE_KEY), 'the key is shown nowhere');
});

test('an empty submission on the page changes nothing', async () => {
  const s = pageSetup({ fetchFn: async () => { throw new Error('should not be called'); } });
  await new Promise((r) => setTimeout(r, 50));
  const res = await post(s.base() + '/key', { key: '' });
  assert.match(await res.text(), /No key was entered/);
  assert.equal(await s.run, 2);
  assert.equal(s.calls.secrets.length, 0);
});

test('a key the host refuses on the page changes nothing and prints no key', async () => {
  const s = pageSetup({ fetchFn: async () => reply({}, false) });
  await new Promise((r) => setTimeout(r, 50));
  const res = await post(s.base() + '/key', { key: FAKE_KEY });
  assert.match(await res.text(), /Nothing was changed/);
  assert.equal(await s.run, 1);
  assert.equal(s.calls.secrets.length, 0);
  assert.ok(!s.out.lines.join('').includes(FAKE_KEY));
});

test('when gh cannot set the secrets from the page it says so and keeps nothing', async () => {
  const s = pageSetup({ fetchFn: async () => reply({ result: [{ id: 'acct1' }] }), setFails: true });
  await new Promise((r) => setTimeout(r, 50));
  const res = await post(s.base() + '/key', { key: FAKE_KEY });
  assert.match(await res.text(), /Could not set the secrets/);
  assert.equal(await s.run, 1);
  assert.ok(!s.out.lines.join('').includes(FAKE_KEY));
});

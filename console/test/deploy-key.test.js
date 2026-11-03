'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { deployKey } = require('../deploy-key');

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

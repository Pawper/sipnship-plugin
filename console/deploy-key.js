'use strict';
// sipnship deploy-key [--repo OWNER/NAME] [--host cloudflare|vercel] [--terminal]
//
// Takes the hosting key once and sets the deploy secrets, the same way
// `queue-identity` gives the queue its name: a small page on localhost, with
// one field that shows nothing typed. The machine's own browser opens it;
// the page finds the account or project ids by asking the host, sets every
// secret the deploy needs on the repository with the builder's own gh, and
// forgets the key. The key is held in this process only: it never reaches
// SipNShip's service, is never written to a file, printed or put on any
// command line (gh reads it from standard input), and this process forgets
// it once the secrets are set. --terminal keeps the hidden prompt instead,
// for a machine with no screen.
//   cloudflare  CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID
//   vercel      VERCEL_TOKEN, VERCEL_ORG_ID, VERCEL_PROJECT_ID

const http = require('http');
const fs = require('fs');
const path = require('path');
const { execFileSync, spawn } = require('child_process');
const { remoteRepo } = require('./connect');
const { readHidden } = require('./secret-prompt');

const LABELS = { cloudflare: 'Cloudflare', vercel: 'Vercel' };
const PROVIDER_PAGES = { cloudflare: 'https://dash.cloudflare.com/profile/api-tokens', vercel: 'https://vercel.com/account/tokens' };

const defaultSetSecret = (fullName, name, value) => {
  execFileSync('gh', ['secret', 'set', name, '--repo', fullName], { input: value, stdio: ['pipe', 'ignore', 'ignore'] });
};

const defaultOpen = (url) => {
  const [cmd, args] = process.platform === 'win32' ? ['cmd', ['/c', 'start', '', url]] : process.platform === 'darwin' ? ['open', [url]] : ['xdg-open', [url]];
  try { spawn(cmd, args, { stdio: 'ignore', detached: true }).unref(); } catch { /* the address is printed too */ }
};

/** The host the project deploys to: --host, else .claude/deploy.json's target, else Vercel. */
function hostOf(cwd, host) {
  if (host) return host;
  try { return JSON.parse(fs.readFileSync(path.join(cwd, '.claude', 'deploy.json'), 'utf8')).target === 'cloudflare' ? 'cloudflare' : 'vercel'; } catch { return 'vercel'; }
}

async function getJson(fetchFn, url, key) {
  const res = await fetchFn(url, { headers: { authorization: `Bearer ${key}` } });
  if (!res.ok) throw new Error(String(res.status));
  return res.json();
}

async function cloudflareIds(key, fetchFn) {
  const b = await getJson(fetchFn, 'https://api.cloudflare.com/client/v4/accounts', key);
  const accounts = (b.result || []).map((a) => a.id);
  if (accounts.length !== 1) return { problem: accounts.length ? 'This key reaches more than one Cloudflare account, so there is no single account to pick. Make a key for the one account and run this again.' : 'This key reaches no Cloudflare account.' };
  return { secrets: { CLOUDFLARE_API_TOKEN: key, CLOUDFLARE_ACCOUNT_ID: accounts[0] } };
}

async function vercelIds(key, fetchFn, cwd, fullName) {
  const user = (await getJson(fetchFn, 'https://api.vercel.com/v2/user', key)).user || {};
  const teams = (await getJson(fetchFn, 'https://api.vercel.com/v2/teams', key)).teams || [];
  const org = teams.length === 1 ? teams[0].id : teams.length === 0 ? user.id : '';
  if (!org) return { problem: 'This key reaches more than one Vercel team, so there is no single one to pick. Make a key for the one team and run this again.' };
  let project;
  try { project = JSON.parse(fs.readFileSync(path.join(cwd, '.vercel', 'project.json'), 'utf8')).projectId; } catch { /* look it up by name */ }
  if (!project) {
    const q = teams.length ? `?teamId=${encodeURIComponent(org)}&limit=100` : '?limit=100';
    const list = (await getJson(fetchFn, `https://api.vercel.com/v9/projects${q}`, key)).projects || [];
    const want = fullName.split('/')[1].toLowerCase();
    const hit = list.find((p) => String(p.name).toLowerCase() === want);
    if (!hit) return { problem: `This key's Vercel account has no project named ${fullName.split('/')[1]}. Make the project first, then run this again.` };
    project = hit.id;
  }
  return { secrets: { VERCEL_TOKEN: key, VERCEL_ORG_ID: org, VERCEL_PROJECT_ID: project } };
}

/** The ids for a key on this host: { secrets } to set, or { problem } to say and change nothing. Throws only when the host itself would not answer. */
function idsFor(target, key, fetchFn, cwd, fullName) {
  return target === 'cloudflare' ? cloudflareIds(key, fetchFn) : vercelIds(key, fetchFn, cwd, fullName);
}

async function deployKey({ repo, host, out = process.stdout, cwd = process.cwd(), fetchFn = fetch, setSecret = defaultSetSecret, prompt = readHidden } = {}) {
  const fullName = repo || remoteRepo(cwd);
  if (!fullName || !/^[^/\s]+\/[^/\s]+$/.test(fullName)) {
    out.write('Name the repository: sipnship deploy-key --repo OWNER/NAME\n');
    return 2;
  }
  const target = hostOf(cwd, host);
  if (target !== 'cloudflare' && target !== 'vercel') { out.write('The host is cloudflare or vercel.\n'); return 2; }
  const label = LABELS[target];
  let key = await prompt(`Paste the ${label === 'Cloudflare' ? 'Cloudflare API token' : 'Vercel token'} (it is not shown): `);
  if (!key) { out.write('No key was entered. Nothing was changed.\n'); return 2; }
  let found;
  try {
    found = await idsFor(target, key, fetchFn, cwd, fullName);
  } catch {
    key = '';
    out.write(`${label} would not accept that key. Nothing was changed.\n`);
    return 1;
  }
  if (found.problem) { key = ''; out.write(`${found.problem} Nothing was changed.\n`); return 1; }
  const names = [];
  try {
    for (const [name, value] of Object.entries(found.secrets)) { setSecret(fullName, name, value); names.push(name); }
  } catch {
    key = '';
    out.write(`Could not set the secrets on ${fullName}${names.length ? ` (set so far: ${names.join(', ')})` : ''}. Is gh signed in to an account that can change it?\n`);
    return 1;
  }
  found = null; key = '';
  out.write(`Set ${names.join(', ')} on ${fullName}. The key was not kept anywhere here.\n`);
  return 0;
}

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function page(title, body) {
  return `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)}</title><body style="font:16px/1.5 system-ui,sans-serif;max-width:32rem;margin:3rem auto;padding:0 16px">${body}</body>`;
}

/** The one-field page: a link to make the key on the provider's own page, and a password field that shows nothing typed. */
function keyPage(fullName, target) {
  const label = LABELS[target];
  return page(`Add your ${label} key`, `<h1>Add your ${esc(label)} key</h1>
<p>This sets ${esc(fullName)}'s deploy secrets from a ${esc(label)} key. Make one on <a href="${esc(PROVIDER_PAGES[target])}" target="_blank" rel="noopener">${esc(label)}'s own page</a> if you have not already, then paste it below. It is not shown here, and goes straight to GitHub as a secret: not to SipNShip, not to a file, not to this screen again.</p>
<form id="f">
<input type="password" name="key" autocomplete="off" placeholder="Paste your ${esc(label)} key" style="font:inherit;padding:.5rem;width:100%;box-sizing:border-box">
<p><button type="submit" style="font:inherit;padding:.6rem 1.2rem">Set the deploy key</button></p>
</form>
<script>
f.addEventListener('submit', async (e) => {
  e.preventDefault();
  const key = f.key.value;
  f.key.value = '';
  f.querySelector('button').disabled = true;
  const res = await fetch('/key', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ key }) });
  document.body.innerHTML = await res.text();
});
</script>`);
}

async function readBody(req) {
  let body = '';
  for await (const chunk of req) {
    body += chunk;
    if (body.length > 10000) { req.destroy(); throw new Error('too long'); }
  }
  return body;
}

async function deployKeyPage({ repo, host, out = process.stdout, cwd = process.cwd(), fetchFn = fetch, setSecret = defaultSetSecret, open = defaultOpen, timeoutMs = 10 * 60 * 1000, onListening } = {}) {
  const fullName = repo || remoteRepo(cwd);
  if (!fullName || !/^[^/\s]+\/[^/\s]+$/.test(fullName)) {
    out.write('Name the repository: sipnship deploy-key --repo OWNER/NAME\n');
    return 2;
  }
  const target = hostOf(cwd, host);
  if (target !== 'cloudflare' && target !== 'vercel') { out.write('The host is cloudflare or vercel.\n'); return 2; }
  const label = LABELS[target];

  let finish;
  const done = new Promise((r) => { finish = r; });
  const server = http.createServer(async (req, res) => {
    const send = (status, html) => { res.writeHead(status, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }); res.end(html); };
    if (req.method === 'GET' && (req.url === '/' || req.url === '')) return send(200, keyPage(fullName, target));
    if (req.method !== 'POST' || req.url !== '/key') return send(404, page('Not here', '<p>Nothing here.</p>'));
    let key = '';
    try {
      const body = await readBody(req);
      key = String(JSON.parse(body).key || '').trim();
    } catch { key = ''; }
    if (!key) { send(200, '<p>No key was entered. Nothing was changed.</p>'); return finish({ code: 2, say: 'No key was entered. Nothing was changed.' }); }
    let found;
    try {
      found = await idsFor(target, key, fetchFn, cwd, fullName);
    } catch {
      key = '';
      send(200, `<p>${esc(label)} would not accept that key. Nothing was changed.</p>`);
      return finish({ code: 1, say: `${label} would not accept that key. Nothing was changed.` });
    }
    if (found.problem) {
      key = '';
      send(200, `<p>${esc(found.problem)} Nothing was changed.</p>`);
      return finish({ code: 1, say: `${found.problem} Nothing was changed.` });
    }
    const names = [];
    try {
      for (const [name, value] of Object.entries(found.secrets)) { setSecret(fullName, name, value); names.push(name); }
    } catch {
      key = '';
      send(200, `<p>Could not set the secrets on ${esc(fullName)}${names.length ? ` (set so far: ${esc(names.join(', '))})` : ''}. Is gh signed in to an account that can change it?</p>`);
      return finish({ code: 1, say: `Could not set the secrets on ${fullName}${names.length ? ` (set so far: ${names.join(', ')})` : ''}. Is gh signed in to an account that can change it?` });
    }
    found = null; key = '';
    send(200, `<h1>Deploys have their key</h1><p>Set ${esc(names.join(', '))} on ${esc(fullName)}. The key was not kept anywhere here. You can close this page.</p>`);
    return finish({ code: 0, say: `Set ${names.join(', ')} on ${fullName}. The key was not kept anywhere here.` });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  if (onListening) onListening(base);
  out.write(`Opening ${base} to take your ${label} key. It is not shown there, and goes straight to GitHub as a secret.\n`);
  open(base);
  const timer = setTimeout(() => finish({ code: 1, say: 'Nothing came back in ten minutes. Run the command again when you are ready.' }), timeoutMs);
  const result = await done;
  clearTimeout(timer);
  server.close();
  out.write(`${result.say}\n`);
  return result.code;
}

module.exports = { deployKey, deployKeyPage, hostOf };

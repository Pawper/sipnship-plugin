'use strict';
// sipnship deploy-key [--repo OWNER/NAME] [--host cloudflare|vercel]
//
// Takes the hosting key once, at a prompt that does not show it, finds the
// ids that go with it by asking the host, sets every secret the deploy needs
// on the repository with the builder's own gh, and forgets the key. The key
// is held in this function only; it is not written to a file, printed, or
// put on any command line (gh reads it from standard input).
//   cloudflare  CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID
//   vercel      VERCEL_TOKEN, VERCEL_ORG_ID, VERCEL_PROJECT_ID

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { remoteRepo } = require('./connect');
const { readHidden } = require('./secret-prompt');

const defaultSetSecret = (fullName, name, value) => {
  execFileSync('gh', ['secret', 'set', name, '--repo', fullName], { input: value, stdio: ['pipe', 'ignore', 'ignore'] });
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

async function deployKey({ repo, host, out = process.stdout, cwd = process.cwd(), fetchFn = fetch, setSecret = defaultSetSecret, prompt = readHidden } = {}) {
  const fullName = repo || remoteRepo(cwd);
  if (!fullName || !/^[^/\s]+\/[^/\s]+$/.test(fullName)) {
    out.write('Name the repository: sipnship deploy-key --repo OWNER/NAME\n');
    return 2;
  }
  const target = hostOf(cwd, host);
  if (target !== 'cloudflare' && target !== 'vercel') { out.write('The host is cloudflare or vercel.\n'); return 2; }
  const label = target === 'cloudflare' ? 'Cloudflare API token' : 'Vercel token';
  let key = await prompt(`Paste the ${label} (it is not shown): `);
  if (!key) { out.write('No key was entered. Nothing was changed.\n'); return 2; }
  let found;
  try {
    found = target === 'cloudflare' ? await cloudflareIds(key, fetchFn) : await vercelIds(key, fetchFn, cwd, fullName);
  } catch {
    key = '';
    out.write(`${target === 'cloudflare' ? 'Cloudflare' : 'Vercel'} would not accept that key. Nothing was changed.\n`);
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

module.exports = { deployKey, hostOf };

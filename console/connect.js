'use strict';
// sipnship connect --repo [OWNER/NAME] [--token TOKEN]
// sipnship disconnect [--repo OWNER/NAME]
//
// Connect: the device flow (a short code the builder approves on the
// dashboard), then the connect route, which hands this machine its
// repository token once; the token is kept in ~/.sipnship/tokens.json,
// outside every repository. --token installs a token the dashboard's Rotate
// made instead. Disconnect: tells the service to stop the token, then
// forgets it here. Nothing here prints a token.

const os = require('os');
const { execFileSync } = require('child_process');
const tokens = require('./tokens');
const { base } = require('./brief-send');

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

function remoteRepo(cwd) {
  try {
    return tokens.repoFromRemote(execFileSync('git', ['remote', 'get-url', 'origin'], { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }));
  } catch {
    return undefined;
  }
}

async function json(res) {
  try { return await res.json(); } catch { return {}; }
}

async function call(url, init = {}) {
  const res = await fetch(url, { ...init, signal: AbortSignal.timeout(15000) });
  return { status: res.status, body: await json(res) };
}

/** The repository's GitHub id: the one already kept for it, else GitHub's own answer through gh. */
function repoIdOf(fullName, env, run) {
  const kept = tokens.find(fullName, env);
  if (kept) return kept.repoId;
  try {
    const id = Number(String(run('gh', ['api', `repos/${fullName}`, '--jq', '.id'])).trim());
    return Number.isInteger(id) && id > 0 ? id : undefined;
  } catch {
    return undefined;
  }
}

const defaultRun = (cmd, args) => execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });

async function connect({ repo, token, env = process.env, out = process.stdout, cwd = process.cwd(), machine = os.hostname(), run = defaultRun, pollMs }) {
  const fullName = repo || remoteRepo(cwd);
  if (!fullName || !/^[^/\s]+\/[^/\s]+$/.test(fullName)) {
    out.write('Name the repository: sipnship connect --repo OWNER/NAME\n');
    return 2;
  }
  const url = base(env);
  if (token !== undefined) {
    if (!tokens.looksLikeToken(token)) { out.write('That is not a SipNShip repository token. Copy the whole command from the dashboard again.\n'); return 2; }
    const repoId = repoIdOf(fullName, env, run);
    if (!repoId) { out.write(`Could not find ${fullName} on GitHub from this machine. Run it from inside the repository, signed in to gh.\n`); return 1; }
    const kept = tokens.find(repoId, env);
    tokens.put({ repoId, fullName, token, machine: kept?.machine || machine }, env);
    out.write(`Installed the new token for ${fullName}. The old one has already stopped working.\n`);
    return 0;
  }
  let start;
  try {
    start = await call(`${url}/v1/device/code`, { method: 'POST' });
  } catch {
    out.write('Could not reach SipNShip. Nothing was changed; try again in a minute.\n');
    return 1;
  }
  const d = start.body;
  if (start.status !== 200 || !d.deviceCode) { out.write(`${d.say || 'SipNShip could not start the connection.'}\n`); return 1; }
  out.write(`${d.say || `Open ${d.verificationUri} and enter the code ${d.userCode}.`}\n`);
  const every = pollMs ?? Math.max(1, Number(d.interval) || 5) * 1000;
  const until = Date.now() + Math.max(60, Number(d.expiresIn) || 900) * 1000;
  let gh;
  while (Date.now() < until) {
    await wait(every);
    let r;
    try {
      r = await call(`${url}/v1/device/token`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ deviceCode: d.deviceCode }) });
    } catch { continue; }
    if (r.status === 200 && r.body.token) { gh = r.body.token; break; }
    if (r.body.code === 'approval_pending') continue;
    out.write(`${r.body.say || 'The code was not approved in time. Run the command again for a new one.'}\n`);
    return 1;
  }
  if (!gh) { out.write('The code was not approved in time. Run the command again for a new one.\n'); return 1; }
  const c = await call(`${url}/v1/repos/${fullName}/connect`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${gh}` },
    body: JSON.stringify({ machine }),
  }).catch(() => ({ status: 0, body: {} }));
  if (c.status !== 200 || !tokens.looksLikeToken(c.body.token) || !Number.isInteger(c.body.repoId)) {
    out.write(`${c.body.say || `Could not connect ${fullName}. Nothing was changed.`}\n`);
    return 1;
  }
  tokens.put({ repoId: c.body.repoId, fullName: c.body.fullName || fullName, token: c.body.token, machine: c.body.machine || machine }, env);
  out.write(`${c.body.say || `Connected: ${machine}.`}\n`);
  return 0;
}

async function disconnect({ repo, env = process.env, out = process.stdout, cwd = process.cwd() }) {
  const fullName = repo || remoteRepo(cwd);
  const entry = tokens.find(fullName, env);
  if (!entry) { out.write(`This machine is not connected${fullName ? ` for ${fullName}` : ''}.\n`); return 0; }
  let told = false;
  try {
    const res = await fetch(`${base(env)}/v1/repos/${entry.repoId}/disconnect`, { method: 'POST', headers: { authorization: `Bearer ${entry.token}` }, signal: AbortSignal.timeout(5000) });
    told = res.status === 204 || res.status === 401;
  } catch { /* forgotten here either way */ }
  tokens.remove(entry.repoId, env);
  out.write(told
    ? `Disconnected ${entry.fullName}. This machine sends nothing more.\n`
    : `Forgot the token for ${entry.fullName} here, but could not reach SipNShip; press Disconnect on the dashboard to stop it there too.\n`);
  return 0;
}

module.exports = { connect, disconnect, remoteRepo };

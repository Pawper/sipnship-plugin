'use strict';
// sipnship ask add-runner [NAME]
// sipnship ask remove-runner NAME
// sipnship ask migrate [PR]       run the database change from main, or from that pull request's branch
// sipnship ask deploy
// sipnship ask scan-skip          let the runners skip the antivirus scan
// sipnship ask scan-again         scan the runners again
//
// A proposal for this machine, made in the name of the person signed in to
// gh. From a terminal it is always a proposal: it runs only after the
// machine's person approves it on the dashboard, where it waits as a card.
// There is no form of this command for granting permissions: an agent never
// grants itself permissions.
const { execFileSync } = require('child_process');
const { base } = require('./brief-send');
const { remoteRepo } = require('./connect');
const tokens = require('./tokens');
const { paramRule } = require('./request-rules');

const ASKS = { 'add-runner': 'add-runner', 'remove-runner': 'remove-runner', migrate: 'run-migration', deploy: 'deploy', 'scan-skip': 'scan-skip', 'scan-again': 'scan-again' };

const defaultRun = (cmd, args) => execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });

async function ask({ what, param, reason = '', repo, env = process.env, out = process.stdout, cwd = process.cwd(), run = defaultRun }) {
  const kind = ASKS[what];
  if (!kind) { out.write('Ask for one of: add-runner, remove-runner, migrate, deploy, scan-skip, scan-again. Granting permissions is yours alone: node console/cli.js permissions.\n'); return 2; }
  const given = kind === 'run-migration' ? (param || 'main') : (param || '');
  const p = kind === 'add-runner' && !given ? '' : paramRule(kind, given);
  if (p === undefined) { out.write(`That is not a valid ${kind === 'run-migration' ? 'branch (main, or a pull request number)' : kind.endsWith('runner') ? 'runner name (lowercase letters, numbers and dashes, like garden-4)' : 'value for this request'}.\n`); return 2; }
  const fullName = repo || remoteRepo(cwd);
  const entry = fullName ? tokens.find(fullName, env) : undefined;
  if (!entry) { out.write('This machine is not connected to SipNShip for that repository. Run npx sipnship connect --repo first.\n'); return 2; }
  let token = '';
  try { token = run('gh', ['auth', 'token']).trim(); } catch { /* not signed in */ }
  if (!token) { out.write('Sign in to GitHub first with gh auth login; the request is made in your name.\n'); return 2; }
  try {
    const res = await fetch(`${base(env)}/v1/repos/${entry.fullName}/machines/${encodeURIComponent(entry.machine)}/requests`, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ kind, param: p, reason: String(reason).replace(/\s+/g, ' ').trim(), via: 'cli' }),
      signal: AbortSignal.timeout(10000),
    });
    const body = await res.json().catch(() => ({}));
    if (res.status === 201) { out.write(`${body.say}\nIt waits for approval on the dashboard: ${entry.machine}'s person approves it there, and only then does it run.\n`); return 0; }
    out.write(`${body.say || 'SipNShip did not take the request.'}\n`);
    return 1;
  } catch {
    out.write('Could not reach SipNShip, so nothing was asked. Nothing changed.\n');
    return 1;
  }
}

module.exports = { ask, ASKS };

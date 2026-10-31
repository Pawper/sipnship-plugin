'use strict';
// sipnship land-next N ["reason"]   land this pull request next
// sipnship hold N ["reason"]        hold it out of the queue
// sipnship drop N "reason"          take it out, closing it with the reason
// sipnship release N                release a hold
// sipnship deploy-now ["reason"]    start the Deploy workflow at the queue's next tick
//
// A request to the merge queue, made as the person signed in to gh (the
// service checks they can see the repository). The local queue honours it
// within two minutes and never merges anything red. When SipNShip cannot
// be reached, prints the comment to post on the Merge queue issue instead,
// which the queue reads on the issue road.
const { execFileSync } = require('child_process');
const { base } = require('./brief-send');
const { remoteRepo } = require('./connect');

const KINDS = { 'land-next': 'land-next', hold: 'hold', drop: 'drop', release: 'release', 'deploy-now': 'deploy-now' };

function ghToken(run) {
  try {
    return run('gh', ['auth', 'token']).trim();
  } catch {
    return '';
  }
}

const defaultRun = (cmd, args) => execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });

/** The issue road's fixed form, as the queue parses it. */
function issueForm(kind, pr, login, reason) {
  return `Queue request: ${kind === 'deploy-now' ? kind : `${kind} #${pr}`} by ${login}${reason ? `: ${reason}` : ''}`;
}

async function request({ kind, pr, reason = '', repo, via = 'cli', env = process.env, out = process.stdout, cwd = process.cwd(), run = defaultRun }) {
  if (!KINDS[kind]) { out.write('Ask for one of: land-next, hold, drop, release.\n'); return 2; }
  const deploy = kind === 'deploy-now';
  const n = deploy ? 0 : Number(pr);
  if (!deploy && (!Number.isInteger(n) || n <= 0)) { out.write(`Name the pull request by its number: sipnship ${kind} 48\n`); return 2; }
  const why = String(reason || '').replace(/\s+/g, ' ').trim();
  if (kind === 'drop' && !why) { out.write('Taking a pull request out closes it, so say why: sipnship drop 48 "what replaced it"\n'); return 2; }
  const fullName = repo || remoteRepo(cwd);
  if (!fullName) { out.write('Run this inside the repository, or name it with --repo OWNER/NAME.\n'); return 2; }
  const token = ghToken(run);
  if (!token) { out.write('Sign in to GitHub first with gh auth login; the request is made in your name.\n'); return 2; }
  try {
    const res = await fetch(`${base(env)}/v1/repos/${fullName}/queue/requests`, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify(deploy ? { kind, reason: why, via } : { kind, pr: n, reason: why, via }),
      signal: AbortSignal.timeout(10000),
    });
    const body = await res.json().catch(() => ({}));
    if (res.status === 201) { out.write(`${body.say}. The queue takes it within two minutes.\n`); return 0; }
    out.write(`${body.say || 'SipNShip did not take the request.'}\n`);
    return 1;
  } catch {
    let login = 'you';
    try { login = run('gh', ['api', 'user', '--jq', '.login']).trim() || login; } catch {}
    out.write(`Could not reach SipNShip. Post this comment on the Merge queue issue instead, and the queue reads it there:\n${issueForm(kind, n, login, why)}\n`);
    return 1;
  }
}

module.exports = { request, issueForm, KINDS };

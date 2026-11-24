'use strict';
// How an agent started inside a workflow run (the drive's own run, on its runner) reports to SipNShip when its
// machine holds no repository token (#2437). The run is signed in by GitHub's identity token, the way the queue's
// drain already is (scripts/ci/service-auth.sh): a workflow with `id-token: write` asks GitHub for a short-lived
// token for the audience https://sipnship.dev, never kept. The service takes it for a session sample alone: no
// card, no runner reading, no step, so a run can say which agent is on which issue and nothing else.

const AUDIENCE = 'https://sipnship.dev';
const SENDER = 'GitHub Actions';

/** True when this process is a step of a run that may ask GitHub for its identity token. */
function inRun(env = process.env) {
  return !!(env.ACTIONS_ID_TOKEN_REQUEST_URL && env.ACTIONS_ID_TOKEN_REQUEST_TOKEN && /^\d+$/.test(env.GITHUB_REPOSITORY_ID || ''));
}

/**
 * The entry the send signs in with for `repo` (owner/name), or undefined when this is not a run of that repository
 * or GitHub does not answer. Same shape as a token entry, with `actions: true`.
 */
async function entry(repo, env = process.env, fetchFn = fetch, why = {}) {
  if (!inRun(env)) {
    if (env.GITHUB_ACTIONS === 'true') why.line = 'this run holds no identity token for the agent to report with: the job needs `id-token: write`, and the agent\'s own environment must keep it';
    return undefined;
  }
  if (repo && env.GITHUB_REPOSITORY && String(env.GITHUB_REPOSITORY).toLowerCase() !== String(repo).toLowerCase()) return undefined;
  try {
    const url = env.ACTIONS_ID_TOKEN_REQUEST_URL;
    const res = await fetchFn(`${url}${url.includes('?') ? '&' : '?'}audience=${encodeURIComponent(AUDIENCE)}`, {
      headers: { authorization: `Bearer ${env.ACTIONS_ID_TOKEN_REQUEST_TOKEN}` },
      signal: AbortSignal.timeout(4000),
    });
    if (!res.ok) { why.line = `GitHub would not give this run an identity token (answered ${res.status})`; return undefined; }
    const value = (await res.json()).value;
    if (!/^[\w-]+\.[\w-]+\.[\w-]+$/.test(value || '')) { why.line = 'GitHub gave this run an identity token that was not readable'; return undefined; }
    return { repoId: Number(env.GITHUB_REPOSITORY_ID), fullName: env.GITHUB_REPOSITORY, token: value, machine: SENDER, actions: true };
  } catch {
    why.line = 'GitHub did not answer this run\'s request for an identity token';
    return undefined;
  }
}

/**
 * Says in one line why an agent's report could not be sent, where a person reads the run: the run's step summary when
 * there is one, and a file beside the other send records. Never throws; never carries a token.
 */
function troubleLine(line, env = process.env, now = new Date()) {
  const text = `Its agent could not report to SipNShip: ${line}.`;
  const fs = require('fs');
  const path = require('path');
  try { if (env.GITHUB_STEP_SUMMARY) fs.appendFileSync(env.GITHUB_STEP_SUMMARY, `${text}\n`); } catch { /* the summary is not there */ }
  try {
    const dir = path.join(env.SIPNSHIP_HOME || path.join(require('os').homedir(), '.sipnship'), 'brief-send');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'sample-trouble.txt'), `${now.toISOString()} ${text}\n`);
  } catch { /* nowhere to keep it */ }
  return text;
}

module.exports = { AUDIENCE, SENDER, inRun, entry, troubleLine };

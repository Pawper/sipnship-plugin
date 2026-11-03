'use strict';
// sipnship setup [--repo OWNER/NAME]
//
// How setting up this project is going, read from the service in its own
// words (spec 015, "What an agent reads"): each item with its state, whose
// turn it is, one plain sentence, its fields and its handle. It prints what
// the dashboard shows and words nothing itself; a test keeps these lines equal
// to the CLI package's (packages/cli/src/setup.ts). Read-only.

const tokens = require('./tokens');
const { base } = require('./brief-send');
const { remoteRepo } = require('./connect');

const STATE_WORDS = {
  done: 'Done',
  'needs-you': 'Needs you',
  'agent-on-it': 'Your agent is on it',
  waiting: 'Waiting for an agent',
  'not-yet': 'Not yet',
  optional: 'Optional',
  'not-on-plan': 'Not on your GitHub plan',
};

const handleLine = (h) => (h.kind === 'link' ? `${h.label}: ${h.href}` : h.kind === 'copy' ? `${h.label}: ${h.words}` : h.label);

function itemLines(i) {
  const turn = i.turn ? `, ${i.turn.words}` : '';
  return [`${i.title} (${STATE_WORDS[i.state]}${turn})`, `  ${i.say}`, ...i.fields.map((f) => `  ${f.label}: ${f.value}`), ...i.handles.map((h) => `  ${handleLine(h)}`)];
}

function setupLines(r) {
  const head = r.complete ? 'Setup is done.' : (r.briefLine ?? `Setup: ${r.done} of ${r.total} done.`);
  const advice = r.advice.length ? ['', 'Advice', ...r.advice.flatMap((a) => [`  ${a.say}`, `  ${handleLine(a.handle)}`])] : [];
  return [head, '', ...r.items.flatMap((i) => [...itemLines(i), '']).slice(0, -1), ...advice];
}

// readSetup(fetchFn, base, repo, token) -> { ok, text, reading? }
async function readSetup(fetchFn, url, repo, token) {
  let res;
  try {
    res = await fetchFn(`${url.replace(/\/$/, '')}/v1/repos/${repo}/setup`, { headers: { accept: 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) } });
  } catch {
    return { ok: false, text: 'SipNShip could not be reached. Setup carries on through your agent; the checklist is back when SipNShip is.' };
  }
  const body = await res.json().catch(() => undefined);
  if (!res.ok || !body || !Array.isArray(body.items)) return { ok: false, text: (body && body.say) || 'SipNShip could not read the setup checklist.' };
  return { ok: true, reading: body, text: setupLines(body).join('\n') };
}

// setup({ repo }): prints the checklist; 0 when read, 1 when not, 2 when no repository is known.
async function setup({ repo, env = process.env, out = process.stdout, cwd = process.cwd(), fetchFn = (u, i) => fetch(u, { ...i, signal: AbortSignal.timeout(15000) }) } = {}) {
  const fullName = repo || remoteRepo(cwd);
  if (!fullName || !/^[^/\s]+\/[^/\s]+$/.test(fullName)) {
    out.write('Name the repository: sipnship setup --repo OWNER/NAME\n');
    return 2;
  }
  // The signed-in token of the connected machine, when there is one; the service says what it shows without it.
  const entry = tokens.find(fullName, env);
  const answer = await readSetup(fetchFn, base(env), fullName, entry && entry.token);
  out.write(`${answer.text}\n`);
  return answer.ok ? 0 : 1;
}

module.exports = { setup, readSetup, setupLines, itemLines, STATE_WORDS };

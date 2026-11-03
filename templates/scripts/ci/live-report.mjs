#!/usr/bin/env node
// The Live check's helper: finds what is failing in the app a project has
// deployed, says it in plain words, and sends only the findings that count.
//
//   node scripts/ci/live-report.mjs [--plan] [--dry]
//
// It reads two things with the deploy's own Cloudflare token
// (CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID), on the builder's own runner:
//   A. the app's one-line refusal records (templates/live/live-problem.ts) in
//      Workers Logs, asking for lines that carry the mark and nothing else;
//   B. each Worker's request counts for the last hour from Workers analytics.
// It applies the counting rules below, so a blip never leaves the machine,
// and sends the findings to the SipNShip service (POST /v1/repos/ID/live)
// with LIVE_SERVICE_TOKEN and LIVE_REPO_ID (the Live workflow signs in with
// scripts/ci/service-auth.sh). It writes the same sentences to the run's
// summary and as one notice, and it always exits 0: a failing app is not a
// failing check. A send that fails is said once.
//
// What is sent: kind, service, feature, status, reason code, the Google
// project number, times, counts, a Worker's name. Never a path, an address,
// a body, a provider's message, a prompt, a key or log text.
//
// The counting rules are the same as the service's (packages/core in the
// SipNShip repository: live-problems.ts and refusal-kind.ts), copied here
// because the plugin has no build. Change them in both places.

import fs from 'node:fs';

const MINUTE = 60_000;
export const RULES = {
  lastingCount: 3,
  lastingWindowMs: 60 * MINUTE,
  lastingSpreadMs: 2 * MINUTE,
  passingShare: 0.2,
  passingWindowMs: 15 * MINUTE,
  passingMinFailures: 10,
  ownShare: 0.05,
  ownMinFailures: 20,
  partMinCalls: 3,
  deployGraceMs: 2 * MINUTE,
  hourMs: 60 * MINUTE,
};

const BY_REASON = {
  SERVICE_DISABLED: 'not_switched_on', API_DISABLED: 'not_switched_on',
  API_KEY_INVALID: 'key_not_accepted', API_KEY_EXPIRED: 'key_not_accepted', API_KEY_NOT_FOUND: 'key_not_accepted',
  ACCESS_TOKEN_EXPIRED: 'key_not_accepted', UNAUTHENTICATED: 'key_not_accepted', invalid_grant: 'key_not_accepted',
  invalid_client: 'key_not_accepted', unauthorized_client: 'key_not_accepted', invalid_api_key: 'key_not_accepted',
  authentication_error: 'key_not_accepted',
  IAM_PERMISSION_DENIED: 'not_allowed', PERMISSION_DENIED: 'not_allowed', API_KEY_SERVICE_BLOCKED: 'not_allowed',
  API_KEY_HTTP_REFERRER_BLOCKED: 'not_allowed', API_KEY_IP_ADDRESS_BLOCKED: 'not_allowed', CONSUMER_SUSPENDED: 'not_allowed',
  BILLING_DISABLED: 'billing', insufficient_quota: 'billing',
  RESOURCE_EXHAUSTED: 'quota', QUOTA_EXCEEDED: 'quota',
  RATE_LIMIT_EXCEEDED: 'slow_down', rate_limit_exceeded: 'slow_down', rate_limit: 'slow_down',
};
const LASTING = new Set(['not_switched_on', 'key_not_accepted', 'not_allowed', 'billing', 'quota']);

/** The kind of one refusal: the provider's reason code wins, then the status. */
export function refusalKind(status, reason) {
  const known = reason ? BY_REASON[reason] : undefined;
  if (known) return known;
  const s = String(status);
  if (s === 'timeout' || s === 'unreachable') return 'unreachable';
  const n = Number(s);
  if (n === 401) return 'key_not_accepted';
  if (n === 402) return 'billing';
  if (n === 429) return 'slow_down';
  if (n >= 500 && n <= 599) return 'provider_trouble';
  return 'refused';
}

const MARK = 'sipnship live/1';
const FIELD = /(\w+)=(\S+)/g;

/** One refusal line read back, or undefined when it is not ours or holds a value off its pattern. */
export function parseRefusalLine(text, at) {
  const i = String(text).indexOf(MARK);
  if (i < 0) return undefined;
  const f = {};
  for (const m of String(text).slice(i + MARK.length).matchAll(FIELD)) f[m[1]] = m[2];
  const { service, feature, status, reason, account, count } = f;
  if (!service || !/^[a-z0-9][a-z0-9.-]{0,39}$/.test(service)) return undefined;
  if (!feature || !/^[a-z0-9-]{1,40}$/.test(feature)) return undefined;
  if (!status || !/^(\d{3}|timeout|unreachable|error)$/.test(status)) return undefined;
  if (reason !== undefined && !/^[A-Za-z0-9._]{1,40}$/.test(reason)) return undefined;
  if (account !== undefined && !/^\d{1,20}$/.test(account)) return undefined;
  const n = Number(count ?? 1);
  if (!Number.isInteger(n) || n < 1 || n > 1_000_000) return undefined;
  return { at, service, feature, status, ...(reason ? { reason } : {}), ...(account ? { account } : {}), count: n };
}

const inDeploy = (at, deploys = []) => deploys.some((d) => at >= d && at <= d + RULES.deployGraceMs);

/**
 * The causes that count right now, worst first. An outside service refusing
 * for one reason is one cause however many features it touches; each carries
 * its features with their own counts and times.
 */
export function refusalCauses(events, { now, callsByService = {}, deploys = [] }) {
  const live = events.filter((e) => !e.recovered && e.at <= now && now - e.at <= RULES.lastingWindowMs && !inDeploy(e.at, deploys));
  const groups = new Map();
  for (const e of live) {
    const kind = refusalKind(e.status, e.reason);
    const id = `${e.service}:${kind}:${e.reason ?? '-'}`;
    const c = groups.get(id) ?? { id, service: e.service, kind, reason: e.reason, account: e.account, status: e.status, features: new Map(), failures: 0, first: e.at, last: e.at };
    c.failures += e.count;
    c.first = Math.min(c.first, e.at);
    c.last = Math.max(c.last, e.at);
    c.account ??= e.account;
    const ft = c.features.get(e.feature) ?? { failures: 0, first: e.at, last: e.at };
    ft.failures += e.count;
    ft.first = Math.min(ft.first, e.at);
    ft.last = Math.max(ft.last, e.at);
    c.features.set(e.feature, ft);
    groups.set(id, c);
  }
  const counts = (c) => {
    if (LASTING.has(c.kind)) return c.failures >= RULES.lastingCount && c.last - c.first >= RULES.lastingSpreadMs;
    const recent = live.filter((e) => e.service === c.service && refusalKind(e.status, e.reason) === c.kind && now - e.at <= RULES.passingWindowMs);
    const failed = recent.reduce((sum, e) => sum + e.count, 0);
    const calls = callsByService[c.service] ?? 0;
    return failed >= RULES.passingMinFailures && calls > 0 && failed / calls >= RULES.passingShare;
  };
  return [...groups.values()].filter(counts).sort((a, b) => b.failures - a.failures || a.id.localeCompare(b.id));
}

/** The app's own errors that count: a Worker over its share of an hour's requests. A user's own 4xx and a visitor who left never count. */
export function ownProblems(workers) {
  const out = [];
  for (const w of workers) {
    const failures = w.serverErrors + w.exceptions + w.limits;
    const counted = w.ok + w.serverErrors + w.exceptions + w.limits;
    const share = counted > 0 ? failures / counted : 0;
    if (failures >= RULES.ownMinFailures && share >= RULES.ownShare) out.push({ worker: w.worker, failures, requests: counted, share });
  }
  return out.sort((a, b) => b.share - a.share || a.worker.localeCompare(b.worker));
}

/** Whether this run looks: on the hour, ten to twenty minutes after a deploy finished, or by hand. */
export function livePlan({ now, deployedAt, manual = false }) {
  if (manual) return 'hourly';
  if (deployedAt && Number.isFinite(deployedAt)) {
    const age = now - deployedAt;
    if (age >= 10 * MINUTE && age < 20 * MINUTE) return 'after-deploy';
  }
  return new Date(now).getUTCMinutes() < 10 ? 'hourly' : 'skip';
}

/** What a Cloudflare analytics row's outcome means for the counting rules. */
export function outcomeKind(status) {
  switch (status) {
    case 'success': return 'ok';
    case 'clientDisconnected': case 'responseStreamDisconnected': return 'canceled';
    case 'scriptThrewException': return 'exceptions';
    case 'exceededResources': case 'exceededCpu': case 'exceededMemory': case 'exceededSubrequests': return 'limits';
    case 'internalError': case 'unknown': return 'serverErrors';
    default: return 'ok';
  }
}

const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');

/** The findings that count, in the shape the service takes. */
export function buildFindings({ causes, own, callsByWorker = {} }) {
  const out = [];
  for (const c of causes) {
    for (const [feature, f] of c.features) {
      out.push({ kind: 'refusal', service: c.service, feature, status: c.status, ...(c.reason ? { reason: c.reason } : {}), ...(c.account ? { account: c.account } : {}), first: iso(f.first), last: iso(f.last), failures: Math.min(f.failures, 100_000_000) });
    }
  }
  for (const p of own) {
    const calls = callsByWorker[p.worker];
    out.push({ kind: 'own', worker: p.worker, first: iso(p.first), last: iso(p.last), failures: p.failures, ...(calls !== undefined ? { calls: p.requests } : {}) });
  }
  return out.slice(0, 200);
}

const clock = (ms) => new Date(ms).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });

/** The plain sentences for a look: what is failing, or that nothing is. */
export function sentences({ causes, own, now, logsReadable }) {
  const lines = [];
  for (const c of causes) {
    const what = [...c.features.keys()].join(', ');
    lines.push(`An outside service your app calls (${c.service}) refused ${what} ${c.failures} times since ${clock(c.first)}${c.reason ? `, reason ${c.reason}` : ''}.`);
  }
  for (const p of own) lines.push(`Your app's ${p.worker} failed on ${Math.round(p.share * 100)}% of its requests in the last hour (${p.failures} of ${p.requests}).`);
  if (!lines.length) lines.push(`Your app is working. Last looked at ${clock(now)}.`);
  if (logsReadable === false) lines.push('The deploy token cannot read the app\'s logs, so outside services refusing your app cannot be seen. Allow it Workers Observability: Read on the token.');
  return lines;
}

const CF = 'https://api.cloudflare.com/client/v4';
const get = async (fetchFn, url, init) => {
  const res = await fetchFn(url, { ...init, signal: AbortSignal.timeout(15_000) });
  const body = await res.json().catch(() => ({}));
  return { status: res.status, body };
};

/** The last hour's refusal lines, asked for by their mark alone. `readable` is false when the token may not read logs. */
export async function readLogs({ fetchFn, account, token, now }) {
  const { status, body } = await get(fetchFn, `${CF}/accounts/${account}/workers/observability/telemetry/query`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({
      queryId: 'sipnship-live',
      timeframe: { from: now - RULES.hourMs, to: now },
      view: 'events',
      limit: 2000,
      parameters: { filters: [{ key: '$metadata.message', operation: 'includes', type: 'string', value: MARK }] },
    }),
  });
  if (status === 401 || status === 403) return { readable: false, events: [] };
  if (status >= 300) return { readable: false, events: [] };
  const list = body?.result?.events?.events ?? body?.result?.events ?? [];
  const events = [];
  for (const e of Array.isArray(list) ? list : []) {
    const text = e?.$metadata?.message ?? e?.source?.message ?? e?.message ?? (typeof e?.source === 'string' ? e.source : '');
    const at = Number(e?.timestamp ?? e?.$metadata?.timestamp ?? now);
    const ev = parseRefusalLine(text, Number.isFinite(at) ? at : now);
    if (ev) events.push(ev);
  }
  return { readable: true, events };
}

const GQL = 'query($acc:String!,$name:String!,$from:Time!,$to:Time!){viewer{accounts(filter:{accountTag:$acc}){workersInvocationsAdaptive(limit:100,filter:{scriptName:$name,datetime_geq:$from,datetime_leq:$to}){sum{requests subrequests} dimensions{status}}}}}';

/** One Worker's last hour by outcome, or undefined when analytics cannot be read. */
export async function readWorker({ fetchFn, account, token, worker, now }) {
  const { status, body } = await get(fetchFn, `${CF}/graphql`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ query: GQL, variables: { acc: account, name: worker, from: new Date(now - RULES.hourMs).toISOString(), to: new Date(now).toISOString() } }),
  });
  if (status >= 300 || body?.errors?.length) return undefined;
  const rows = body?.data?.viewer?.accounts?.[0]?.workersInvocationsAdaptive ?? [];
  const w = { worker, ok: 0, clientErrors: 0, canceled: 0, serverErrors: 0, exceptions: 0, limits: 0, subrequests: 0 };
  for (const r of rows) {
    w[outcomeKind(r?.dimensions?.status)] += Number(r?.sum?.requests ?? 0);
    w.subrequests += Number(r?.sum?.subrequests ?? 0);
  }
  return w;
}

/** The Worker names in deploy order: each folder's wrangler.toml name, else the folder's own name. */
export function workerNames(deployJson, readFile = (p) => fs.readFileSync(p, 'utf8')) {
  let folders = [];
  try { folders = JSON.parse(deployJson).workers ?? []; } catch { /* none listed */ }
  return folders.map((dir) => {
    try {
      const m = readFile(`${dir}/wrangler.toml`).match(/^name\s*=\s*"([^"]+)"/m);
      if (m) return m[1];
    } catch { /* fall back */ }
    return String(dir).split('/').pop();
  });
}

/**
 * One look. Everything outside is passed in so a test feeds fixture answers.
 * Returns { findings, lines, sent } and never throws.
 */
export async function look({ env, fetchFn, now, log = () => {}, workers = [], deploys = [], write = () => {} }) {
  const token = env.CLOUDFLARE_API_TOKEN;
  const account = env.CLOUDFLARE_ACCOUNT_ID;
  let logsReadable;
  let events = [];
  const counts = [];
  if (token && account) {
    try {
      const r = await readLogs({ fetchFn, account, token, now });
      logsReadable = r.readable;
      events = r.events;
    } catch { logsReadable = false; }
    for (const name of workers) {
      try { const w = await readWorker({ fetchFn, account, token, worker: name, now }); if (w) counts.push(w); } catch { /* skipped */ }
    }
  } else {
    log('CLOUDFLARE_API_TOKEN or CLOUDFLARE_ACCOUNT_ID is not set, so the live app cannot be read.');
    logsReadable = false;
  }
  // The provider calls the app made in the quarter hour are the Workers' subrequests: a share against them can only be too low, never too high.
  const subs = counts.reduce((sum, w) => sum + w.subrequests, 0);
  const services = new Set(events.map((e) => e.service));
  const callsByService = Object.fromEntries([...services].map((s) => [s, subs]));
  const causes = refusalCauses(events, { now, callsByService, deploys });
  const own = ownProblems(counts).map((p) => ({ ...p, first: now - RULES.hourMs, last: now }));
  const findings = buildFindings({ causes, own, callsByWorker: Object.fromEntries(counts.map((w) => [w.worker, true])) });
  const lines = sentences({ causes, own, now, logsReadable });
  write(lines);

  let sent = false;
  if (env.LIVE_SERVICE_TOKEN && env.LIVE_REPO_ID) {
    try {
      const res = await fetchFn(`${env.SIPNSHIP_URL || 'https://sipnship.dev'}/v1/repos/${env.LIVE_REPO_ID}/live`, {
        method: 'POST',
        headers: { authorization: `Bearer ${env.LIVE_SERVICE_TOKEN}`, 'content-type': 'application/json' },
        body: JSON.stringify({ at: iso(now), ...(logsReadable !== undefined ? { logsReadable } : {}), findings }),
        signal: AbortSignal.timeout(5000),
      });
      sent = res.ok;
      if (!res.ok) log(`SipNShip did not take the findings (it answered ${res.status}). The next look sends them again.`);
    } catch {
      log('SipNShip could not be reached, so the findings stay in this run. The next look sends them again.');
    }
  } else {
    log('No SipNShip sign-in here, so the findings stay in this run.');
  }
  return { findings, lines, sent, logsReadable };
}

async function main() {
  const env = process.env;
  const now = Date.now();
  const flags = process.argv.slice(2);
  if (flags.includes('--plan')) {
    const deployedAt = Date.parse(env.LIVE_DEPLOYED_AT || '');
    process.stdout.write(`${livePlan({ now, deployedAt, manual: env.GITHUB_EVENT_NAME === 'workflow_dispatch' })}\n`);
    return;
  }
  let deployJson = '{}';
  try { deployJson = fs.readFileSync('.claude/deploy.json', 'utf8'); } catch { /* none */ }
  const deploys = String(env.LIVE_DEPLOYS || '').split(',').map((s) => Date.parse(s)).filter(Number.isFinite);
  const r = await look({
    env: flags.includes('--dry') ? { ...env, LIVE_SERVICE_TOKEN: '' } : env,
    fetchFn: fetch,
    now,
    workers: workerNames(deployJson),
    deploys,
    log: (s) => process.stdout.write(`${s}\n`),
    write: (lines) => {
      if (env.GITHUB_STEP_SUMMARY) { try { fs.appendFileSync(env.GITHUB_STEP_SUMMARY, `### Your live app\n\n${lines.map((l) => `- ${l}`).join('\n')}\n`); } catch { /* summary is a courtesy */ } }
      process.stdout.write(`::notice title=Your live app::${lines.join(' ')}\n`);
    },
  });
  process.stdout.write(`${r.findings.length} finding(s)${r.sent ? ' sent' : ''}.\n`);
}

if (import.meta.url === `file://${process.argv[1].replace(/\\/g, '/')}` || process.argv[1]?.endsWith('live-report.mjs')) {
  main().catch((e) => { process.stdout.write(`The live check stopped early: ${e?.message ?? 'unknown'}\n`); }).finally(() => process.exit(0));
}

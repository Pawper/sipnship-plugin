'use strict';
// Delivery: how work moves through the project, read from what GitHub
// already records (CI runs and their jobs, pull requests, main's history)
// and from the local files the plugin keeps (the queue log, the hook log).
// Nothing is collected or sent anywhere; this reads, sums and says.
//
// gather(root) does the reading, over REST only (gh api), with a short
// cache so a page left open does not spend the API budget. Everything
// after it is pure: summarize(raw, now) and queueView(raw) turn the raw
// reads into the numbers and the queue picture the page draws.

const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');

const DAY = 86400000;
const WINDOW_DAYS = 14;

// ---------- pure helpers

function ms(a, b) {
  const x = Date.parse(a); const y = Date.parse(b);
  return Number.isFinite(x) && Number.isFinite(y) && y >= x ? y - x : null;
}

function median(xs) {
  const v = xs.filter((x) => x != null).sort((a, b) => a - b);
  if (!v.length) return null;
  const m = Math.floor(v.length / 2);
  return v.length % 2 ? v[m] : (v[m - 1] + v[m]) / 2;
}

function pct(xs, p) {
  const v = xs.filter((x) => x != null).sort((a, b) => a - b);
  if (!v.length) return null;
  return v[Math.min(v.length - 1, Math.ceil((p / 100) * v.length) - 1)];
}

// minutes(MS): "4 min", "1 h 10 min", "under a minute"; "no data" for null.
function minutes(x) {
  if (x == null) return 'no data';
  const m = Math.round(x / 60000);
  if (m < 1) return 'under a minute';
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60); const r = m % 60;
  if (h < 48) return r ? `${h} h ${r} min` : `${h} h`;
  return `${Math.round(h / 24)} days`;
}

// rollup(CHECK_RUNS): one word for a commit's checks, as the queue reads
// them: red on any failure, pending while any runs, green when all passed
// or were skipped, cancelled when only cancellations stand in the way.
function rollup(all) {
  if (!all || !all.length) return 'none';
  // Only each check's newest attempt counts: GitHub lists every attempt on
  // a commit, so a red run that was re-run kept the dot red while the new
  // run was still going.
  const newest = {};
  all.forEach((r, i) => {
    const k = r.name || `#${r.id || i}`;
    const at = Date.parse(r.started_at || '') || r.id || 0;
    if (!newest[k] || at >= newest[k].at) newest[k] = { at, r };
  });
  const runs = Object.values(newest).map((x) => x.r);
  const bad = ['failure', 'timed_out', 'startup_failure', 'action_required'];
  if (runs.some((r) => bad.includes(r.conclusion))) return 'red';
  if (runs.some((r) => r.status !== 'completed')) return 'pending';
  if (runs.some((r) => r.conclusion === 'cancelled')) return 'cancelled';
  return 'green';
}

// batchMembers(BODY): the "- #N title" lines of a batch pull request.
function batchMembers(body) {
  const out = [];
  String(body || '').replace(/\r/g, '').split('\n').forEach((l) => {
    const m = /^- #(\d+) /.exec(l);
    if (m) out.push(Number(m[1]));
  });
  return out;
}

// mergedNumber(MESSAGE): the pull request a commit on main landed, from
// "Title (#123)" or "Merge pull request #123"; null for a direct commit.
function mergedNumber(message) {
  const first = String(message || '').split('\n')[0];
  let m = /\(#(\d+)\)/.exec(first);
  if (m) return Number(m[1]);
  m = /^Merge pull request #(\d+)/.exec(first);
  return m ? Number(m[1]) : null;
}

// serialReason(MESSAGE): the reason in "[serial: X]", or null.
function serialReason(message) {
  const m = /\[serial: ([^\]]+)\]/.exec(String(message || '').split('\n')[0]);
  return m ? m[1] : null;
}

// redSpells(PUSH_RUNS): main's red spells from its push runs, oldest
// first: each spell starts at a failed run and ends at the next green one.
function redSpells(runs, now) {
  const done = runs.filter((r) => r.status === 'completed' && ['success', 'failure'].includes(r.conclusion))
    .sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at));
  const spells = []; let start = null;
  done.forEach((r) => {
    if (r.conclusion === 'failure' && start == null) start = r.created_at;
    if (r.conclusion === 'success' && start != null) { spells.push({ from: start, to: r.updated_at }); start = null; }
  });
  if (start != null) spells.push({ from: start, to: null, open: true, length: ms(start, new Date(now).toISOString()) });
  spells.forEach((s) => { if (s.length == null) s.length = ms(s.from, s.to); });
  return spells;
}

function within(iso, now, days) {
  const t = Date.parse(iso);
  return Number.isFinite(t) && now - t <= days * DAY && t <= now;
}

// trend(THIS, BEFORE): "faster", "slower" or "steady", by 25%.
function trend(a, b) {
  if (a == null || b == null || b === 0) return null;
  if (a > b * 1.25) return 'slower';
  if (a < b * 0.8) return 'faster';
  return 'steady';
}

// summarize(RAW, NOW): the numbers the Delivery section shows, and the
// plain lines it says when something got worse. RAW is what gather read.
function summarize(raw, now) {
  const t = now || Date.now();
  const runs = (raw.runs || []).filter((r) => within(r.created_at, t, WINDOW_DAYS));
  const prRuns = runs.filter((r) => r.event === 'pull_request' && r.status === 'completed' && r.conclusion !== 'cancelled');
  const recent = prRuns.filter((r) => within(r.created_at, t, 7));
  const older = prRuns.filter((r) => !within(r.created_at, t, 7));
  const runLen = (r) => ms(r.created_at, r.updated_at);
  const ci = {
    count: prRuns.length,
    median: median(prRuns.map(runLen)),
    slow: pct(prRuns.map(runLen), 90),
    week: median(recent.map(runLen)),
    before: median(older.map(runLen)),
  };
  ci.trend = trend(ci.week, ci.before);

  const jobs = raw.jobs || [];
  let queued = 0; let ran = 0;
  const jobsPerRun = {};
  jobs.forEach((j) => {
    const q = ms(j.created_at, j.started_at); const r = ms(j.started_at, j.completed_at);
    if (q != null) queued += q;
    if (r != null) ran += r;
    jobsPerRun[j.run_id] = (jobsPerRun[j.run_id] || 0) + 1;
  });
  const runner = {
    sampled: Object.keys(jobsPerRun).length,
    jobsPerRun: median(Object.values(jobsPerRun)),
    queued, ran,
    share: queued + ran > 0 ? queued / (queued + ran) : null,
    online: raw.runners ? raw.runners.filter((r) => r.status === 'online').length : null,
    busy: raw.runners ? raw.runners.filter((r) => r.busy).length : null,
    total: raw.runners ? raw.runners.length : null,
  };

  const merged = (raw.closed || []).filter((p) => p.merged_at && within(p.merged_at, t, WINDOW_DAYS));
  const openToMerge = merged.map((p) => ms(p.created_at, p.merged_at));
  const merges = {
    count: merged.length,
    median: median(openToMerge),
    slow: pct(openToMerge, 90),
    perDay: merged.length / WINDOW_DAYS,
  };

  const pushRuns = runs.filter((r) => r.event === 'push');
  const spells = redSpells(pushRuns, t);
  const main = {
    runs: pushRuns.filter((r) => r.status === 'completed').length,
    red: pushRuns.filter((r) => r.conclusion === 'failure').length,
    spells: spells.length,
    longest: spells.reduce((m, s) => Math.max(m, s.length || 0), 0) || null,
    redNow: spells.some((s) => s.open),
    redFor: (spells.find((s) => s.open) || {}).length || null,
  };

  const commits = (raw.mainCommits || []).filter((c) => within(c.date, t, WINDOW_DAYS));
  const reasons = {};
  let serial = 0; let batches = 0;
  commits.forEach((c) => {
    const why = serialReason(c.message);
    if (why) { serial += 1; reasons[why] = (reasons[why] || 0) + 1; }
    if (/^Batch \d{4}-\d{2}-\d{2}/.test(c.message) || /\/batch-\d{4}-\d{2}-\d{2}/.test(c.message)) batches += 1;
  });
  const queue = { serial, batches, reasons, flaky: (raw.flaky || []).length };

  const hooks = {};
  (raw.hookLog || []).forEach((h) => { if (within(h.at, t, WINDOW_DAYS)) hooks[h.hook] = (hooks[h.hook] || 0) + 1; });
  const resolution = resolutionFeed(raw.hookLog || [], raw.hookResolved || [], t);

  const say = [];
  if (resolution.workarounds) say.push(`${resolution.workarounds} refusal${resolution.workarounds === 1 ? ' was' : 's were'} followed by a possible workaround: the agent may have reached the same effect another way. See the hook feed.`);
  if (main.redNow) say.push(`Main is red, and has been for ${minutes(main.redFor)}. Nothing else should merge until it is fixed.`);
  if (runner.share != null && runner.share > 0.5) say.push(`Jobs spent ${Math.round(runner.share * 100)}% of their time waiting for a runner. Add a runner, or run fewer jobs a pull request.`);
  if (ci.trend === 'slower') say.push(`CI got slower this week: ${minutes(ci.week)} a pull request, against ${minutes(ci.before)} the week before.`);
  if (runner.total > 0 && runner.online < Math.min(2, runner.total || 2)) say.push(`${runner.online} of ${runner.total} runners are online. Jobs wait while they are offline.`);
  if (serial > 0 && serial > batches * 2 && serial >= 3) say.push(`${serial} serial merges against ${batches} batches. Most pull requests could have landed together with --drain.`);
  return { windowDays: WINDOW_DAYS, ci, runner, merges, main, queue, hooks, resolution, say, read: raw.read || [] };
}

// runnerLanes(RUNNERS, ACTIVE_JOBS, OPEN): one lane per runner: its
// name, online or not, and the job it is running with the pull request
// the job belongs to; plus how many jobs wait for a runner. ACTIVE_JOBS
// are the jobs of runs not yet finished, from GitHub's run jobs list.
function runnerLanes(runners, jobs, open) {
  const byHead = {};
  const batchHeads = new Set();
  (open || []).forEach((p) => {
    byHead[p.head] = p.number;
    if (/<!-- merge-queue:batch -->/.test(p.body || '') || /^One integration run for the pull requests below/.test(p.body || '')) batchHeads.add(p.head);
  });
  // A job a runner has taken: anything not finished that names the runner.
  // Matching only "in_progress" missed a pull request's checks job in the
  // moment between being assigned and starting, and the lane said "busy".
  // A job still listed as queued but already naming its runner is taken:
  // GitHub flags the runner busy before the job's status moves on.
  const taken = (jobs || []).filter((j) => j.status !== 'completed' && j.runner_name);
  const describe = (j) => ({
    name: j.name,
    workflow: j.workflow_name || null,
    pr: byHead[j.head_branch] || null,
    branch: j.head_branch,
    batch: batchHeads.has(j.head_branch),
  });
  const lanes = (runners || []).map((r) => {
    const j = taken.find((x) => x.runner_name === r.name);
    return {
      name: r.name,
      status: r.status === 'online' ? (j || r.busy ? 'busy' : 'idle') : 'offline',
      job: j ? describe(j) : null,
    };
  });
  // The summary check ("CI passed") waits for the other jobs; it is the
  // gate, not work. It joins the waiting line only when nothing else in
  // its run is left to do.
  const summary = process.env.QUEUE_SUMMARY_CHECK || 'CI passed';
  const pendingIn = (runId, self) => (jobs || []).some((x) => x !== self && x.run_id === runId && x.status !== 'completed');
  const waiting = (jobs || []).filter((j) => j.status === 'queued' && !j.runner_name)
    .filter((j) => j.name !== summary || !pendingIn(j.run_id, j))
    .map(describe);
  return { lanes, waiting, queued: waiting.length };
}

// resolutionFeed(REFUSALS, RESOLVED, NOW): what agents did after each
// refusal, from the hook log and the resolution log. Per hook, how many
// were followed, retried, asked, stopped, moved on or worked around, and
// the newest twenty, newest first. A refusal nothing settled yet is open.
const OUTCOMES = ['followed', 'asked', 'retried', 'moved on', 'stopped', 'workaround', 'open'];
function resolutionFeed(refusals, resolved, now) {
  const out = {};
  resolved.forEach((r) => { out[r.id] = r.outcome; });
  const recent = refusals.filter((h) => within(h.at, now, WINDOW_DAYS))
    .map((h) => ({ at: h.at, hook: h.hook, outcome: out[h.id || h.at] || 'open' }));
  const byHook = {};
  recent.forEach((r) => {
    const b = byHook[r.hook] || (byHook[r.hook] = { total: 0 });
    b.total += 1; b[r.outcome] = (b[r.outcome] || 0) + 1;
  });
  Object.values(byHook).forEach((b) => {
    const settled = b.total - (b.open || 0);
    b.followRate = settled ? (b.followed || 0) / settled : null;
  });
  return { byHook, feed: recent.slice(-20).reverse(), workarounds: recent.filter((r) => r.outcome === 'workaround').length };
}

// queueView(RAW): the merge queue as three columns. Open pull requests
// waiting their turn; the members of an open batch, with the batch's CI
// progress; and the last pull requests to land on main.
function queueView(raw) {
  const open = raw.open || [];
  // A batch is known by the queue's marker in its body, never its branch.
  const isBatch = (p) => /<!-- merge-queue:batch -->/.test(p.body || '') || /^One integration run for the pull requests below/.test(p.body || '');
  const batches = open.filter(isBatch);
  const inBatch = new Set();
  const batch = batches.length ? (() => {
    const b = batches[0];
    const members = batchMembers(b.body);
    members.forEach((n) => inBatch.add(n));
    return {
      number: b.number, title: b.title, state: b.state,
      done: b.jobsDone, total: b.jobsTotal,
      members: members.map((n) => open.find((p) => p.number === n) || { number: n, title: `#${n}`, state: b.state }),
    };
  })() : null;
  const waiting = open.filter((p) => !isBatch(p) && !inBatch.has(p.number))
    .map((p) => ({ ...p, state: p.draft ? 'draft' : p.state }));
  const landed = (raw.mainCommits || []).map((c) => ({ number: mergedNumber(c.message), title: c.message.split('\n')[0], at: c.date, serial: serialReason(c.message) }))
    .filter((c, i, all) => c.number != null && all.findIndex((x) => x.number === c.number) === i).slice(0, 6);
  const r = raw.runners ? runnerLanes(raw.runners, raw.activeJobs, open) : null;
  return { open: waiting, batch, main: landed, checking: raw.checking || [], clashes: raw.clashes || [], runners: r ? r.lanes : null, waiting: r ? r.waiting : null, queued: r ? r.queued : null };
}

// ---------- reading (the one impure part)

function gh(root, args) {
  return new Promise((resolve) => {
    execFile('gh', ['api', ...args], { cwd: root, maxBuffer: 32 * 1024 * 1024, windowsHide: true, timeout: 30000 }, (err, out) => {
      if (err) return resolve(null);
      try { resolve(JSON.parse(out)); } catch (e) { resolve(null); }
    });
  });
}

function readLines(file) {
  try { return fs.readFileSync(file, 'utf8').replace(/\r/g, '').split('\n').filter(Boolean); } catch (e) { return []; }
}

function hasGithubRemote(root) {
  try {
    const cfg = fs.readFileSync(path.join(root, '.git', 'config'), 'utf8');
    return /github\.com[:/]/.test(cfg);
  } catch (e) {
    // a worktree's .git is a file; let gh decide
    return fs.existsSync(path.join(root, '.git'));
  }
}

const cache = new Map();

// gather(ROOT, {fresh, queueOnly}): read GitHub and the local files.
// Cached for a minute (the queue) and five (the rest), so a page left open
// costs a handful of calls a minute at most.
async function gather(root, opts) {
  const o = opts || {};
  const key = `${root}|${o.queueOnly ? 'q' : 'all'}`;
  const hit = cache.get(key);
  const life = o.queueOnly ? 20000 : 300000;
  if (hit && !o.fresh && Date.now() - hit.at < life) return hit.raw;

  const raw = { read: [] };
  if (!hasGithubRemote(root)) {
    raw.read.push('This folder has no GitHub remote, so there is nothing to read from GitHub.');
  } else {
    const workflow = process.env.QUEUE_CI_WORKFLOW || 'ci.yml';
    const openP = gh(root, ['repos/{owner}/{repo}/pulls?state=open&per_page=100']);
    const commitsP = gh(root, ['repos/{owner}/{repo}/commits?per_page=60']);
    const [open, commits] = await Promise.all([openP, commitsP]);
    if (!open) raw.read.push('GitHub could not be read just now (signed out, offline or rate-limited).');
    raw.mainCommits = (commits || []).map((c) => ({ sha: c.sha, message: c.commit.message, date: c.commit.committer.date }));
    raw.open = await Promise.all((open || []).map(async (p) => {
      const [checks, one] = await Promise.all([
        gh(root, [`repos/{owner}/{repo}/commits/${p.head.sha}/check-runs?per_page=100`]),
        // mergeable_state is only on the single pull request; "dirty" is a
        // conflict with its base
        p.draft ? null : gh(root, [`repos/{owner}/{repo}/pulls/${p.number}`]),
      ]);
      const dirty = one && one.mergeable_state === 'dirty';
      const list = (checks && checks.check_runs) || [];
      const summary = list.find((c) => c.name === (process.env.QUEUE_SUMMARY_CHECK || 'CI passed'));
      return {
        number: p.number, title: p.title, author: p.user && p.user.login, draft: p.draft,
        head: p.head.ref, base: p.base.ref, created: p.created_at, url: p.html_url, body: p.body || '',
        state: dirty ? 'mainconflict' : rollup(list),
        conflict: dirty ? `Conflicts with ${p.base.ref}; not eligible for a batch until its owner merges ${p.base.ref} in and fixes it.` : undefined,
        summary: summary ? (summary.status === 'completed' ? summary.conclusion : summary.status) : 'not run',
        jobsDone: list.filter((c) => c.status === 'completed').length,
        jobsTotal: list.length,
      };
    }));
    // What each runner is doing: the jobs of every run not finished, of any
    // event (a pull request, a push, a workflow_run like a store upload,
    // a schedule), read on the same tick as the runners' busy flags. A
    // busy runner no job names is read once more, since a job can start
    // between two reads; one still unmatched is said as such.
    const unfinished = ['in_progress', 'queued', 'waiting', 'requested', 'pending'];
    const readJobs = async () => {
      const lists = await Promise.all(unfinished.map((st) => gh(root, [`repos/{owner}/{repo}/actions/runs?per_page=50&status=${st}`])));
      const seen = new Set();
      const runs = [];
      lists.forEach((l) => ((l && l.workflow_runs) || []).forEach((r) => { if (!seen.has(r.id)) { seen.add(r.id); runs.push(r); } }));
      const jobLists = await Promise.all(runs.slice(0, 30).map((r) => gh(root, [`repos/{owner}/{repo}/actions/runs/${r.id}/jobs?filter=latest&per_page=100`])));
      const jobs = [];
      jobLists.forEach((l) => ((l && l.jobs) || []).forEach((j) => jobs.push(j)));
      return jobs;
    };
    const [runnersNow, firstJobs] = await Promise.all([gh(root, ['repos/{owner}/{repo}/actions/runners']), readJobs()]);
    raw.runners = runnersNow && runnersNow.runners ? runnersNow.runners : null;
    raw.activeJobs = firstJobs;
    const named = (jobs) => new Set(jobs.filter((j) => j.status !== 'completed' && j.runner_name).map((j) => j.runner_name));
    if ((raw.runners || []).some((r) => r.busy && !named(raw.activeJobs).has(r.name))) raw.activeJobs = await readJobs();
    if (!o.queueOnly) {
      const since = new Date(Date.now() - WINDOW_DAYS * DAY).toISOString().slice(0, 10);
      const [runs, closed] = await Promise.all([
        gh(root, [`repos/{owner}/{repo}/actions/workflows/${workflow}/runs?per_page=100&created=>=${since}`]),
        gh(root, ['repos/{owner}/{repo}/pulls?state=closed&sort=updated&direction=desc&per_page=100']),
      ]);
      raw.runs = (runs && runs.workflow_runs) || [];
      raw.closed = closed || [];
      if (!raw.runners) raw.read.push('Runners need an admin token to list; their numbers are left out.');
      // Jobs of the last 15 pull request runs: enough to see queue time
      // against run time without a call for every run.
      const sample = raw.runs.filter((r) => r.event === 'pull_request' && r.status === 'completed').slice(0, 15);
      const jobLists = await Promise.all(sample.map((r) => gh(root, [`repos/{owner}/{repo}/actions/runs/${r.id}/jobs?per_page=100`])));
      raw.jobs = [];
      jobLists.forEach((l, i) => ((l && l.jobs) || []).forEach((j) => raw.jobs.push({ ...j, run_id: sample[i].id })));
    }
  }
  // What the queue is doing now, from the file it keeps while it runs:
  // "checking 251 252 254" while it test-merges the batch's candidates.
  const now = readLines(path.join(root, '.scratch', 'queue', 'now'))[0] || '';
  // The pairs the last batch left out: "LEFT_OUT WITH", one a line.
  raw.clashes = readLines(path.join(root, '.scratch', 'queue', 'clashes')).map((l) => l.split(' ').map(Number)).filter((c) => c[0] && c[1]);
  raw.checking = /^checking /.test(now) ? now.split(' ').slice(1).map(Number).filter(Boolean) : [];
  raw.flaky = readLines(path.join(root, '.scratch', 'queue', 'flaky.tsv'));
  raw.hookLog = readLines(path.join(root, '.scratch', 'hooks.log')).map((l) => {
    const [at, hook, session, id] = l.split('\t');
    return { at, hook, session, id };
  }).filter((h) => h.hook);
  raw.hookResolved = readLines(path.join(root, '.scratch', 'hooks-resolved.log')).map((l) => {
    const [at, id, hook, session, outcome] = l.split('\t');
    return { at, id, hook, session, outcome };
  }).filter((r) => r.outcome);
  cache.set(key, { at: Date.now(), raw });
  return raw;
}

module.exports = {
  gather, summarize, queueView, runnerLanes, resolutionFeed, OUTCOMES,
  median, pct, minutes, rollup, batchMembers, mergedNumber, serialReason, redSpells, trend,
};

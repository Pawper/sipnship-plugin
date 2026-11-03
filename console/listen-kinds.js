'use strict';
// What each kind of request runs, and nothing else: one fixed script from
// the repository or the plugin, with the parameter the rule passed. The
// service never names a script. Every function answers { outcome, facts }
// with a core outcome word and the kind's own facts; nothing from a
// script's output is passed on. `ctx` is injected so tests run none of it:
//   exec(cmd, args, { cwd, timeoutMs }) -> { status, stdout }   (no shell)
//   elevated(file, args, timeoutMs)     -> exit code, 87 when Windows' prompt was refused, 'timeout' when unanswered
//   step(name)                          -> reports 'asking' or 'running'
//   root, fullName, sleep(ms), now(), home

const fs = require('fs');
const path = require('path');
const permissions = require('./permissions');
const { PERMISSION_IDS, SCAN_FOLDERS } = require('./request-rules');

const PROMPT_WAIT_MS = 10 * 60000;
const ONLINE_WAIT_MS = 5 * 60000;
const RUN_WAIT_MS = 30 * 60000;
const POLL_MS = 15000;
const PLUGIN_SCRIPT = path.join(__dirname, '..', 'scripts', 'machine', 'antivirus-exclusions.ps1');
const PR_TITLE = "Allow the agent the project's own commands";

const gh = (ctx, args) => ctx.exec('gh', args, { cwd: ctx.root, timeoutMs: 60000 });

async function elevatedRun(ctx, file, args, ms) {
  await ctx.step('asking');
  const code = await ctx.elevated(file, args, ms);
  if (code === 87) return { outcome: 'declined-windows', facts: {} };
  if (code === 'timeout') return { outcome: 'no-answer', facts: {} };
  await ctx.step('running');
  return code === 0 ? { ok: true } : { outcome: 'failed', facts: {} };
}

async function isAdmin(ctx) {
  const r = gh(ctx, ['api', `repos/${ctx.fullName}`, '--jq', '.permissions.admin']);
  return r.status === 0 && String(r.stdout).trim() === 'true';
}

// A name adds that one runner; digits add that many in one run, so Windows asks once for all of them and the antivirus exclusion.
async function addRunner(ctx, param) {
  // GitHub hands out a runner key only to an admin: say so before asking Windows for anything.
  if (!(await isAdmin(ctx))) return { outcome: 'no-admin', facts: {} };
  const count = /^[0-9]+$/.test(param) ? Number(param) : 0;
  const listed = () => {
    const s = gh(ctx, ['api', `repos/${ctx.fullName}/actions/runners`, '--paginate', '--jq', '.runners[] | [.name, .status] | @tsv']);
    return s.status === 0 ? String(s.stdout).split(/\r?\n/).filter(Boolean).map((l) => l.split('\t')) : [];
  };
  const before = new Set(listed().map((r) => r[0]));
  const args = count ? ['-Count', String(count)] : ['-Name', param];
  const r = await elevatedRun(ctx, path.join(ctx.root, 'scripts', 'ci', 'add-runner.ps1'), args, RUN_WAIT_MS);
  if (!r.ok) return r;
  const until = ctx.now() + ONLINE_WAIT_MS;
  for (;;) {
    const rows = listed();
    if (count) {
      // Which names the script picked is its own rule's; the new online ones are what to count.
      const online = rows.filter((x) => !before.has(x[0]) && x[1] === 'online').length;
      if (online >= count) return { outcome: 'done', facts: {} };
    } else if (rows.some((x) => x[0] === param && x[1] === 'online')) {
      return { outcome: 'done', facts: { runner: param } };
    }
    if (ctx.now() >= until) return { outcome: 'not-online', facts: count ? {} : { runner: param } };
    await ctx.sleep(POLL_MS);
  }
}

async function removeRunner(ctx, name) {
  if (!(await isAdmin(ctx))) return { outcome: 'no-admin', facts: {} };
  const r = await elevatedRun(ctx, path.join(ctx.root, 'scripts', 'ci', 'remove-runner.ps1'), ['-Name', name], PROMPT_WAIT_MS);
  return r.ok ? { outcome: 'done', facts: { runner: name } } : r;
}

async function scan(ctx, action) {
  const root = `C:\\actions-runner-${ctx.fullName.split('/')[1]}`;
  const r = await elevatedRun(ctx, PLUGIN_SCRIPT, ['-Action', action, '-Root', root], PROMPT_WAIT_MS);
  return r.ok ? { outcome: 'done', facts: { folders: SCAN_FOLDERS.join(',') } } : r;
}

// A workflow dispatched with the person's own gh sign-in; done only when its run ends.
async function dispatch(ctx, workflow, ref) {
  await ctx.step('running');
  const started = ctx.now();
  const sent = gh(ctx, ['workflow', 'run', workflow, '--ref', ref]);
  if (sent.status !== 0) return { outcome: 'failed', facts: {} };
  const until = started + RUN_WAIT_MS;
  let run;
  while (ctx.now() < until) {
    await ctx.sleep(POLL_MS);
    const l = gh(ctx, ['run', 'list', '--workflow', workflow, '--branch', ref, '--limit', '3', '--json', 'databaseId,status,conclusion,createdAt']);
    let rows = [];
    try { rows = JSON.parse(l.stdout || '[]'); } catch { /* try again */ }
    run = rows.find((r) => Date.parse(r.createdAt) >= started - 30000);
    if (run && run.status === 'completed') break;
  }
  const facts = run && Number.isInteger(run.databaseId) ? { run: String(run.databaseId) } : {};
  return { outcome: run && run.status === 'completed' && run.conclusion === 'success' ? 'done' : 'failed', facts };
}

async function runMigration(ctx, param) {
  let ref = 'main';
  if (param !== 'main') {
    const r = gh(ctx, ['api', `repos/${ctx.fullName}/pulls/${param}`, '--jq', '.head.ref']);
    ref = String(r.stdout).trim();
    if (r.status !== 0 || !/^[A-Za-z0-9._\/-]{1,200}$/.test(ref)) return { outcome: 'failed', facts: {} };
  }
  return dispatch(ctx, 'migrate.yml', ref);
}

// The same merge the terminal command makes, written in a fresh worktree from main, committed, and opened as a pull request.
async function grantPermissions(ctx, param) {
  await ctx.step('running');
  const id = ctx.now().toString(36);
  const branch = `allow-agent-commands-${id}`;
  const dir = path.join(ctx.home, 'worktrees', branch);
  const git = (args, cwd = dir) => ctx.exec('git', args, { cwd, timeoutMs: 120000 });
  if (git(['fetch', 'origin', 'main'], ctx.root).status !== 0) return { outcome: 'failed', facts: {} };
  fs.mkdirSync(path.dirname(dir), { recursive: true });
  if (git(['worktree', 'add', '-b', branch, dir, 'origin/main'], ctx.root).status !== 0) return { outcome: 'failed', facts: {} };
  const ids = param.split(',').filter((i) => PERMISSION_IDS.includes(i));
  const allow = permissions.RULES.filter((r) => ids.includes(r.id)).flatMap((r) => r.allow);
  const file = path.join(dir, '.claude', 'settings.json');
  let existing = {};
  try { existing = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { /* none yet */ }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(permissions.mergeSettings(existing, allow), null, 2) + '\n');
  const body = path.join(dir, '.scratch', 'permissions-body.md');
  fs.mkdirSync(path.dirname(body), { recursive: true });
  fs.writeFileSync(body, 'Lets the agent run the commands chosen in the permissions step, so it no longer stops at them.\n');
  for (const args of [['add', '.claude/settings.json'], ['commit', '-m', PR_TITLE], ['push', '-u', 'origin', branch]]) {
    if (git(args).status !== 0) return { outcome: 'failed', facts: {} };
  }
  const pr = ctx.exec('sh', ['scripts/pr-open.sh', PR_TITLE, body], { cwd: dir, timeoutMs: 120000 });
  const n = String(pr.stdout).match(/\/pull\/(\d+)/);
  return pr.status === 0 ? { outcome: 'opened', facts: n ? { pr: n[1] } : {} } : { outcome: 'failed', facts: {} };
}

const KIND_RUNNERS = {
  'add-runner': (c, p) => addRunner(c, p),
  'remove-runner': (c, p) => removeRunner(c, p),
  'grant-permissions': (c, p) => grantPermissions(c, p),
  'run-migration': (c, p) => runMigration(c, p),
  deploy: (c) => dispatch(c, 'deploy.yml', 'main'),
  'scan-skip': (c) => scan(c, 'Add'),
  'scan-again': (c) => scan(c, 'Remove'),
};

// perform(kind, param, ctx): the kind's fixed script, or a refusal when the kind is not on the list.
async function perform(kind, param, ctx) {
  const run = KIND_RUNNERS[kind];
  if (!run) return { outcome: 'refused', facts: {} };
  try {
    return await run(ctx, param);
  } catch {
    return { outcome: 'failed', facts: {} };
  }
}

module.exports = { perform, PLUGIN_SCRIPT, PR_TITLE, KIND_RUNNERS };

'use strict';
// Tests for the Delivery section and the merge queue picture: the pure
// parts, fed made-up GitHub reads.

const test = require('node:test');
const assert = require('node:assert/strict');
const d = require('../delivery');
const qv = require('../queue-view');
const render = require('../render');

const NOW = Date.parse('2026-10-14T12:00:00Z');
const at = (h) => new Date(NOW - h * 3600000).toISOString();

test('median and slowest tenth', () => {
  assert.equal(d.median([3, 1, 2]), 2);
  assert.equal(d.median([1, 2, 3, 4]), 2.5);
  assert.equal(d.median([]), null);
  assert.equal(d.pct([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 90), 9);
});

test('minutes reads plainly', () => {
  assert.equal(d.minutes(null), 'no data');
  assert.equal(d.minutes(20000), 'under a minute');
  assert.equal(d.minutes(12 * 60000), '12 min');
  assert.equal(d.minutes(70 * 60000), '1 h 10 min');
});

test('rollup reads checks as the queue does', () => {
  assert.equal(d.rollup([]), 'none');
  assert.equal(d.rollup([{ status: 'completed', conclusion: 'success' }, { status: 'completed', conclusion: 'skipped' }]), 'green');
  assert.equal(d.rollup([{ status: 'in_progress' }, { status: 'completed', conclusion: 'success' }]), 'pending');
  assert.equal(d.rollup([{ status: 'in_progress' }, { status: 'completed', conclusion: 'failure' }]), 'red');
  assert.equal(d.rollup([{ status: 'completed', conclusion: 'cancelled' }]), 'cancelled');
});

test('a re-run is judged by its newest attempt, and a run still going is pending', () => {
  const runs = [
    { id: 1, name: 'app', status: 'completed', conclusion: 'failure', started_at: '2026-10-15T10:00:00Z' },
    { id: 5, name: 'app', status: 'in_progress', started_at: '2026-10-15T11:00:00Z' },
    { id: 6, name: 'checks', status: 'completed', conclusion: 'success', started_at: '2026-10-15T11:00:00Z' },
    { id: 7, name: 'full', status: 'completed', conclusion: 'skipped', started_at: '2026-10-15T11:00:00Z' },
  ];
  assert.equal(d.rollup(runs), 'pending', 'no CI passed yet and app running: pending, not red');
  assert.equal(d.rollup([...runs, { id: 9, name: 'app', status: 'completed', conclusion: 'failure', started_at: '2026-10-15T11:05:00Z' }]), 'red');
});

test('what landed on main, and how', () => {
  assert.equal(d.mergedNumber('Fix the chime (#79) [serial: alone]'), 79);
  assert.equal(d.mergedNumber('Merge pull request #77 from Pawper/x'), 77);
  assert.equal(d.mergedNumber('A direct commit'), null);
  assert.equal(d.serialReason('Fix the chime (#79) [serial: migration]'), 'migration');
  assert.equal(d.serialReason('Fix the chime (#79)'), null);
  assert.deepEqual(d.batchMembers('Batch\r\n- #303 AI fill. Closes #300\n- #305 Highlights\nnot - #9'), [303, 305]);
});

test('red spells on main end at the next green run', () => {
  const runs = [
    { status: 'completed', conclusion: 'success', created_at: at(10), updated_at: at(9.9) },
    { status: 'completed', conclusion: 'failure', created_at: at(8), updated_at: at(7.9) },
    { status: 'completed', conclusion: 'failure', created_at: at(7), updated_at: at(6.9) },
    { status: 'completed', conclusion: 'success', created_at: at(6), updated_at: at(5) },
    { status: 'completed', conclusion: 'failure', created_at: at(2), updated_at: at(1.9) },
  ];
  const s = d.redSpells(runs, NOW);
  assert.equal(s.length, 2);
  assert.equal(s[0].length, 3 * 3600000);
  assert.equal(s[1].open, true);
  assert.equal(s[1].length, 2 * 3600000);
});

test('summarize says what got worse, and only that', () => {
  const run = (h, len, event, conclusion) => ({ event, status: 'completed', conclusion: conclusion || 'success', created_at: at(h), updated_at: at(h - len) });
  const raw = {
    runs: [run(1, 0.25, 'pull_request'), run(2, 0.25, 'pull_request'), run(200, 0.05, 'pull_request'), run(201, 0.05, 'pull_request'), run(3, 0.1, 'push', 'failure')],
    jobs: [
      { run_id: 1, created_at: at(1), started_at: at(0.9), completed_at: at(0.85) },
      { run_id: 1, created_at: at(1), started_at: at(0.8), completed_at: at(0.78) },
    ],
    runners: [{ status: 'online', busy: true }, { status: 'offline', busy: false }],
    closed: [{ created_at: at(5), merged_at: at(4) }, { created_at: at(5), merged_at: null }],
    mainCommits: [
      { message: 'A (#1) [serial: drain]', date: at(1) }, { message: 'B (#2) [serial: drain]', date: at(2) },
      { message: 'C (#3) [serial: migration]', date: at(3) }, { message: 'Merge pull request #4 from o/batch-2026-10-13', date: at(4) },
    ],
    hookLog: [{ at: at(1), hook: 'block-delete' }, { at: at(2), hook: 'block-delete' }, { at: at(500), hook: 'old' }],
  };
  const s = d.summarize(raw, NOW);
  assert.equal(s.ci.count, 4);
  assert.equal(s.ci.trend, 'slower');
  assert.equal(s.merges.count, 1);
  assert.equal(s.main.redNow, true);
  assert.deepEqual(s.queue.reasons, { drain: 2, migration: 1 });
  assert.equal(s.queue.batches, 1);
  assert.deepEqual(s.hooks, { 'block-delete': 2 });
  assert.ok(s.runner.share > 0.5);
  const said = s.say.join('\n');
  assert.match(said, /Main is red/);
  assert.match(said, /waiting for a runner/);
  assert.match(said, /CI got slower/);
  assert.match(said, /1 of 2 runners are online/);
  assert.match(said, /3 serial merges against 1 batches/);
});

test('summarize says nothing when nothing got worse, and nothing about runners it cannot list', () => {
  const s = d.summarize({ runs: [], closed: [], mainCommits: [], runners: null }, NOW);
  assert.deepEqual(s.say, []);
  const t = d.summarize({ runners: [] }, NOW);
  assert.deepEqual(t.say, []);
});

test('the queue: batch members leave Open; main lists each pull request once', () => {
  const raw = {
    open: [
      { number: 306, head: 'batch-2026-10-14', body: '<!-- merge-queue:batch -->\n- #303 A\n- #305 B', state: 'pending', jobsDone: 2, jobsTotal: 5 },
      { number: 310, head: 'batch-escape-lines-483', body: 'Carry escape lines. Closes #483', state: 'green' },
      { number: 303, head: 'a', state: 'green' }, { number: 305, head: 'b', state: 'green' },
      { number: 301, head: 'c', state: 'red' }, { number: 302, head: 'd', state: 'green', draft: true },
    ],
    mainCommits: [{ message: 'X (#319)', date: at(1) }, { message: 'Merge pull request #319 from o/x', date: at(2) }, { message: 'Y (#318) [serial: alone]', date: at(3) }],
  };
  const v = d.queueView(raw);
  assert.deepEqual(v.open.map((p) => [p.number, p.state]), [[310, 'green'], [301, 'red'], [302, 'draft']], 'a branch named batch-… without the marker is an ordinary pull request');
  assert.deepEqual(v.batch.members.map((p) => p.number), [303, 305]);
  assert.equal(v.batch.done, 2);
  assert.deepEqual(v.main.map((m) => m.number), [319, 318]);
  assert.equal(v.main[1].serial, 'alone');
  const st = qv.queueState(v);
  assert.match(st.note, /Batch PR #306 is testing 2/);
});

test('a lane per runner: its job and pull request, idle, or offline', () => {
  const r = d.runnerLanes(
    [{ name: 'build-1', status: 'online', busy: true }, { name: 'build-2', status: 'online', busy: false }, { name: 'build-3', status: 'offline' }],
    [{ status: 'in_progress', runner_name: 'build-1', name: 'app', head_branch: 'digest' }, { status: 'queued', name: 'checks' }, { status: 'queued', name: 'app' }],
    [{ number: 251, head: 'digest' }],
  );
  assert.deepEqual(r.lanes.map((l) => [l.name, l.status, l.job && l.job.pr]), [['build-1', 'busy', 251], ['build-2', 'idle', null], ['build-3', 'offline', null]]);
  assert.equal(r.queued, 2);
  assert.equal(d.queueView({ open: [], runners: null }).runners, null);
});

test('a runner names its job: the PR, or main with its workflow', () => {
  const r = d.runnerLanes(
    [{ name: 'r1', status: 'online', busy: true }, { name: 'r2', status: 'online', busy: true }, { name: 'r3', status: 'online', busy: true }],
    [
      { status: 'waiting', runner_name: 'r1', name: 'checks', workflow_name: 'CI', head_branch: 'feat' },
      { status: 'in_progress', runner_name: 'r2', name: 'deploy', workflow_name: 'Deploy', head_branch: 'main' },
      { status: 'queued', name: 'drain', workflow_name: 'Queue drain', head_branch: 'main' },
    ],
    [{ number: 12, head: 'feat' }],
  );
  assert.deepEqual(r.lanes.map((l) => l.job && [l.job.pr, l.job.name, l.job.workflow]), [[12, 'checks', 'CI'], [null, 'deploy', 'Deploy'], null]);
  const q = d.runnerLanes([{ name: 'r1', status: 'online', busy: true }], [{ status: 'queued', runner_name: 'r1', name: 'kotlin', workflow_name: 'CI', head_branch: 'feat' }], [{ number: 595, head: 'feat' }]);
  assert.deepEqual([q.lanes[0].job.pr, q.lanes[0].job.name, q.waiting.length], [595, 'kotlin', 0], 'a queued job that names its runner is taken, not waiting');
  assert.equal(r.lanes[2].status, 'busy', 'busy with no job seen is still busy');
  assert.deepEqual(r.waiting.map((w) => [w.branch, w.workflow, w.name]), [['main', 'Queue drain', 'drain']]);
});

test('the batch PR jobs belong to the batch, and CI passed is not work', () => {
  const r = d.runnerLanes(
    [{ name: 'r1', status: 'online', busy: true }],
    [
      { run_id: 7, status: 'in_progress', runner_name: 'r1', name: 'app', workflow_name: 'CI', head_branch: 'batch-2026-10-15-041200' },
      { run_id: 7, status: 'queued', name: 'CI passed', workflow_name: 'CI', head_branch: 'batch-2026-10-15-041200' },
      { run_id: 8, status: 'queued', name: 'CI passed', workflow_name: 'CI', head_branch: 'feat' },
    ],
    [{ number: 533, head: 'batch-2026-10-15-041200', body: '<!-- merge-queue:batch -->\n- #530 A' }, { number: 12, head: 'feat' }],
  );
  assert.deepEqual([r.lanes[0].job.pr, r.lanes[0].job.batch], [533, true]);
  assert.deepEqual(r.waiting.map((w) => [w.pr, w.name]), [[12, 'CI passed']], 'CI passed waits only when it is all that is left in its run');
});

test('every poll repaints and says when, or why not', () => {
  assert.ok(qv.QUEUE_JS.includes("stamp('updated '"));
  assert.ok(qv.QUEUE_JS.includes("stamp('could not redraw: '"));
  assert.ok(qv.QUEUE_JS.includes("stamp('could not read the queue: '"));
});

test('the queue picture explains each job', () => {
  assert.doesNotThrow(() => new Function(qv.QUEUE_JS), 'the page script parses');
  assert.ok(qv.QUEUE_JS.includes('JOB_TIPS'));
  assert.ok(qv.QUEUE_JS.includes("'drain': 'The merge queue on its timer"));
  assert.ok(qv.QUEUE_JS.includes('busy; job not matched'));
  assert.ok(!qv.QUEUE_JS.includes('another repository, or a run older'), 'no guessed cause');
});

test('the demo shows runners at work', () => {
  const f = qv.demoFrames();
  assert.ok(f.every((x) => x.runners && x.runners.length === 2));
  assert.ok(f.some((x) => x.runners.some((l) => l.status === 'busy')));
});

test('pull requests the queue is test-merging gleam', () => {
  const st = qv.queueState({ open: [{ number: 251, state: 'green' }, { number: 252, state: 'green' }, { number: 253, state: 'pending' }], batch: null, main: [], checking: [251, 252] });
  assert.deepEqual(st.batch.members.map((p) => [p.number, p.anchor]), [[251, true]]);
  assert.equal(st.batch.forming, true);
  assert.deepEqual(st.open.map((p) => [p.number, p.checking]), [[252, true], [253, false]]);
  assert.match(st.note, /Test-merging PR #251, PR #252/);
  assert.ok(qv.demoFrames().some((f) => f.open.some((p) => p.checking)));
  const notes = qv.demoFrames().map((f) => f.note).join(' ');
  assert.ok(!/(^|[^R] )#\d/.test(notes), 'every number in the demo says PR');
  assert.match(notes, /PR #251 is the earliest/);
});

test('clashes: left-out pairs from the queue, and conflicts with main', () => {
  const st = qv.queueState({ open: [{ number: 255, state: 'conflict' }, { number: 257, state: 'mainconflict' }], batch: null, main: [], clashes: [[255, 252], [999, 1]] });
  assert.deepEqual(st.clashes, [[255, 252], [257, 'main']]);
  const f = qv.demoFrames();
  assert.ok(f.some((x) => (x.clashes || []).some((c) => c[1] === 'main')));
  assert.ok(f.some((x) => (x.clashes || []).some((c) => c[0] === 255 && c[1] === 252)));
  assert.ok(f.some((x) => x.open.some((p) => p.number === 255 && p.state === 'mainconflict')), 'once #252 lands, #255 conflicts with main');
  const last = f[f.length - 1];
  assert.equal(last.open.length, 0, 'the demo plays until nothing is open');
  assert.deepEqual([251, 252, 253, 254, 255, 257].filter((n) => !last.main.some((m) => m.number === n)), [], 'every pull request lands');
});

test('hook resolutions: per hook rates, a feed, workarounds said', () => {
  const log = [
    { at: at(5), hook: 'block-delete', id: 'a' }, { at: at(4), hook: 'block-delete', id: 'b' },
    { at: at(3), hook: 'block-delete', id: 'c' }, { at: at(2), hook: 'block-force-push', id: 'd' }, { at: at(1), hook: 'block-delete', id: 'e' },
  ];
  const res = [{ id: 'a', outcome: 'followed' }, { id: 'b', outcome: 'workaround' }, { id: 'c', outcome: 'retried' }, { id: 'd', outcome: 'followed' }];
  const r = d.resolutionFeed(log, res, NOW);
  assert.equal(r.workarounds, 1);
  assert.equal(r.byHook['block-delete'].total, 4);
  assert.equal(r.byHook['block-delete'].open, 1);
  assert.equal(Math.round(r.byHook['block-delete'].followRate * 100), 33);
  assert.deepEqual(r.feed.map((f) => f.outcome), ['open', 'followed', 'retried', 'workaround', 'followed']);
  const s = d.summarize({ hookLog: log, hookResolved: res }, NOW);
  assert.match(s.say.join(' '), /possible workaround/);
  const html = render.renderHookFeed(r);
  assert.match(html, /class="alarm"/);
  assert.match(html, /33% followed/);
  assert.match(render.renderHookFeed(null), /None on record/);
});

test('the queue panel carries its data, safely', () => {
  const html = qv.renderQueue({ open: [{ number: 1, title: '</script><b>x' }], batch: null, main: [] }, { poll: 'queue.json' });
  assert.ok(html.includes('data-queue'));
  assert.ok(!html.includes('</script><b>'));
  assert.ok(html.includes('"poll":"queue.json"'));
});

test('the demo page plays on its own', () => {
  const page = qv.demoPage();
  assert.ok(page.startsWith('<!doctype html>'));
  assert.ok(page.includes('"demo":['));
  assert.ok(page.includes('window.MergeQueueView'));
  const f = qv.demoFrames();
  assert.ok(f.some((x) => x.batch) && f.some((x) => !x.batch));
});

test('the Delivery section renders its numbers and its picture', () => {
  const s = d.summarize({ runs: [], closed: [], mainCommits: [], runners: null, hookLog: [] }, NOW);
  const html = render.renderDelivery(s, qv.queueState({ open: [], batch: null, main: [] }));
  assert.match(html, /id="delivery"/);
  assert.match(html, /Nothing got worse/);
  assert.match(html, /None on record/);
  assert.match(html, /data-queue/);
  assert.equal(render.renderDelivery(null), '');
});

'use strict';
// The merge queue as a picture: open pull requests on the left, the batch
// being tested in the middle with its CI progress, main on the right.
// Each pull request is one chip that moves between the columns as its
// state changes, with a tooltip for its title, author, branch and checks.
//
// renderQueue(view) gives the markup and the data; QUEUE_CSS and QUEUE_JS
// draw and animate it in the browser. The console polls /queue.json and
// redraws; demoPage() plays a scripted queue for a page with no project
// behind it, such as the plugin's own site.

function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

const QUEUE_CSS = `
.mq { --mq-bg: #1b1f1c; --mq-panel: #262b26; --mq-chip: #1a1c22; --mq-ink: #eef2ee; --mq-soft: #9aa59c;
  --mq-line: #3a423b; --mq-green: #4ade9a; --mq-amber: #e8b04b; --mq-red: #f06292; --mq-main-red: #ef4444; --mq-grey: #7c847e; --mq-cyan: #38c8f0;
  position: relative; background: linear-gradient(180deg, var(--mq-panel), var(--mq-bg)); color: var(--mq-ink);
  border: 1px solid var(--mq-line); border-radius: 22px; padding: 18px 18px 22px; font: 13px/1.4 system-ui, -apple-system, "Segoe UI", sans-serif;
  width: 100%; max-width: 520px; box-sizing: border-box; overflow: visible; }
.mq-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; margin-bottom: 22px; }
.mq-title { letter-spacing: .18em; font-size: 12px; color: var(--mq-soft); display: flex; align-items: center; gap: 8px; text-transform: uppercase; }
.mq-title::before { content: ""; width: 8px; height: 8px; border-radius: 50%; background: var(--mq-green); box-shadow: 0 0 8px var(--mq-green); }
.mq-tag { color: var(--mq-ink); font-weight: 600; text-align: right; max-width: 60%; }
.mq-cols { display: grid; grid-template-columns: 1fr 1fr 1fr; font-size: 11px; letter-spacing: .16em; color: var(--mq-soft); margin-bottom: 10px; text-transform: uppercase; }
.mq-stage { position: relative; }
.mq-line { position: absolute; top: 0; bottom: 0; width: 2px; background: linear-gradient(var(--mq-amber), var(--mq-line) 30%); transform: translateX(-1px); }
.mq-line.pulse { animation: mq-pulse 1.2s ease-out; }
@keyframes mq-pulse { 0% { box-shadow: 0 0 0 0 var(--mq-green); background: var(--mq-green); } 100% { box-shadow: 0 0 18px 2px transparent; } }
.mq-box { position: absolute; border: 1.5px solid var(--mq-cyan); border-radius: 16px; box-shadow: 0 0 18px rgba(56,200,240,.35), inset 0 0 12px rgba(56,200,240,.12);
  transition: top .6s ease, height .6s ease, opacity .5s ease; }
.mq-bar { position: absolute; left: 12px; right: 12px; bottom: 14px; height: 5px; border-radius: 3px; background: var(--mq-line); overflow: hidden; }
.mq-bar i { display: block; height: 100%; width: 0; background: var(--mq-cyan); border-radius: 3px; transition: width .8s ease; }
.mq-bar.red i { background: var(--mq-red); } .mq-bar.green i { background: var(--mq-green); }
.mq-chip { position: absolute; left: 0; top: 0; height: 36px; padding: 0 14px; display: flex; align-items: center; gap: 8px; border-radius: 10px;
  background: var(--mq-chip); border: 1px solid #2c3036; font-weight: 700; color: var(--mq-ink); cursor: default; white-space: nowrap;
  transition: transform .8s cubic-bezier(.3,.7,.2,1), opacity .5s ease; outline: none; }
.mq-chip:focus-visible { box-shadow: 0 0 0 2px var(--mq-cyan); }
.mq-chip.small { height: 26px; padding: 0 10px; font-size: 11px; font-weight: 600; opacity: .85; }
.mq-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--mq-grey); }
.mq-chip[data-state=green] .mq-dot { background: var(--mq-green); box-shadow: 0 0 6px var(--mq-green); }
.mq-chip[data-state=pending] .mq-dot { background: var(--mq-amber); animation: mq-blink 1.4s infinite; }
.mq-chip[data-state=red] .mq-dot { background: var(--mq-red); box-shadow: 0 0 6px var(--mq-red); }
.mq-chip[data-state=cancelled] .mq-dot, .mq-chip[data-state=none] .mq-dot { background: var(--mq-grey); }
.mq-chip[data-state=draft] { opacity: .6; }
.mq-chip[data-state=merged] .mq-dot { background: var(--mq-green); }
@keyframes mq-blink { 50% { opacity: .35; } }
@property --mq-a { syntax: '<angle>'; inherits: false; initial-value: 0deg; }
.mq-chip::before { content: ""; position: absolute; inset: -2px; border-radius: 12px; padding: 2px; opacity: 0; transition: opacity .4s ease; pointer-events: none;
  background: conic-gradient(from var(--mq-a), transparent 0 62%, rgba(255,255,255,.9) 76%, var(--mq-cyan) 84%, transparent 96%);
  -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0); -webkit-mask-composite: xor; mask-composite: exclude; }
.mq-box.forming { border-style: dashed; }
.mq-box-label { position: absolute; top: 10px; left: 0; right: 0; text-align: center; font-size: 11px; font-weight: 700; letter-spacing: .04em; color: var(--mq-cyan); }
.mq-box.forming .mq-box-label { color: var(--mq-soft); font-weight: 600; }
.mq-chip.checking::before { opacity: 1; animation: mq-gleam 1.4s linear infinite; }
@keyframes mq-gleam { to { --mq-a: 360deg; } }
.mq-tip { position: absolute; z-index: 5; pointer-events: none; min-width: 200px; max-width: 280px; background: #0f1113; color: var(--mq-ink);
  border: 1px solid var(--mq-line); border-radius: 10px; padding: 10px 12px; font-size: 12px; opacity: 0; transition: opacity .15s ease; box-shadow: 0 8px 24px rgba(0,0,0,.4); }
.mq-tip.on { opacity: 1; }
.mq-tip b { display: block; font-size: 13px; margin-bottom: 4px; }
.mq-tip span { display: block; color: var(--mq-soft); }
.mq-tip .st { color: var(--mq-ink); margin-top: 6px; }
.mq-runners { margin-top: 16px; border-top: 1px solid var(--mq-line); padding-top: 12px; }
.mq-runners-head { display: flex; justify-content: space-between; font-size: 11px; letter-spacing: .16em; color: var(--mq-soft); text-transform: uppercase; margin-bottom: 8px; }
.mq-runners-head .q { letter-spacing: 0; text-transform: none; font-size: 12px; }
.mq-runners-head .q.many { color: var(--mq-amber); }
.mq-lanes { display: grid; gap: 6px; }
.mq-wait { position: relative; min-width: 0; display: flex; flex-wrap: wrap; gap: 6px; min-height: 42px; padding: 8px; border: 1px dashed var(--mq-line); border-radius: 10px; margin-bottom: 12px; align-items: center; align-content: center; }
.mq-wait-none { position: absolute; left: 14px; top: 50%; transform: translateY(-50%); color: var(--mq-soft); font-size: 12px; pointer-events: none; transition: opacity .3s ease; }
.mq-wjob.leaving { position: absolute; transition: opacity .4s ease; }
.mq-wjob { display: inline-flex; align-items: center; gap: 6px; font-size: 11px; color: var(--mq-soft); transition: transform .9s cubic-bezier(.3,.7,.2,1), opacity .4s ease; }
.mq-wjob em { font-style: normal; }
[data-tip] { cursor: help; }
.mq-lane .what { text-decoration: underline dotted var(--mq-line); text-underline-offset: 3px; }
.lanes-head { margin-top: 2px; }
.mq-lane { display: grid; grid-template-columns: 10px minmax(70px, 1fr) minmax(0, 2fr); align-items: center; gap: 10px; background: var(--mq-chip); border: 1px solid #2c3036;
  border-radius: 10px; padding: 7px 12px; font-size: 12px; transition: border-color .4s ease, box-shadow .4s ease; }
.mq-lane .ld { width: 8px; height: 8px; border-radius: 50%; background: var(--mq-grey); }
.mq-lane { --lane: var(--mq-cyan); border-left: 3px solid var(--lane); }
.mq-lane .rn { color: var(--lane); }
.mq-lane.busy { border-color: var(--lane); box-shadow: 0 0 10px color-mix(in srgb, var(--lane) 25%, transparent); }
.mq-lane.busy .ld { background: var(--lane); animation: mq-blink 1.2s infinite; }
.mq-lane .slot .mq-pill { border-color: var(--lane); }
.mq-lane.idle .ld { background: var(--mq-green); }
.mq-lane.offline { opacity: .5; } .mq-lane.offline .ld { background: var(--mq-red); }
.mq-lane .rn { font-weight: 600; }
.mq-lane .job { color: var(--mq-soft); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; display: flex; align-items: center; gap: 8px; min-height: 24px; }
.mq-pill { flex: none; height: 24px; padding: 0 10px; display: inline-flex; align-items: center; border-radius: 8px; background: #1a1c22; border: 1px solid #2c3036;
  font-weight: 700; font-size: 11px; color: var(--mq-ink); transition: transform .9s cubic-bezier(.3,.7,.2,1), opacity .4s ease; will-change: transform; }
.mq-pill.batch { border-color: var(--mq-cyan); color: var(--mq-cyan); box-shadow: 0 0 10px rgba(56,200,240,.3); }
.mq-pill.main { border-color: var(--mq-amber); color: var(--mq-amber); }
.mq-chip.working { box-shadow: 0 0 0 1.5px var(--lane, var(--mq-cyan)), 0 0 12px var(--lane, var(--mq-cyan)); }
.mq-box.working { border-color: var(--lane, var(--mq-cyan)); box-shadow: 0 0 22px var(--lane, var(--mq-cyan)); }
.mq-chip { z-index: 2; }
.mq-clash { position: absolute; inset: 0; width: 100%; height: 100%; pointer-events: none; z-index: 1; overflow: visible; }
.mq-clash line { stroke-width: 2; stroke-linecap: round; stroke-dasharray: 6 5; animation: mq-draw .7s ease-out both, mq-march 1s linear .7s infinite; }
.mq-clash line.pr { stroke: var(--mq-red); }
.mq-clash line.main { stroke: var(--mq-main-red); }
.mq-clash circle { fill: var(--mq-main-red); }
@keyframes mq-draw { from { opacity: 0; } to { opacity: .9; } }
@keyframes mq-march { to { stroke-dashoffset: -22; } }
.mq-chip[data-state=mainconflict] { border-color: var(--mq-main-red); box-shadow: 0 0 10px rgba(239,68,68,.35); }
.mq-chip[data-state=mainconflict] .mq-dot { background: var(--mq-main-red); border-radius: 2px; transform: rotate(45deg); }
.mq-chip[data-state=conflict] { border-color: var(--mq-red); }
.mq-chip[data-state=conflict] .mq-dot { background: var(--mq-red); border-radius: 2px; transform: rotate(45deg); }
.mq-lane.busy .job { color: var(--mq-ink); }
.mq-foot[data-updated]::after { content: " · " attr(data-updated); opacity: .7; }
.mq-foot { margin-top: 14px; color: var(--mq-soft); font-size: 12px; min-height: 1.4em; }
.mq-empty { position: absolute; left: 0; right: 0; top: 40%; text-align: center; color: var(--mq-soft); font-size: 12px; padding: 0 10px; transition: opacity .4s ease; }
.mq.still .mq-chip, .mq.still .mq-box { transition: none; }
@media (prefers-reduced-motion: reduce) { .mq-chip.checking::before { animation: none; background: var(--mq-cyan); } .mq-chip, .mq-box, .mq-bar i { transition: none; } .mq-dot, .mq-line.pulse { animation: none; } }
`;

// The browser side: draw(state) moves each chip to its column and row.
// A chip is keyed by its number, so a pull request moving from Open to
// Batch to Main slides rather than reappearing.
const QUEUE_JS = `
(function () {
  var STATE_WORDS = { green: 'CI green; ready to merge', pending: 'CI running', red: 'CI failed', cancelled: 'CI cancelled; will re-run',
    none: 'no checks yet', draft: 'draft; not queued', conflict: 'conflicts with another pull request; the queue told its owner', mainconflict: 'conflicts with main; not eligible for a batch until its owner merges main in and fixes it', merged: 'landed on main', batch: 'in the batch' };
  function ago(iso) {
    if (!iso) return '';
    var m = Math.round((Date.now() - Date.parse(iso)) / 60000);
    if (!isFinite(m)) return '';
    if (m < 60) return m + ' min ago';
    if (m < 2880) return Math.round(m / 60) + ' h ago';
    return Math.round(m / 1440) + ' days ago';
  }
  function MQ(root) {
    this.root = root;
    this.stage = root.querySelector('.mq-stage');
    this.tip = root.querySelector('.mq-tip');
    this.foot = root.querySelector('.mq-foot');
    this.chips = {};
    this.box = document.createElement('div'); this.box.className = 'mq-box'; this.box.style.opacity = 0;
    this.bar = document.createElement('div'); this.bar.className = 'mq-bar'; this.bar.innerHTML = '<i></i>';
    this.box.appendChild(this.bar);
    this.empty = document.createElement('div'); this.empty.className = 'mq-empty'; this.empty.textContent = 'No batch running';
    this.label = document.createElement('div'); this.label.className = 'mq-box-label';
    this.box.appendChild(this.label);
    this.box.appendChild(this.empty);
    this.line = document.createElement('div'); this.line.className = 'mq-line';
    this.stage.appendChild(this.box); this.stage.appendChild(this.line);
    this.clash = document.createElementNS('http://www.w3.org/2000/svg', 'svg'); this.clash.setAttribute('class', 'mq-clash');
    this.stage.appendChild(this.clash);
    this.lastMain = null;
    var self = this;
    window.addEventListener('resize', function () { if (self.state) self.draw(self.state); });
    root.addEventListener('mouseover', function (e) {
      var el = e.target.closest ? e.target.closest('[data-tip]') : null;
      if (!el || !el.dataset.tip || el.classList.contains('mq-chip')) return;
      self.tip.textContent = el.dataset.tip;
      var r = el.getBoundingClientRect(), o = root.getBoundingClientRect();
      self.tip.style.left = Math.min(Math.max(0, r.left - o.left), o.width - 260) + 'px';
      self.tip.style.top = (r.bottom - o.top + 6) + 'px';
      self.tip.classList.add('on');
    });
    root.addEventListener('mouseout', function (e) {
      var el = e.target.closest ? e.target.closest('[data-tip]') : null;
      if (el && !el.classList.contains('mq-chip')) self.tip.classList.remove('on');
    });
  }
  MQ.prototype.chip = function (pr, small) {
    var key = 'pr-' + pr.number, el = this.chips[key], self = this;
    if (!el) {
      el = document.createElement('div');
      el.className = 'mq-chip'; el.tabIndex = 0;
      el.innerHTML = '<span class="mq-n"></span><span class="mq-dot"></span>';
      el.style.opacity = 0;
      this.stage.appendChild(el);
      this.chips[key] = el;
      var show = function () { self.showTip(el); }, hide = function () { self.tip.classList.remove('on'); };
      el.addEventListener('mouseenter', show); el.addEventListener('focus', show);
      el.addEventListener('mouseleave', hide); el.addEventListener('blur', hide);
    }
    el.querySelector('.mq-n').textContent = 'PR #' + pr.number;
    el.classList.toggle('small', !!small);
    el.dataset.state = pr.state || 'none';
    el.classList.toggle('checking', !!pr.checking);
    el._pr = pr;
    el._seen = true;
    return el;
  };
  MQ.prototype.showTip = function (el) {
    var pr = el._pr || {}, t = this.tip, lines = [];
    var st = pr.anchor ? 'The earliest green pull request, so it anchors the batch; the others are test-merged against it.'
      : pr.where === 'batch' ? 'In the batch; ' + (STATE_WORDS[pr.state] || pr.state) : (STATE_WORDS[pr.state] || pr.state);
    t.innerHTML = '';
    var b = document.createElement('b'); b.textContent = 'PR #' + pr.number + '  ' + (pr.title || ''); t.appendChild(b);
    if (pr.author) lines.push('by ' + pr.author + (pr.created ? ', opened ' + ago(pr.created) : ''));
    if (pr.head) lines.push(pr.head);
    if (pr.checking) lines.push('Being test-merged with the others, in memory, to see which can go in the batch together.');
    if (pr.conflict) lines.push(pr.conflict);
    if (pr.at) lines.push('landed ' + ago(pr.at) + (pr.serial ? ', serially (' + pr.serial + ')' : ''));
    lines.forEach(function (l) { var s = document.createElement('span'); s.textContent = l; t.appendChild(s); });
    var s2 = document.createElement('span'); s2.className = 'st';
    s2.textContent = st + (pr.jobsTotal ? ' (' + pr.jobsDone + ' of ' + pr.jobsTotal + ' checks done' + (pr.summary ? '; CI passed: ' + pr.summary : '') + ')' : '');
    t.appendChild(s2);
    var r = el.getBoundingClientRect(), o = this.root.getBoundingClientRect();
    var left = Math.min(Math.max(0, r.left - o.left - 20), o.width - 240);
    t.style.left = left + 'px';
    t.style.top = (r.bottom - o.top + 8) + 'px';
    t.classList.add('on');
  };
  MQ.prototype.draw = function (state) {
    this.state = state;
    var w = this.stage.clientWidth, col = [w * 0.17, w * 0.5, w * 0.85], row = 50, top = 8, self = this;
    Object.keys(this.chips).forEach(function (k) { self.chips[k]._seen = false; });
    var at = {};
    var place = function (el, cx, y) {
      var cw = el.offsetWidth || 70;
      at[el._pr.number] = { x: cx, y: y + el.offsetHeight / 2, w: cw };
      el.style.transform = 'translate(' + Math.round(cx - cw / 2) + 'px,' + Math.round(y) + 'px)';
      el.style.opacity = '';
    };
    var openList = state.open || [], batch = state.batch, main = state.main || [];
    var members = batch ? batch.members : [];
    var firstBatch = top + 38;
    members.forEach(function (pr, i) { place(self.chip(Object.assign({ where: 'batch' }, pr)), col[1], firstBatch + i * row); });
    openList.forEach(function (pr, i) { place(self.chip(Object.assign({ where: 'open' }, pr)), col[0], top + 16 + i * row); });
    main.forEach(function (pr, i) { place(self.chip(Object.assign({ where: 'main', state: 'merged' }, pr), true), col[2], top + 16 + i * 36); });
    var rows = Math.max(openList.length, members.length + 2, Math.ceil(main.length * 36 / row), 3);
    var h = top + 16 + rows * row + 20;
    this.stage.style.height = h + 'px';
    var bw = Math.min(150, w * 0.3);
    this.box.style.left = (col[1] - bw / 2) + 'px'; this.box.style.width = bw + 'px';
    this.box.style.top = top + 'px'; this.box.style.height = (h - top - 4) + 'px';
    this.box.style.opacity = batch ? 1 : 0.4;
    this.empty.style.opacity = batch ? 0 : 1;
    this.bar.style.opacity = batch && !batch.forming ? 1 : 0;
    this.box.classList.toggle('forming', !!(batch && batch.forming));
    this.label.textContent = !batch ? '' : batch.forming ? 'Forming' : 'Batch PR #' + batch.number;
    var fill = batch && batch.total ? Math.round(100 * batch.done / batch.total) : 0;
    this.bar.querySelector('i').style.width = fill + '%';
    this.bar.className = 'mq-bar' + (batch && batch.state === 'red' ? ' red' : batch && batch.state === 'green' ? ' green' : '');
    this.line.style.left = col[2] + 'px';
    // A red line for each clash: pull request to pull request, pink; to
    // main, red. Drawn where the chips are going, so it lands with them.
    var svg = this.clash, NS = 'http://www.w3.org/2000/svg', drawn = {};
    Array.prototype.forEach.call(svg.querySelectorAll('line'), function (l) { drawn[l.dataset.key] = l; });
    var want = {};
    (state.clashes || []).forEach(function (c) {
      var a = at[c[0]]; if (!a) return;
      var toMain = c[1] === 'main', b = toMain ? { x: col[2], y: a.y, w: 0 } : at[c[1]];
      if (!b) return;
      var key = c[0] + '-' + c[1]; want[key] = true;
      var dir = b.x >= a.x ? 1 : -1;
      var x1 = a.x + dir * a.w / 2, x2 = b.x - dir * b.w / 2;
      var l = drawn[key];
      if (!l) { l = document.createElementNS(NS, 'line'); l.dataset.key = key; svg.appendChild(l); }
      l.setAttribute('class', toMain ? 'main' : 'pr');
      l.setAttribute('x1', x1); l.setAttribute('y1', a.y); l.setAttribute('x2', x2); l.setAttribute('y2', b.y);
    });
    Object.keys(drawn).forEach(function (k) { if (!want[k]) svg.removeChild(drawn[k]); });
    var headMain = main.length ? main[0].number : null;
    if (this.lastMain != null && headMain !== this.lastMain) { this.line.classList.remove('pulse'); void this.line.offsetWidth; this.line.classList.add('pulse'); }
    this.lastMain = headMain;
    Object.keys(this.chips).forEach(function (k) {
      var el = self.chips[k];
      if (!el._seen) { el.style.opacity = 0; setTimeout(function () { if (!el._seen && el.parentNode) { el.parentNode.removeChild(el); delete self.chips[k]; } }, 600); }
    });
    this.drawRunners(state);
    if (this.foot) this.foot.textContent = state.note || '';
  };
  // The runners row. Above the lanes, the waiting line: every job queued
  // for a runner, in one line, because GitHub keeps one queue that any
  // free runner takes from, not a queue per runner. Below it, one lane per
  // runner in its own colour: the job it runs now, or idle, or offline. A
  // job's pill flies from its pull request into the waiting line, and from
  // there into the lane of the runner that takes it; the chip of a pull
  // request being worked on glows in that runner's colour.
  var LANE_COLORS = ['#38c8f0', '#c084fc', '#fb923c', '#a3e635', '#f472b6', '#facc15'];
  function pillFor(job, batchNo) {
    var isBatch = job.pr != null && (job.batch || job.pr === batchNo);
    var isMain = !job.pr && job.branch === 'main';
    return { isBatch: isBatch, isMain: isMain,
      text: isBatch ? 'Batch PR #' + job.pr : isMain ? 'main' : job.pr ? 'PR #' + job.pr : (job.branch || 'job'),
      cls: 'mq-pill' + (isBatch ? ' batch' : isMain ? ' main' : '') };
  }
  // The words beside a pill: the job, and for main which workflow it is
  // in (the full suite, a deploy, a build, the drain).
  function jobWords(job) {
    if (!job) return '';
    var w = job.workflow && job.workflow !== job.name ? job.workflow + ' / ' : '';
    return (job.pr ? '' : w) + job.name;
  }
  // What each job is, for the tooltip on its words. A job this list does
  // not know is named by its workflow.
  var JOB_TIPS = {
    'checks': 'Every quick rule check after one checkout: line endings, the status page, numbering, spec, setup, shared code.',
    'app': 'Installs packages once, then the type-check, the tests and, when the app changed, the production build.',
    'CI passed': 'The one summary check branch protection requires; it reports once both jobs are done.',
    'ci-passed': 'The one summary check branch protection requires; it reports once both jobs are done.',
    'full': 'The whole test suite, run once on main after each merge. Main is red until it passes.',
    'drain': 'The merge queue on its timer: it batches green pull requests and merges them.',
    'deploy': 'Builds and ships main to production, when main moved in something the app ships.',
    'build': 'Builds the app for release.',
    'report-red': 'Opens the red-main issue when the full run on main fails.',
    'report-green': 'Closes the red-main issue when main passes again.',
    'smoke': 'Loads the deployed pages in a real browser and fails on a console error.'
  };
  function jobTip(job) {
    if (!job) return '';
    var key = Object.keys(JOB_TIPS).filter(function (k) { return k.toLowerCase() === String(job.name).toLowerCase(); })[0];
    var where = job.pr ? (job.batch ? 'for batch PR #' + job.pr : 'for PR #' + job.pr) : job.branch === 'main' ? 'on main' : '';
    var what = key ? JOB_TIPS[key] : 'A job in the ' + (job.workflow || "project") + ' workflow.';
    return job.name + (job.workflow ? ' (' + job.workflow + ')' : '') + (where ? ', ' + where : '') + ': ' + what;
  }
  MQ.prototype.fly = function (pill, src) {
    if (!src || this.root.classList.contains('still')) return;
    var a = src.getBoundingClientRect(), b = pill.getBoundingClientRect();
    if (!a.width) return;
    pill.style.transition = 'none';
    pill.style.transform = 'translate(' + Math.round(a.left + a.width / 2 - b.left - b.width / 2) + 'px,' + Math.round(a.top + a.height / 2 - b.top - b.height / 2) + 'px) scale(.8)';
    pill.style.opacity = '0.5';
    void pill.offsetWidth;
    pill.style.transition = ''; pill.style.transform = ''; pill.style.opacity = '';
  };
  MQ.prototype.drawRunners = function (state) {
    var box = this.root.querySelector('.mq-runners');
    if (!state.runners || !state.runners.length) { box.style.display = 'none'; return; }
    box.style.display = '';
    var self = this, batchNo = state.batch ? state.batch.number : null;
    var srcOf = function (job, p) { return p.isBatch ? self.box : p.isMain ? self.line : self.chips['pr-' + job.pr]; };
    // where each waiting pill was, before this redraw, so a job leaving
    // the line for a runner flies from it
    var wait = box.querySelector('.mq-wait'), oldWait = {};
    Array.prototype.forEach.call(wait.children, function (el) { if (el.dataset.key) oldWait[el.dataset.key] = el.getBoundingClientRect(); });
    var waiting = state.waiting || [];
    var n = waiting.length || state.queued || 0;
    var q = box.querySelector('.q');
    q.textContent = n ? n + ' job' + (n === 1 ? '' : 's') + ' waiting for a free runner' : 'no job waiting';
    q.className = 'q' + (n > state.runners.length ? ' many' : '');
    // FLIP: a job that stays slides from where it was to where it is now;
    // a new one flies in from its pull request; one that left fades where
    // it stood, so nothing in the line jumps.
    var keep = {}, wasAt = {};
    Array.prototype.forEach.call(wait.querySelectorAll('.mq-wjob'), function (el) {
      if (el.classList.contains('leaving')) { el.parentNode.removeChild(el); return; }
      keep[el.dataset.key] = el; wasAt[el.dataset.key] = el.getBoundingClientRect();
    });
    var none = wait.querySelector('.mq-wait-none');
    none.textContent = n ? n + ' queued' : 'empty';
    none.style.opacity = waiting.length ? 0 : 1;
    var want = {};
    waiting.forEach(function (job) { var p = pillFor(job, batchNo); want[p.text + ' ' + job.name] = true; });
    var wr = wait.getBoundingClientRect();
    Object.keys(keep).forEach(function (key) {
      if (want[key]) return;
      var el = keep[key], r = wasAt[key];
      // A job a runner took goes at once: the lane's pill flies from this
      // spot, and the jobs behind it slide up without passing over it.
      if (el.parentNode) el.parentNode.removeChild(el);
      delete keep[key];
    });
    var fresh = [];
    waiting.forEach(function (job) {
      var p = pillFor(job, batchNo), key = p.text + ' ' + job.name;
      var el = keep[key];
      if (!el) {
        el = document.createElement('span'); el.dataset.key = key;
        el.innerHTML = '<span></span><em></em>';
        el.className = 'mq-wjob';
        fresh.push([el, job, p]);
      }
      el.firstChild.className = p.cls; el.firstChild.textContent = p.text; el.lastChild.textContent = jobWords(job);
      el.dataset.tip = jobTip(job);
      wait.appendChild(el);
    });
    Object.keys(keep).forEach(function (key) {
      var el = keep[key], a = wasAt[key], b = el.getBoundingClientRect();
      if (!a || (a.left === b.left && a.top === b.top)) return;
      el.style.transition = 'none';
      el.style.transform = 'translate(' + Math.round(a.left - b.left) + 'px,' + Math.round(a.top - b.top) + 'px)';
      void el.offsetWidth;
      el.style.transition = ''; el.style.transform = '';
    });
    fresh.forEach(function (f) { self.fly(f[0], srcOf(f[1], f[2])); });
    var lanes = box.querySelector('.mq-lanes'), have = {}, working = {}, batchColor = null;
    Array.prototype.forEach.call(lanes.children, function (el) { have[el.dataset.name] = el; });
    state.runners.forEach(function (r, i) {
      var color = LANE_COLORS[i % LANE_COLORS.length];
      var el = have[r.name];
      if (!el) { el = document.createElement('div'); el.dataset.name = r.name; el.innerHTML = '<span class="ld"></span><span class="rn"></span><span class="job"><span class="slot"></span><span class="what"></span></span>'; lanes.appendChild(el); }
      delete have[r.name];
      el.className = 'mq-lane ' + r.status;
      el.style.setProperty('--lane', color);
      el.querySelector('.rn').textContent = r.name;
      var job = r.job, slot = el.querySelector('.slot'), what = el.querySelector('.what');
      what.textContent = r.status === 'offline' ? 'offline' : job ? jobWords(job) : r.status === 'busy' ? 'busy; job not matched' : 'idle';
      what.dataset.tip = r.status === 'offline' ? 'This runner is not connected to GitHub, so it takes no jobs.'
        : job ? jobTip(job)
        : r.status === 'busy' ? 'GitHub says this runner is busy, and no unfinished job this page read names it, even after reading again.'
        : 'Free: it takes the next job in the waiting line.';
      var p = job ? pillFor(job, batchNo) : null;
      if (p && p.isBatch) batchColor = batchColor || color;
      else if (job && job.pr) working[job.pr] = working[job.pr] || color;
      var key = p ? p.text + ' ' + job.name : '';
      if (slot.dataset.key === key) return;
      slot.dataset.key = key;
      slot.innerHTML = '';
      if (!p || (!job.pr && !p.isMain)) return;
      var pill = document.createElement('span');
      pill.className = p.cls; pill.textContent = p.text;
      slot.appendChild(pill);
      // From the waiting line when it was there, else from its pull request.
      var from = oldWait[key];
      if (from && !self.root.classList.contains('still')) {
        var b = pill.getBoundingClientRect();
        pill.style.transition = 'none';
        pill.style.transform = 'translate(' + Math.round(from.left - b.left) + 'px,' + Math.round(from.top - b.top) + 'px)';
        void pill.offsetWidth;
        pill.style.transition = ''; pill.style.transform = '';
      } else self.fly(pill, srcOf(job, p));
    });
    Object.keys(self.chips).forEach(function (k) {
      var c = working[k.slice(3)];
      self.chips[k].classList.toggle('working', !!c);
      if (c) self.chips[k].style.setProperty('--lane', c);
    });
    this.box.classList.toggle('working', !!batchColor);
    if (batchColor) this.box.style.setProperty('--lane', batchColor);
    Object.keys(have).forEach(function (k) { lanes.removeChild(have[k]); });
  };
  window.MergeQueueView = MQ;
  document.querySelectorAll('.mq[data-queue]').forEach(function (root) {
    var mq = new MQ(root), data = JSON.parse(root.querySelector('script[type="application/json"]').textContent);
    // The first picture appears in place; only changes after it move.
    root.classList.add('still');
    requestAnimationFrame(function () { mq.draw(data.state); requestAnimationFrame(function () { root.classList.remove('still'); }); });
    if (data.poll) {
      // Every poll repaints and says when; a redraw that fails says so on
      // the card instead of leaving the last picture up as if it were now.
      var stamp = function (text) {
        var f = root.querySelector('.mq-foot');
        if (f) f.dataset.updated = text;
      };
      var tick = function () {
        fetch(data.poll, { cache: 'no-store' }).then(function (r) { return r.ok ? r.json() : Promise.reject(new Error('the console answered ' + r.status)); })
          .then(function (s) {
            try { mq.draw(s); stamp('updated ' + new Date().toLocaleTimeString()); }
            catch (e) { stamp('could not redraw: ' + e.message); }
          })
          .catch(function (e) { stamp('could not read the queue: ' + (e && e.message ? e.message : 'no answer')); });
      };
      stamp('updated ' + new Date().toLocaleTimeString());
      setInterval(tick, data.every || 30000);
    }
    if (data.demo) {
      var i = 0;
      setInterval(function () { i = (i + 1) % data.demo.length; mq.draw(data.demo[i]); }, data.every || 2200);
    }
  });
})();
`;

// queueState(VIEW): what the browser draws, from queueView in delivery.js.
function queueState(view) {
  const note = [];
  if (view.checking && view.checking.length) note.push(`Test-merging ${view.checking.map((n) => 'PR #' + n).join(', ')} to find which go in the batch together.`);
  if (view.batch) note.push(`Batch PR #${view.batch.number} is testing ${view.batch.members.length} pull request(s) together.`);
  const ready = view.open.filter((p) => p.state === 'green').length;
  if (ready) note.push(`${ready} green and waiting.`);
  if (!view.batch && !view.open.length) note.push('Nothing waiting.');
  const checking = view.checking || [];
  const anchor = !view.batch && checking.length ? checking[0] : null;
  return {
    open: view.open.filter((p) => p.number !== anchor).map((p) => ({ ...pick(p), checking: checking.includes(p.number) })),
    batch: anchor ? { number: null, forming: true, state: 'none', done: 0, total: 0, members: view.open.filter((p) => p.number === anchor).map((p) => ({ ...pick(p), anchor: true })) } : view.batch ? { number: view.batch.number, state: view.batch.state, done: view.batch.done, total: view.batch.total, members: view.batch.members.map(pick) } : null,
    main: view.main,
    runners: view.runners || null,
    waiting: view.waiting || null,
    clashes: [
      ...(view.clashes || []).filter((c) => view.open.some((p) => p.number === c[0])),
      ...view.open.filter((p) => p.state === 'mainconflict').map((p) => [p.number, 'main']),
    ],
    queued: view.queued == null ? null : view.queued,
    note: note.join(' '),
  };
}

function pick(p) {
  return { number: p.number, title: p.title, author: p.author, head: p.head, created: p.created, state: p.state, conflict: p.conflict, summary: p.summary, jobsDone: p.jobsDone, jobsTotal: p.jobsTotal };
}

// renderQueue(STATE, {poll, demo, tagline}): the panel's markup, with its
// data inline so it draws before the first poll.
function renderQueue(state, opts) {
  const o = opts || {};
  const data = { state, poll: o.poll || null, demo: o.demo || null, every: o.every || null };
  const json = JSON.stringify(data).replace(/</g, '\\u003c');
  return `<div class="mq" data-queue>
<div class="mq-head"><div class="mq-title">Merge queue</div><div class="mq-tag">${esc(o.tagline || 'Testing only what each change touched.')}</div></div>
<div class="mq-cols"><div>Open</div><div style="text-align:center">Batch</div><div style="text-align:right">Main</div></div>
<div class="mq-stage"></div>
<div class="mq-runners"><div class="mq-runners-head"><span>Waiting for a runner</span><span class="q"></span></div><div class="mq-wait"><span class="mq-wait-none"></span></div><div class="mq-runners-head lanes-head"><span>Runners</span></div><div class="mq-lanes"></div></div>
<div class="mq-foot" aria-live="polite"></div>
<div class="mq-tip" role="tooltip"></div>
<script type="application/json">${json}</script>
</div>`;
}

// The scripted queue for demoPage, played until every pull request has
// landed. Six pull requests; four are green,
// #255 conflicts with #252 (pink: a clash with another pull request), and
// #257 conflicts with main (red: never eligible until its owner fixes it). The batch takes the earliest and the most
// that fit beside it, leaves #255 out and tells its owner which files;
// two runners in their own colours take jobs from one waiting line.
function demoFrames() {
  const t = {
    251: ['Add the weekly digest email', 'ada', 'digest-email'],
    252: ['Fix the date picker on mobile', 'lin', 'datepicker-mobile'],
    253: ['Cache the search results', 'sam', 'search-cache'],
    254: ['Plain words on the empty cart', 'ada', 'empty-cart-copy'],
    255: ['Show the date picker in the cart', 'kit', 'cart-datepicker'],
    257: ['Rename the cart route', 'sam', 'cart-route'],
  };
  const P = (n, state, extra) => ({ number: n, title: t[n][0], author: t[n][1], head: t[n][2], state, created: null, ...(extra || {}) });
  const C255 = P(255, 'conflict', { conflict: 'Conflicts with #252 in src/ui/DatePicker.tsx. The queue commented the files on it and labeled it blocked; its owner merges main in and fixes them.' });
  const M257 = P(257, 'mainconflict', { conflict: 'Conflicts with main in src/routes/cart.ts, which changed after it was opened. It is not eligible for a batch; the queue told its owner, who merges main in and fixes the file.' });
  const M255 = P(255, 'mainconflict', { conflict: 'PR #252 landed, so its date picker change is on main now and this one conflicts with main. Its owner was told when the batch formed.' });
  const landed = (ns) => ns.map((n) => ({ number: n, title: n > 250 ? `${t[n][0]} (#${n})` : `Earlier work (#${n})`, at: null }));
  const B = (done, total, state) => ({ number: 256, state, done, total, members: [251, 252, 254].map((n) => P(n, state === 'green' ? 'green' : 'pending')) });
  const J = (pr, name) => (pr === 'main' ? { pr: null, branch: 'main', name, workflow: 'CI' } : { pr, name, workflow: 'CI', batch: pr === 256 || pr === 258 });
  const B2 = (done, total, state) => ({ number: 258, state, done, total, members: [253, 255].map((n) => P(n, state === 'green' ? 'green' : 'pending')) });
  const R = (a, b, waiting) => ({ runners: [{ name: 'build-1', status: a ? 'busy' : 'idle', job: a ? J(...a) : null }, { name: 'build-2', status: b ? 'busy' : 'idle', job: b ? J(...b) : null }], waiting: waiting.map((w) => J(...w)), queued: waiting.length });
  // Every number a person reads is a pull request; say so.
  const prs = (text) => String(text).replace(/(^|[^R] )#(\d+)/g, '$1PR #$2').replace(/^#(\d+)/, 'PR #$1');
  const before = landed([250, 249, 248]);
  const after = landed([254, 252, 251, 250, 249, 248]);
  const after2 = landed([255, 253, 254, 252, 251, 250]);
  const after3 = landed([257, 255, 253, 254, 252, 251]);
  const frames = [
    { open: [P(251, 'green'), P(252, 'green'), P(253, 'pending'), P(254, 'green'), P(255, 'green'), M257], batch: null, main: before, clashes: [[257, 'main']],
      ...R([253, 'checks'], [255, 'app'], [[253, 'app']]), note: 'Four pull requests are green; #253 is still being tested. #257 conflicts with main, so it is not eligible for a batch at all.' },
    { open: [P(252, 'green', { checking: true }), P(253, 'pending'), P(254, 'green', { checking: true }), P(255, 'green', { checking: true }), M257], clashes: [[257, 'main']],
      batch: { number: null, forming: true, state: 'none', done: 0, total: 0, members: [P(251, 'green', { anchor: true })] }, main: before,
      ...R([253, 'app'], null, []), note: '#251 is the earliest, so it anchors the batch. The other green ones are test-merged against it and each other, in memory; no runner is needed for that.' },
    { open: [P(253, 'pending'), C255, M257], batch: B(0, 3, 'pending'), main: before, clashes: [[255, 252], [257, 'main']],
      ...R([253, 'app'], null, [[256, 'checks'], [256, 'app']]), note: 'The batch takes #251 first, then the most that fit beside it. #255 conflicts with #252, so it waits, and its owner is told which files.' },
    { open: [P(253, 'pending'), C255, M257], batch: B(1, 3, 'pending'), main: before, clashes: [[255, 252], [257, 'main']],
      ...R([253, 'app'], [256, 'checks'], [[256, 'app']]), note: 'The batch\'s jobs queue like anyone else\'s; a free runner takes the next in line.' },
    { open: [P(253, 'green'), C255, M257], batch: B(2, 3, 'pending'), main: before, clashes: [[255, 252], [257, 'main']],
      ...R([256, 'app'], [256, 'CI passed'], []), note: '#253 is green now. Both runners are on the batch.' },
    { open: [P(253, 'green'), C255, M257], batch: B(3, 3, 'green'), main: before, clashes: [[255, 252], [257, 'main']],
      ...R(null, null, []), note: 'The batch is green: three pull requests tested once, together.' },
    { open: [P(253, 'green'), M255, M257], batch: null, main: after, clashes: [[255, 'main'], [257, 'main']],
      ...R(['main', 'full'], null, []), note: 'All three land on main in one merge. #252 is on main now, so #255 conflicts with main: red, not pink.' },
    { open: [P(253, 'green'), P(255, 'pending'), M257], batch: null, main: after, clashes: [[257, 'main']],
      ...R([255, 'checks'], ['main', 'full'], [[255, 'app']]), note: '#255\'s owner merged main in and fixed the file; it is being tested again.' },
    { open: [P(253, 'green'), P(255, 'green'), P(257, 'pending')], batch: null, main: after,
      ...R([257, 'checks'], null, [[257, 'app']]), note: '#255 is green again. #257\'s owner merged main in too, so it is no longer red; it is being tested.' },
    { open: [P(255, 'green', { checking: true }), P(257, 'pending')],
      batch: { number: null, forming: true, state: 'none', done: 0, total: 0, members: [P(253, 'green', { anchor: true })] }, main: after,
      ...R([257, 'app'], null, []), note: 'The next round: #253 is now the earliest green one, so it anchors the next batch, and #255 is test-merged against it.' },
    { open: [P(257, 'pending')], batch: B2(0, 3, 'pending'), main: after,
      ...R([257, 'app'], [258, 'checks'], [[258, 'app']]), note: 'They fit, so batch #258 tests #253 and #255 together. #257 is not green yet, so it waits for the next round.' },
    { open: [P(257, 'green')], batch: B2(2, 3, 'pending'), main: after,
      ...R([258, 'app'], [258, 'CI passed'], []), note: '#257 is green now, but the batch already started; it does not jump in.' },
    { open: [P(257, 'green')], batch: B2(3, 3, 'green'), main: after,
      ...R(null, null, []), note: 'Batch #258 is green.' },
    { open: [P(257, 'green')], batch: null, main: after2,
      ...R(['main', 'full'], null, []), note: '#253 and #255 land together. One green pull request is left; a batch of one would only add a run.' },
    { open: [], batch: null, main: after3,
      ...R(['main', 'full'], null, []), note: '#257 merges on its own, since main is green and it merges cleanly. Every open pull request has landed: two batches and one on its own.' },
  ];
  return frames.map((f) => ({ ...f, note: prs(f.note), open: f.open.map((o) => (o.conflict ? { ...o, conflict: prs(o.conflict) } : o)) }));
}

// demoPage(): one self-contained page that plays the scripted queue, for
// a site with no project behind it.
function demoPage() {
  const frames = demoFrames();
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Merge queue</title>
<style>body { margin: 0; padding: 24px 16px; background: #10120f; } .mq { margin: 0 auto; } ${QUEUE_CSS}</style>
</head>
<body>
${renderQueue(frames[0], { demo: frames, every: 2600 })}
<script>${QUEUE_JS}</script>
</body>
</html>
`;
}

module.exports = { QUEUE_CSS, QUEUE_JS, renderQueue, queueState, demoFrames, demoPage };

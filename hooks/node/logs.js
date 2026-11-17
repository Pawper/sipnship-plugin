'use strict';
// The files a hook keeps on this machine, written as the shell hooks write
// them (refusal-log.sh, rule-switch.sh, hook-timed.sh): the refusal log and
// its pending list, the rule switches in .claude/rules-off.txt, the note when
// a switched-off rule let a call through, and the timing record. Every line
// has the same fields in the same order, so the console and the brief read
// what the Node program writes as they read what the shell wrote.
const fs = require('fs');
const path = require('path');

const stamp = () => new Date().toISOString().slice(0, 19) + 'Z';
const logOn = () => (process.env.HOOK_LOG === undefined ? '1' : process.env.HOOK_LOG) !== '0';
const projectDir = () => process.env.CLAUDE_PROJECT_DIR || '.';

// scratchDir(): the project's ignored scratch folder, or '' when the project
// has no .git (a hook never writes outside a repository).
function scratchDir() {
  const root = projectDir();
  try { fs.statSync(path.join(root, '.git')); } catch (e) { return ''; }
  return path.join(root, '.scratch');
}

function append(file, line) {
  try { fs.appendFileSync(file, line); return true; } catch (e) { return false; }
}

// ruleOn(id): true unless .claude/rules-off.txt has a line naming the id.
function ruleOn(id) {
  const file = process.env.RULES_OFF_FILE || path.join(projectDir(), '.claude', 'rules-off.txt');
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch (e) { return true; }
  for (const raw of text.replace(/\r/g, '').split('\n')) {
    const first = raw.replace(/#.*/, '').trim().split(/\s+/)[0];
    if (first === id) return false;
  }
  return true;
}

// ruleOffNote(hook, id, session): one line saying a switched-off rule let a call through.
function ruleOffNote(hook, id, session) {
  if (!logOn()) return;
  const s = scratchDir();
  if (!s) return;
  try { fs.mkdirSync(s, { recursive: true }); } catch (e) { return; }
  const now = stamp();
  append(path.join(s, 'hooks-off.log'), [now, hook, id, session || 'unknown', now + '-' + process.pid].join('\t') + '\n');
}

function epoch(iso) {
  const m = /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z/.exec(iso);
  if (!m) return null;
  return Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]) / 1000;
}

function seconds(from, to) {
  const a = epoch(from), b = epoch(to);
  return a === null || b === null || b < a ? 0 : b - a;
}

const calls = (n) => (/^[0-9]+$/.test(n) ? Math.min(+n, 5) : 0);

let counter = 0;

// refusalLog(hook, session): one refusal noted, and an earlier one by the
// same hook in the same session settled as retried (refusal-log.sh).
function refusalLog(hook, session) {
  if (!logOn()) return;
  const s = scratchDir();
  if (!s) return;
  try { fs.mkdirSync(path.join(s, 'hooks'), { recursive: true }); } catch (e) { return; }
  const now = stamp();
  const sess = session || 'unknown';
  const id = now + '-' + process.pid + (counter++ ? '.' + counter : '');
  if (!append(path.join(s, 'hooks.log'), [now, hook, sess, id].join('\t') + '\n')) return;
  const pending = path.join(s, 'hooks', 'pending');
  let text = null;
  try { text = fs.readFileSync(pending, 'utf8'); } catch (e) { /* none yet */ }
  if (text !== null) {
    const keep = [];
    for (const line of text.split('\n')) {
      if (line === '') continue;
      const f = line.split('\t');
      if (f[1] === hook && f[2] === sess) {
        append(path.join(s, 'hooks-resolved.log'), [now, f[0], f[1], f[2], 'retried', seconds(f[0], now), calls(f[3] || '')].join('\t') + '\n');
      } else {
        keep.push(line);
      }
    }
    try { fs.writeFileSync(pending, keep.length ? keep.join('\n') + '\n' : ''); } catch (e) { /* kept as it was */ }
  }
  append(pending, [id, hook, sess, '0'].join('\t') + '\n');
}

// timing: the start and end lines of .scratch/hooks/timing.log, as hook-timed.sh writes them.
function timingDir() {
  if (!logOn()) return '';
  const s = scratchDir();
  if (!s) return '';
  try { fs.mkdirSync(path.join(s, 'hooks'), { recursive: true }); } catch (e) { return ''; }
  return path.join(s, 'hooks');
}

function timingStart(dir, name, limit) {
  if (dir) append(path.join(dir, 'timing.log'), ['start', stamp(), name, limit, process.pid].join('\t') + '\n');
}

function timingEnd(dir, name, limit, ms) {
  if (dir) append(path.join(dir, 'timing.log'), ['end', stamp(), name, limit, ms, process.pid].join('\t') + '\n');
}

function timingBound(dir, name, seconds_) {
  if (dir) append(path.join(dir, 'timing.log'), ['bound', stamp(), name, seconds_].join('\t') + '\n');
}

// timingTrim(dir): cut the record to its newest 2000 lines when it passes 4000.
function timingTrim(dir) {
  if (!dir) return;
  const file = path.join(dir, 'timing.log');
  try {
    const lines = fs.readFileSync(file, 'utf8').split('\n');
    if (lines.length - 1 > 4000) fs.writeFileSync(file, lines.slice(-2001).join('\n'));
  } catch (e) { /* the record is only a record */ }
}

module.exports = { ruleOn, ruleOffNote, refusalLog, timingDir, timingStart, timingEnd, timingBound, timingTrim, scratchDir, logOn };

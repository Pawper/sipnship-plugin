'use strict';
// The hour's GitHub budget, read as lib.sh reads it: a cached line in
// .scratch/gh-budget.txt, younger than a minute, else one free call to
// gh api rate_limit. A record is "graphql_left graphql_limit graphql_reset
// rest_left rest_limit rest_reset", tab-separated.
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const JQ = '[.resources.graphql.remaining, .resources.graphql.limit, .resources.graphql.reset, .resources.core.remaining, .resources.core.limit, .resources.core.reset] | @tsv';

const commas = (n) => String(Math.trunc(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
const num = (s) => { const m = /^[ \t]*[-+]?[0-9]*\.?[0-9]+/.exec(s); return m ? parseFloat(m[0]) : 0; };

// budgetCached(line, now, max): the record of a cache line "epoch<TAB>record"
// younger than max seconds, or ''.
function budgetCached(line, now, max = 60) {
  const f = line.replace(/\r/g, '').split('\n')[0].split('\t');
  if (f.length < 7) return '';
  const age = now - num(f[0]);
  return age >= 0 && age < max ? f.slice(1, 7).join('\t') : '';
}

// budgetLine(record, now, floor, warn): the one line the hook and the brief show.
function budgetLine(record, now, floor = 500, warn = 1500) {
  const f = record.replace(/\r/g, '').split('\n')[0].split('\t');
  if (f.length < 6 || f[0] === '') return '';
  const reset = num(f[2]);
  const mins = Math.max(0, Math.trunc((reset - now + 59) / 60));
  const hh = String(Math.trunc((reset % 86400) / 3600)).padStart(2, '0');
  const mm = String(Math.trunc((reset % 3600) / 60)).padStart(2, '0');
  let out = 'GraphQL ' + commas(num(f[0])) + ' of ' + commas(num(f[1])) + ' left, resets ' + hh + ':' + mm + 'Z (in ' + mins + ' min); REST ' + commas(num(f[3])) + ' of ' + commas(num(f[4])) + ' left.';
  if (num(f[0]) < floor) out += ' Low: use the REST forms (scripts/issue-open.sh, pr-open.sh, pr-checks.sh, gh api) and wait for the reset; never retry before it.';
  else if (num(f[0]) < warn) out += ' Getting low: switch to the REST forms now (scripts/issue-open.sh, pr-open.sh, pr-checks.sh, gh api); gh pr, gh issue and gh project spend these points.';
  return out;
}

function budgetLow(record, floor = 500) {
  const f = record.replace(/\r/g, '').split('\n')[0].split('\t');
  return f.length >= 6 && f[0] !== '' && num(f[0]) < floor;
}

// budgetRead(root, onBound): the record from the cache, else from gh (bounded);
// '' when gh is absent or the call fails. onBound(seconds) is told of a read cut short.
function budgetRead(root, onBound) {
  const file = path.join(root, '.scratch', 'gh-budget.txt');
  const now = Math.floor(Date.now() / 1000);
  let first = '';
  try { first = fs.readFileSync(file, 'utf8').split('\n')[0]; } catch (e) { /* no cache */ }
  const cached = budgetCached(first, now);
  if (cached) return cached;
  const secs = Number(process.env.HOOK_NET_SECONDS) || 4;
  const r = spawnSync('gh', ['api', 'rate_limit', '--jq', JQ], { encoding: 'utf8', timeout: secs * 1000, windowsHide: true });
  if (r.error) { if (r.error.code === 'ETIMEDOUT' && onBound) onBound(secs); return ''; }
  if (r.status !== 0) return '';
  const rec = (r.stdout || '').replace(/\r/g, '').replace(/\n+$/, '');
  if (!rec) return '';
  try {
    fs.mkdirSync(path.join(root, '.scratch'), { recursive: true });
    fs.writeFileSync(file, now + '\t' + rec + '\n');
  } catch (e) { /* the cache is a convenience */ }
  return rec;
}

module.exports = { budgetCached, budgetLine, budgetLow, budgetRead };
